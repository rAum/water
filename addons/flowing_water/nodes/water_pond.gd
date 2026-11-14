# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
@icon("../editor/icons/water_pond.svg")
class_name WaterPond
extends Node3D
## Still or slow water drawn as a closed outline. The surface is flat at this
## node's height. Ponds share the river surface shader; the flow across the
## pond comes from the same pressure solve, driven by the junction inlets and
## outlets, so a pond with no junctions has zero flow.

const MAX_GRID := 512
const DEFAULT_CELL := 0.25
## The surface reaches this far past the outline. An outline is a polygon of
## straight chords drawn by hand: the real shore (where the ground rises out
## of the water) lies a little inside or outside it. The water is drawn and
## baked over this band too, and the depth buffer ends it exactly where the
## bank comes out of the water - no dry strip under a cut-off surface.
const SKIRT := 0.7

## Closed outline in the node's local XZ plane.
@export var outline: PackedVector2Array = PackedVector2Array([
	Vector2(-6, -6), Vector2(6, -6), Vector2(8, 2), Vector2(0, 7), Vector2(-7, 3),
]):
	set(v):
		outline = v
		_mark_dirty()

@export var style: WaterStyle:
	set(v):
		if style != null and style.changed.is_connected(_apply_style):
			style.changed.disconnect(_apply_style)
		style = v
		if style != null:
			style.changed.connect(_apply_style)
		_apply_style()

@export_flags_3d_physics var collision_mask: int = 1
## Wind ripple strength on still water (scaled by WindField when present).
@export_range(0.0, 1.0) var wind_ripples := 0.4:
	set(v):
		wind_ripples = v
		_apply_style()
@export_range(0, 3) var debug_view := 0:
	set(v):
		debug_view = v
		for m in [_material, _far_material]:
			if m != null:
				m.set_shader_parameter("debug_view", v)

@export var baked_data: WaterData

var bake_out_of_date := false
var _material: ShaderMaterial
var _far_material: ShaderMaterial
## The surface, cut into tiles of about TILE_SIZE metres: a lake is not one
## mesh paying for the full shader out to its far shore.
var _tiles: Array[MeshInstance3D] = []
const TILE_SIZE := 48.0
var _spray: Node3D
var _junctions: Array[Node] = []
var _hash_accum := 0.0

signal baked


func _ready() -> void:
	_make_material()
	rebuild_mesh()
	_manager_call("register_body", self)
	if not Engine.is_editor_hint():
		_build_spray()


func _enter_tree() -> void:
	if is_node_ready():
		_manager_call("register_body", self)


func _exit_tree() -> void:
	_manager_call("unregister_body", self)


func _process(delta: float) -> void:
	_update_lod()
	if Engine.is_editor_hint():
		_hash_accum += delta
		if _hash_accum > 2.0:
			_hash_accum = 0.0
			_check_bake_freshness()


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if outline.size() < 3:
		out.append("The outline needs at least 3 points.")
	if baked_data == null:
		out.append("Not baked yet. Press \"Bake\" (or bake a junction, which bakes river and pond in order).")
	elif bake_out_of_date:
		out.append("Bake is out of date: a collider inside the pond bounds moved.")
	return out


func _mark_dirty() -> void:
	if Engine.is_editor_hint() and is_node_ready():
		rebuild_mesh()
	update_gizmos()
	update_configuration_warnings()


# -------------------------------------------------------------------- meshing --

func rebuild_mesh() -> void:
	for t in _tiles:
		if is_instance_valid(t):
			t.queue_free()
	_tiles.clear()
	_lod_dirty = true
	var mgr := _manager()
	if mgr != null and mgr.has_method("invalidate_query_grid"):
		mgr.invalidate_query_grid()
	if outline.size() < 3:
		return
	var shore := skirt_outline()
	# densify the outline (shore detail) and scatter interior points
	var pts := PackedVector2Array()
	for n in shore.size():
		var a := shore[n]
		var b := shore[(n + 1) % shore.size()]
		var len := a.distance_to(b)
		var steps := maxi(1, int(len / 0.6))
		for s in steps:
			pts.append(a.lerp(b, float(s) / float(steps)))
	var aabb := _outline_rect()
	var spacing := clampf(maxf(aabb.size.x, aabb.size.y) / 24.0, 0.8, 4.0)
	var y := aabb.position.y + spacing * 0.5
	while y < aabb.end.y:
		var x := aabb.position.x + spacing * 0.5
		var odd := false
		while x < aabb.end.x:
			var p := Vector2(x, y + (spacing * 0.25 if odd else 0.0))
			if Geometry2D.is_point_in_polygon(p, shore) \
					and _distance_to_polygon(p, shore) > spacing * 0.35:
				pts.append(p)
			x += spacing
			odd = not odd
		y += spacing
	var tris := Geometry2D.triangulate_delaunay(pts)
	if tris.is_empty():
		return

	var grid := _grid_info()
	var origin: Vector2 = grid["origin"]
	var size: Vector2 = grid["size"]
	var gpos := global_position

	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	pos.resize(pts.size())
	nrm.resize(pts.size())
	tan.resize(pts.size() * 4)
	uv.resize(pts.size())
	uv2.resize(pts.size())
	col.resize(pts.size())
	for n in pts.size():
		var p := pts[n]
		pos[n] = Vector3(p.x, 0.0, p.y)
		nrm[n] = Vector3.UP
		tan[n * 4] = 0.0
		tan[n * 4 + 1] = 0.0
		tan[n * 4 + 2] = 1.0
		tan[n * 4 + 3] = 1.0
		uv[n] = Vector2((p.x - origin.x) / size.x, (p.y - origin.y) / size.y)
		uv2[n] = Vector2(gpos.x + p.x, gpos.z + p.y)
		col[n] = Color(1, 0, 0)
	# keep only triangles inside the outline, with pond winding flipped so
	# the surface faces up; each goes to the tile its centroid lies in
	var tile_tris := {}     # Vector2i -> PackedInt32Array
	var t := 0
	while t < tris.size():
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		var centroid := (pts[a] + pts[b] + pts[c]) / 3.0
		if Geometry2D.is_point_in_polygon(centroid, shore):
			var key := Vector2i(floori(centroid.x / TILE_SIZE), floori(centroid.y / TILE_SIZE))
			var list: PackedInt32Array = tile_tris.get(key, PackedInt32Array())
			list.append_array([a, c, b])
			tile_tris[key] = list
		t += 3
	if tile_tris.is_empty():
		return
	for key in tile_tris:
		# a tile carries only the vertices its triangles use
		var src: PackedInt32Array = tile_tris[key]
		var remap := {}
		var t_pos := PackedVector3Array()
		var t_nrm := PackedVector3Array()
		var t_tan := PackedFloat32Array()
		var t_uv := PackedVector2Array()
		var t_uv2 := PackedVector2Array()
		var t_col := PackedColorArray()
		var idx := PackedInt32Array()
		idx.resize(src.size())
		for k in src.size():
			var v := src[k]
			if not remap.has(v):
				remap[v] = t_pos.size()
				t_pos.append(pos[v])
				t_nrm.append(nrm[v])
				t_tan.append_array([tan[v * 4], tan[v * 4 + 1], tan[v * 4 + 2], tan[v * 4 + 3]])
				t_uv.append(uv[v])
				t_uv2.append(uv2[v])
				t_col.append(col[v])
			idx[k] = remap[v]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = t_pos
		arrays[Mesh.ARRAY_NORMAL] = t_nrm
		arrays[Mesh.ARRAY_TANGENT] = t_tan
		arrays[Mesh.ARRAY_TEX_UV] = t_uv
		arrays[Mesh.ARRAY_TEX_UV2] = t_uv2
		arrays[Mesh.ARRAY_COLOR] = t_col
		arrays[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.custom_aabb = mesh.get_aabb().grow(0.5)
		if mgr != null:
			mgr.set_draw_range(mi)
		add_child(mi, false, Node.INTERNAL_MODE_BACK)
		_tiles.append(mi)
	_apply_style()


# ------------------------------------------------------------------------ LOD --

## Metres the camera moves before the near/far shader choice is re-checked.
const LOD_RECHECK_MOVE := 2.0
var _lod_dirty := true
var _lod_cam := Vector3.INF


## Each tile switches to the cheap `_far` shader once its nearest point is
## past the distance where vertex waves and refraction have faded out of
## the full one (the same rule and hysteresis as river chunks).
func _update_lod() -> void:
	if _tiles.is_empty() or _material == null or _far_material == null:
		return
	var cam: Camera3D = null
	if Engine.is_editor_hint():
		var ei: Object = Engine.get_singleton("EditorInterface")
		var vp: Viewport = ei.get_editor_viewport_3d(0) if ei != null else null
		cam = vp.get_camera_3d() if vp != null else null
	elif get_viewport() != null:
		cam = get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	if not _lod_dirty and cam_pos.distance_squared_to(_lod_cam) < LOD_RECHECK_MOVE * LOD_RECHECK_MOVE:
		return
	_lod_dirty = false
	_lod_cam = cam_pos
	var mgr := _manager()
	var far_dist: float = mgr.far_lod_distance() if mgr != null else 110.0
	for tile in _tiles:
		if not is_instance_valid(tile):
			continue
		var box: AABB = tile.global_transform * tile.custom_aabb
		var nearest := cam_pos.clamp(box.position, box.end)
		var d := cam_pos.distance_to(nearest)
		var is_far := tile.material_override == _far_material
		var want_far := d > (far_dist * 0.9 if is_far else far_dist * 1.1)
		tile.material_override = _far_material if want_far else _material


func apply_draw_distance() -> void:
	var mgr := _manager()
	if mgr == null:
		return
	for tile in _tiles:
		if is_instance_valid(tile):
			mgr.set_draw_range(tile)


func _distance_to_outline(p: Vector2) -> float:
	return _distance_to_polygon(p, outline)


static func _distance_to_polygon(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for n in poly.size():
		var a := poly[n]
		var b := poly[(n + 1) % poly.size()]
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


## The outline grown by SKIRT: the area the surface is drawn and baked over.
func skirt_outline() -> PackedVector2Array:
	if outline.size() < 3:
		return outline
	var grown := Geometry2D.offset_polygon(outline, SKIRT, Geometry2D.JOIN_ROUND)
	var best := outline
	var best_area := -1.0
	for poly: PackedVector2Array in grown:
		if Geometry2D.is_polygon_clockwise(poly) != Geometry2D.is_polygon_clockwise(outline) and grown.size() > 1:
			continue
		var r := Rect2(poly[0], Vector2.ZERO)
		for q in poly:
			r = r.expand(q)
		if r.get_area() > best_area:
			best_area = r.get_area()
			best = poly
	return best


## Signed horizontal distance from the outline: positive inside the pond,
## negative outside.
func inside_distance(world_pos: Vector3) -> float:
	if outline.size() < 3:
		return -INF
	var local := to_local(world_pos)
	var p2 := Vector2(local.x, local.z)
	var d := _distance_to_outline(p2)
	return d if Geometry2D.is_point_in_polygon(p2, outline) else -d


func _outline_rect() -> Rect2:
	var r := Rect2(outline[0], Vector2.ZERO)
	for p in outline:
		r = r.expand(p)
	return r


## Bake grid over the outline bounds: default 0.25 m cells, capped 512x512.
func _grid_info() -> Dictionary:
	var r := _outline_rect().grow(SKIRT + 0.5)
	var cell := DEFAULT_CELL
	var nx := int(ceil(r.size.x / cell))
	var nz := int(ceil(r.size.y / cell))
	while nx > MAX_GRID or nz > MAX_GRID:
		cell *= 2.0
		nx = int(ceil(r.size.x / cell))
		nz = int(ceil(r.size.y / cell))
	return {"origin": r.position, "size": Vector2(nx * cell, nz * cell), "nx": nx, "nz": nz, "cell": cell}


# ----------------------------------------------------------------------- bake --

## Main-thread raycast part.
func prepare_bake_data() -> WaterData:
	var grid := _grid_info()
	var nx: int = grid["nx"]
	var nz: int = grid["nz"]
	var cell: float = grid["cell"]
	var origin: Vector2 = grid["origin"]
	var data := WaterData.new()
	data.cells_across = nx
	data.rows = nz
	data.cell_length = cell
	data.is_pond_grid = true
	var gpos := global_position
	data.grid_origin = Vector3(gpos.x + origin.x, gpos.y, gpos.z + origin.y)
	data.row_cell_width.resize(nz)
	data.row_slope.resize(nz)
	data.row_height.resize(nz)
	data.row_mean_speed.resize(nz)
	data.row_half_width.resize(nz)
	data.row_center.resize(nz)
	data.row_dir.resize(nz)
	for j in nz:
		data.row_cell_width[j] = cell
		data.row_slope[j] = 0.0
		data.row_height[j] = gpos.y
		data.row_center[j] = data.grid_origin + Vector3(nx * cell * 0.5, 0, (float(j) + 0.5) * cell)
		data.row_dir[j] = Vector3(0, 0, 1)
		data.row_half_width[j] = nx * cell * 0.5
	data.depth.resize(nx * nz)
	var space := get_world_3d().direct_space_state
	var shore := skirt_outline()
	for j in nz:
		for i in nx:
			var local := Vector2(origin.x + (float(i) + 0.5) * cell, origin.y + (float(j) + 0.5) * cell)
			var dep := 0.0
			# (past the outline too: the depth there says where the bank
			# really comes out of the water - negative on dry ground)
			if Geometry2D.is_point_in_polygon(local, shore):
				var world := Vector3(gpos.x + local.x, gpos.y, gpos.z + local.y)
				if space != null:
					var ray := PhysicsRayQueryParameters3D.create(
						world + Vector3.UP * 1.5, world + Vector3.DOWN * 12.0, collision_mask)
					var hit := space.intersect_ray(ray)
					dep = (gpos.y - hit["position"].y) if not hit.is_empty() else 6.0
			data.depth[j * nx + i] = dep
	return data


## Bakes the pond. Junctions must already be registered so their inlet
## profiles and outlets drive the solve (bake rivers first: a junction's
## Bake button does both in the right order).
func bake_blocking(progress: Callable = Callable()) -> void:
	var data := prepare_bake_data()
	var params := WaterBaker.BakeParams.new()
	params.pond_mode = true
	params.discharge = 0.0
	for j in _junctions:
		if j == null or not j.has_method("pond_boundary"):
			continue
		var b: Dictionary = j.pond_boundary(self)
		if b.is_empty():
			continue
		var cells := _world_cells(data, b.get("positions", PackedVector3Array()))
		if b.get("is_inlet", true):
			# inflow cells that land on dry ground cannot take water: hand
			# their share to the wet ones so the river's discharge is kept
			var fluxes: PackedFloat32Array = b.get("fluxes", PackedFloat32Array()).duplicate()
			var total := 0.0
			var total_wet := 0.0
			for c in cells.size():
				total += fluxes[c]
				if cells[c] >= 0 and data.depth[cells[c]] > WaterBaker.SOLID_EPSILON:
					total_wet += fluxes[c]
			if total_wet > 1e-6:
				for c in cells.size():
					fluxes[c] *= total / total_wet
			params.pond_inlet_cells.append_array(cells)
			params.pond_inlet_fluxes.append_array(fluxes)
			params.pond_inlet_foam.append_array(b.get("foam", PackedFloat32Array()))
			params.pond_inlet_aeration.append_array(b.get("aeration", PackedFloat32Array()))
			var dir: Vector3 = b.get("dir", Vector3(0, 0, 1))
			for c in cells.size():
				params.pond_inlet_dirs.append(Vector2(dir.x, dir.z).normalized())
			var plunge: float = b.get("plunge", 0.0)
			if plunge > 0.0 and not cells.is_empty() and cells[cells.size() / 2] >= 0:
				params.plunge_cells.append(cells[cells.size() / 2])
				params.plunge_strengths.append(plunge)
		else:
			params.pond_outlet_cells.append_array(cells)
	WaterBaker.bake(data, params, progress)
	data.build_textures()
	data.scene_hash = _collider_hash()
	baked_data = data
	bake_out_of_date = false
	update_configuration_warnings()
	_bind_baked_textures()
	var mgr := _manager()
	if mgr != null:
		mgr.invalidate_map()
	if not Engine.is_editor_hint():
		_build_spray()
	baked.emit()


## Grid cell index for each world position; -1 where the position is
## outside the grid (the result stays aligned with the input).
func _world_cells(data: WaterData, positions: PackedVector3Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for p in positions:
		var i := int((p.x - data.grid_origin.x) / data.cell_length)
		var j := int((p.z - data.grid_origin.z) / data.cell_length)
		if i >= 0 and i < data.cells_across and j >= 0 and j < data.rows:
			out.append(j * data.cells_across + i)
		else:
			out.append(-1)
	return out


## True if the world position is inside the pond outline.
func contains_point(world_pos: Vector3) -> bool:
	var local := to_local(world_pos)
	return outline.size() >= 3 and Geometry2D.is_point_in_polygon(Vector2(local.x, local.z), outline)


func save_baked_data(base_path: String = "") -> void:
	if baked_data == null:
		return
	if base_path == "":
		var scene := get_tree().edited_scene_root if Engine.is_editor_hint() else null
		base_path = "res://" + String(name)
		if scene != null and scene.scene_file_path != "":
			base_path = scene.scene_file_path.get_base_dir() + "/" \
				+ scene.scene_file_path.get_file().get_basename() + "_" + String(name)
	var path := base_path + "_water.res"
	baked_data.take_over_path(path)
	ResourceSaver.save(baked_data, path, ResourceSaver.FLAG_COMPRESS)


func _scene_root() -> Node:
	if owner != null:
		return owner
	if Engine.is_editor_hint():
		return get_tree().edited_scene_root
	return get_tree().current_scene


func _collider_hash() -> int:
	return WaterBaker.collider_hash(_scene_root(), get_water_aabb().grow(1.0),
		collision_mask, global_transform)


func _check_bake_freshness() -> void:
	if baked_data == null:
		return
	var fresh := _collider_hash() == baked_data.scene_hash
	if bake_out_of_date == fresh:
		bake_out_of_date = not fresh
		update_configuration_warnings()


# ------------------------------------------------------------------ materials --

func _make_material() -> void:
	_material = ShaderMaterial.new()
	_far_material = ShaderMaterial.new()
	_apply_style()


func _apply_style() -> void:
	if _material == null:
		return
	var mgr := _manager()
	var variant := style.shader_variant if style != null else WaterStyle.Variant.REALISTIC
	if mgr != null:
		_material.shader = mgr.shader_for(variant, false)
		_far_material.shader = mgr.shader_for(variant, true)
	else:
		_material.shader = load("res://addons/flowing_water/render/water_full.gdshader")
		_far_material.shader = load("res://addons/flowing_water/render/water_far.gdshader")
	for m in [_material, _far_material]:
		if style != null:
			style.apply_to_material(m)
			style.apply_to_material(m, "style_b_")
		m.set_shader_parameter("wind_ripple_strength", wind_ripples)
		m.set_shader_parameter("debug_view", debug_view)
		if mgr != null:
			m.set_shader_parameter("vertex_wave_max_dist", mgr.vertex_wave_distance())
			m.set_shader_parameter("noise_tex", mgr.noise_texture)
			m.set_shader_parameter("fall_tex", mgr.fall_texture)
			m.set_shader_parameter("foam_tex", mgr.foam_texture)
	_lod_dirty = true
	_bind_baked_textures()
	# rivers that blend into this pond carry its style as their second style
	for j in _junctions:
		if j != null and is_instance_valid(j) and j.has_method("_update_blend"):
			j._update_blend()


func apply_quality() -> void:
	_apply_style()


func _bind_baked_textures() -> void:
	if baked_data == null or _material == null:
		return
	for m in [_material, _far_material]:
		m.set_shader_parameter("flow_tex", baked_data.flow_tex)
		m.set_shader_parameter("aux_tex", baked_data.aux_tex)


func surface_material() -> ShaderMaterial:
	return _material


# -------------------------------------------------------------------- queries --

func query_water(world_pos: Vector3) -> Array:
	var local := to_local(world_pos)
	var p2 := Vector2(local.x, local.z)
	if outline.size() < 3 or not Geometry2D.is_point_in_polygon(p2, outline):
		return []
	var height := global_position.y
	var flow := Vector3.ZERO
	var depth := 1.0
	if baked_data != null and baked_data.is_valid():
		var fi := (world_pos.x - baked_data.grid_origin.x) / baked_data.cell_length - 0.5
		var fj := (world_pos.z - baked_data.grid_origin.z) / baked_data.cell_length - 0.5
		depth = baked_data.sample_array(baked_data.depth, fi, fj)
		if depth <= 0.03:
			return []
		flow = Vector3(
			baked_data.sample_array(baked_data.vel_across, fi, fj), 0.0,
			baked_data.sample_array(baked_data.vel_along, fi, fj))
		height += baked_data.sample_array(baked_data.surface_offset, fi, fj)
	return [height, flow, depth, 1.0]


## Height of the surface as the vertex shader draws it at time `t`
## (WaterManager.water_time): level, baked offset, standing waves and the
## wind's swell, term for term as in water_surface_body.gdshaderinc.
## NAN outside the pond.
func drawn_height(world_pos: Vector3, t: float) -> float:
	var r := query_water(world_pos)
	if r.is_empty():
		return NAN
	var level := global_position.y
	if baked_data == null or not baked_data.is_valid():
		return level
	var d := baked_data
	var fi := (world_pos.x - d.grid_origin.x) / d.cell_length - 0.5
	var fj := (world_pos.z - d.grid_origin.z) / d.cell_length - 0.5
	var depth := d.sample_array(d.depth, fi, fj)
	var foam := d.sample_array(d.foam, fi, fj)
	var off := d.sample_array(d.surface_offset, fi, fj)
	var speed := Vector2(d.sample_array(d.vel_across, fi, fj), d.sample_array(d.vel_along, fi, fj)).length()
	var shore := smoothstep(0.02, 0.2, depth)
	var mgr := get_tree().root.get_node_or_null("WaterManager") if is_inside_tree() else null
	var m := Vector2(world_pos.x, world_pos.z)   # v_metric (UV2) = world xz
	var wave_amp := style.standing_wave_height if style != null else 0.08
	var amp := wave_amp * (0.3 + 1.2 * foam) * clampf(speed / 2.0, 0.0, 1.3) * shore
	amp *= 0.85 + 0.15 * sin(t * 1.7 + m.y * 2.0)
	var h0 := 0.0
	if mgr != null:
		h0 = mgr.sample_noise(Vector2(m.x * 0.22, m.y * 0.16 - t * 0.02), 2) - 0.5
	var lift := (off + h0 * 2.0 * amp + 0.02 * foam) * shore
	# wind swell: wind_waves(p, t, wind_dir, 1).x / WIND_WAVE_REF_H, first train only
	if wind_ripples > 0.001 and mgr != null:
		var wd := Vector2(0.6, 0.8).normalized()
		var warp := Vector2(
			mgr.sample_noise(m * 0.045 + t * wd * 0.004, 0),
			mgr.sample_noise(m * 0.045 + t * wd * 0.004, 1)) - Vector2(0.5, 0.5)
		var lambda := 5.5
		var ang := -1.4 * 0.42
		var steep := 0.11
		var wdir := Vector2(wd.x * cos(ang) - wd.y * sin(ang), wd.x * sin(ang) + wd.y * cos(ang))
		var k := TAU / lambda
		var omega := sqrt(9.81 * k)
		var ph := wdir.dot(m) * k - omega * t + warp.x * 6.0
		var wh := (steep / k) * sin(ph) / 0.096
		var ww_h := style.wind_wave_height if style != null else 0.015
		var calm := 1.0 - clampf(speed / 0.6, 0.0, 1.0)
		lift += wh * ww_h * (wind_ripples / 0.4) * calm * shore * smoothstep(0.1, 0.5, depth)
	return level + lift


## Water level beside a position on the shore (within `margin` metres of
## the outline), NAN otherwise. Used for wet banks.
func surface_height_near(world_pos: Vector3, margin: float = 2.5) -> float:
	if outline.size() < 3:
		return NAN
	var local := to_local(world_pos)
	var p2 := Vector2(local.x, local.z)
	if Geometry2D.is_point_in_polygon(p2, outline) or _distance_to_outline(p2) <= margin:
		return global_position.y
	return NAN


## Splats this pond's baked grid into the world water map. `cursor` is a
## map row; returns Vector2i(next_cursor or -1 when done, texels written).
func splat_water_map(build, cursor: int, budget: int) -> Vector2i:
	if baked_data == null or not baked_data.is_valid():
		return Vector2i(-1, 0)
	var data := baked_data
	var used := 0
	var level := global_position.y
	var margin := 2.0
	var gx0 := data.grid_origin.x
	var gz0 := data.grid_origin.z
	var gw := float(data.cells_across) * data.cell_length
	var gh := float(data.rows) * data.cell_length
	var n: int = build.n
	var i0 := clampi(int((gx0 - margin - build.ox) / build.texel), 0, n)
	var i1 := clampi(int((gx0 + gw + margin - build.ox) / build.texel) + 1, 0, n)
	var j0 := clampi(int((gz0 - margin - build.oz) / build.texel), 0, n)
	var j1 := clampi(int((gz0 + gh + margin - build.oz) / build.texel) + 1, 0, n)
	var j := maxi(cursor, j0)
	while j < j1:
		if used >= budget:
			return Vector2i(j, used)
		var z: float = build.oz + (float(j) + 0.5) * build.texel
		var fj := (z - gz0) / data.cell_length - 0.5
		for i in range(i0, i1):
			var x: float = build.ox + (float(i) + 0.5) * build.texel
			var fi := (x - gx0) / data.cell_length - 0.5
			var wet := false
			if fi >= 0.0 and fj >= 0.0 and fi < float(data.cells_across - 1) and fj < float(data.rows - 1):
				var dep := data.sample_array(data.depth, fi, fj)
				var cell := int(fj + 0.5) * data.cells_across + int(fi + 0.5)
				# rocks stay walls for the ripple simulation
				if dep > 0.03 and (data.obstacle.is_empty() or data.obstacle[cell] == 0):
					wet = true
					build.put_water(x, z,
						data.sample_array(data.vel_across, fi, fj),
						data.sample_array(data.vel_along, fi, fj),
						level + data.sample_array(data.surface_offset, fi, fj), dep, 1.0)
			if not wet:
				build.put_bank(x, z, level)
			used += 1
		j += 1
	return Vector2i(-1, used)


func get_water_aabb() -> AABB:
	var r := _outline_rect().grow(SKIRT)
	return AABB(global_position + Vector3(r.position.x, -4.0, r.position.y),
		Vector3(r.size.x, 5.0, r.size.y))


# ---------------------------------------------------------- junction support --

func register_junction(j: Node) -> void:
	if not _junctions.has(j):
		_junctions.append(j)


func unregister_junction(j: Node) -> void:
	_junctions.erase(j)


## Water level at the shore nearest to a world position (it is flat).
func water_level() -> float:
	return global_position.y


func _build_spray() -> void:
	if _spray != null and is_instance_valid(_spray):
		_spray.queue_free()
		_spray = null
	if baked_data == null:
		return
	var segs: Array[WaterData] = [baked_data]
	_spray = WaterSprayFactory.build_for(self, segs)
	if _spray != null:
		add_child(_spray, false, Node.INTERNAL_MODE_BACK)


func _manager() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("WaterManager")


func _manager_call(method: String, arg) -> void:
	var mgr := _manager()
	if mgr != null:
		mgr.call(method, arg)
