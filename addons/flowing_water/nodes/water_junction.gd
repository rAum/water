# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
@icon("../editor/icons/water_junction.svg")
class_name WaterJunction
extends Node3D
## Joins one end of a WaterRiver to a WaterPond (river -> pond, or
## pond -> river) and enforces continuity of height, flow and look:
##   1. the river end snaps to the pond level, flattened over the last metres;
##   2. the river's last baked row becomes the pond's inflow (or the pond's
##      speed seeds the outgoing river), so "Bake" here bakes both in order;
##   3. over the blend length the river ribbon extends into the pond and
##      fades out, drawn above the pond (render_priority + 2 mm lift), with
##      style parameters blending from river values to pond values.

enum Direction { RIVER_INTO_POND, POND_INTO_RIVER }

@export var river_path: NodePath:
	set(v):
		river_path = v
		_connect_bodies()
@export var pond_path: NodePath:
	set(v):
		pond_path = v
		_connect_bodies()
@export var direction: Direction = Direction.RIVER_INTO_POND:
	set(v):
		direction = v
		_connect_bodies()
## Metres over which the two surfaces blend.
@export_range(1.0, 12.0) var blend_length := 4.0:
	set(v):
		blend_length = v
		_update_blend()
## Metres of river flattened to meet the pond level without a kink.
@export_range(1.0, 20.0) var flatten_length := 6.0

var _extension: MeshInstance3D

signal baked


func _ready() -> void:
	_connect_bodies()
	_manager_call("register_junction", self)


func _exit_tree() -> void:
	_manager_call("unregister_junction", self)
	var pond := get_pond()
	if pond != null:
		pond.unregister_junction(self)


func get_river() -> WaterRiver:
	return get_node_or_null(river_path) as WaterRiver


func get_pond() -> WaterPond:
	return get_node_or_null(pond_path) as WaterPond


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	var river := get_river()
	var pond := get_pond()
	if river == null or pond == null:
		out.append("Assign both a WaterRiver and a WaterPond.")
		return out
	if direction == Direction.RIVER_INTO_POND:
		var end: Vector3 = river.end_frame()["pos"]
		if end.y < pond.water_level() - 0.05:
			out.append("The river arrives %.2f m below the pond level. Use \"Snap to pond level\"." % (pond.water_level() - end.y))
	if river.style != null and pond.style != null \
			and river.style.shader_variant != pond.style.shader_variant:
		out.append("River and pond use different shader variants; the junction cannot blend them seamlessly.")
	return out


func _connect_bodies() -> void:
	if not is_inside_tree():
		return
	var river := get_river()
	var pond := get_pond()
	if river != null:
		river.set_junction(self, direction == Direction.RIVER_INTO_POND)
	if pond != null:
		pond.register_junction(self)
	_update_blend()
	update_configuration_warnings()


# ----------------------------------------------------------- height continuity --

## Snaps the junction end of the river to the pond level and flattens the
## last metres so the surface arrives without a kink.
func snap_river_to_pond() -> void:
	var river := get_river()
	var pond := get_pond()
	if river == null or pond == null or river.curve == null:
		return
	var level := pond.water_level()
	var curve := river.curve
	var n := curve.point_count
	if n < 2:
		return
	var at_end := direction == Direction.RIVER_INTO_POND
	var length := curve.get_baked_length()
	for p in n:
		var pos := curve.get_point_position(p)
		var world_y := (river.global_transform * pos).y
		var s := curve.get_closest_offset(pos)
		var dist_from_junction := (length - s) if at_end else s
		if dist_from_junction <= flatten_length:
			var t := clampf(dist_from_junction / flatten_length, 0.0, 1.0)
			var ease_t := t * t * (3.0 - 2.0 * t)
			var target := lerpf(level, maxf(world_y, level), ease_t)
			pos.y += target - world_y
			curve.set_point_position(p, pos)
	river.rebuild_mesh()
	update_configuration_warnings()


# -------------------------------------------------------------- flow continuity --

## Inlet profile for an outgoing river (pond -> river): the first metres
## start at the pond's speed, not at full river speed.
func river_inlet_profile(river: WaterRiver) -> Array:
	if direction != Direction.POND_INTO_RIVER or get_pond() == null:
		return []
	var pond := get_pond()
	if pond.baked_data == null or not pond.baked_data.is_valid():
		return []
	var data := river.prepare_bake_data(0)
	var nx := data.cells_across
	var fluxes := PackedFloat32Array()
	fluxes.resize(nx)
	var foam := PackedFloat32Array()
	foam.resize(nx)
	var aer := PackedFloat32Array()
	aer.resize(nx)
	var total := 0.0
	for i in nx:
		var pos := WaterBaker._cell_to_world(data, i, 0)
		var q: Array = pond.query_water(pos)
		var speed := 0.3
		if not q.is_empty():
			speed = maxf((q[1] as Vector3).length(), 0.1)
		var dep: float = data.depth[i]
		var flux: float = 0.0 if dep <= 0.03 else speed * dep * data.row_cell_width[0]
		fluxes[i] = flux
		total += flux
	# scale so the river still carries its discharge overall; the pressure
	# solve accelerates it smoothly toward the lip
	if total > 1e-5:
		var sc := river.discharge / total
		# don't jump straight to full speed at the mouth
		sc = minf(sc, 2.5)
		for i in nx:
			fluxes[i] *= sc
	return [fluxes, foam, aer]


## Boundary for the pond bake: inflow at a river mouth, outflow at an outlet.
func pond_boundary(_pond: WaterPond) -> Dictionary:
	var river := get_river()
	if river == null:
		return {}
	if direction == Direction.RIVER_INTO_POND:
		var prof := river.end_flow_profile()
		if prof.is_empty():
			return {}
		var plunge := 0.0
		if not river.baked_segments.is_empty() and river.baked_segments[0] != null:
			var data: WaterData = river.baked_segments[river.baked_segments.size() - 1]
			var last_slope: float = data.row_slope[data.rows - 1] if data.row_slope.size() > 0 else 0.0
			if last_slope > river.waterfall_threshold * 0.8:
				plunge = 1.0
		# The river's weight fades out over the blend zone, so the pond must
		# already be flowing there: hand the inflow over where the river
		# crosses the shore, not at the tip of the ribbon.
		var positions: PackedVector3Array = prof[3]
		var dir: Vector3 = prof[4]
		var shifted := PackedVector3Array()
		for pos in positions:
			var best := pos
			var back := 0.25
			while back <= blend_length:
				var cand := pos - dir * back
				if not _pond.contains_point(cand):
					break
				best = cand
				back += 0.25
			shifted.append(best)
		return {
			"is_inlet": true,
			"fluxes": prof[0], "foam": prof[1], "aeration": prof[2],
			"positions": shifted, "dir": dir, "plunge": plunge,
		}
	else:
		# outlet: the pond loses the river's discharge at the river's mouth
		var data := river.prepare_bake_data(0)
		var positions := PackedVector3Array()
		for i in data.cells_across:
			positions.append(WaterBaker._cell_to_world(data, i, 0))
		return {"is_inlet": false, "positions": positions}


## Bakes everything this junction touches, in the right order: inlet rivers
## first, then the pond, then outgoing rivers.
func bake_all(progress: Callable = Callable()) -> void:
	var pond := get_pond()
	if pond == null:
		var river := get_river()
		if river != null:
			river.bake_segments_blocking(progress)
		return
	var junctions: Array[Node] = pond._junctions
	for j in junctions:
		if j is WaterJunction and j.direction == Direction.RIVER_INTO_POND:
			var r: WaterRiver = j.get_river()
			if r != null:
				r.bake_segments_blocking(progress)
	pond.bake_blocking(progress)
	for j in junctions:
		if j is WaterJunction and j.direction == Direction.POND_INTO_RIVER:
			var r: WaterRiver = j.get_river()
			if r != null:
				r.bake_segments_blocking(progress)
	_update_blend()
	_build_extension()
	baked.emit()


# -------------------------------------------------------------- look continuity --

func _update_blend() -> void:
	var river := get_river()
	var pond := get_pond()
	if river == null or pond == null or river.curve == null:
		return
	var length: float = river.curve.get_baked_length()
	if direction == Direction.RIVER_INTO_POND:
		# the ribbon extends into the pond and fades out; the river is drawn
		# on top with a small lift so the two surfaces never flicker
		river.set_blend_uniforms(length - blend_length, blend_length, 0.002,
			length, blend_length, pond.style)
	else:
		# reversed: pond style at the start of the river, fading to the
		# river's own; the ribbon itself fades in over the same metres, so
		# the pond underneath carries the look up to the lip
		river.set_blend_uniforms(blend_length, -blend_length, 0.002,
			0.0, 0.0, pond.style, blend_length)
	var rm := river.surface_material()
	if rm != null:
		rm.render_priority = 1
	var pm := pond.surface_material()
	if pm != null:
		pm.render_priority = 0
	if direction == Direction.RIVER_INTO_POND:
		_build_extension()


## Weight of the river in blended queries near its tail.
func river_tail_weight(river: WaterRiver, s: float) -> float:
	if direction != Direction.RIVER_INTO_POND or river.curve == null:
		return 1.0
	var length: float = river.curve.get_baked_length()
	return clampf((length - s) / maxf(blend_length, 0.01), 0.0, 1.0)


## Weight of an outgoing river in blended queries near its start.
func river_head_weight(river: WaterRiver, s: float) -> float:
	if direction != Direction.POND_INTO_RIVER:
		return 1.0
	return clampf(s / maxf(blend_length, 0.01), 0.0, 1.0)


## The river ribbon continued into the pond for the blend length, fading out.
func _build_extension() -> void:
	if _extension != null and is_instance_valid(_extension):
		_extension.queue_free()
		_extension = null
	var river := get_river()
	var pond := get_pond()
	if river == null or pond == null or direction != Direction.RIVER_INTO_POND:
		return
	var f := river.end_frame()
	var c: Vector3 = f["pos"]
	var dir: Vector3 = f["dir"]
	dir.y = 0.0
	dir = dir.normalized()
	var side := Vector3(dir.z, 0.0, -dir.x)
	var hw: float = f["half_width"] + 0.4
	var level := pond.water_level()
	var length: float = river.curve.get_baked_length()

	var rows := 9
	var ax := 13
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	for r in rows:
		var t := float(r) / float(rows - 1)
		var center := c + dir * t * blend_length
		center.y = lerpf(c.y, level, t * t * (3.0 - 2.0 * t)) + 0.002
		for i in ax:
			var u := float(i) / float(ax - 1)
			var d := -hw + u * 2.0 * hw
			pos.append(center + side * d)
			nrm.append(Vector3.UP)
			tan.append_array([dir.x, dir.y, dir.z, 1.0])
			uv.append(Vector2(u, 1.0))
			uv2.append(Vector2(d, length + t * blend_length))
			col.append(Color(1.0 - t, 1.0, 0.0))
	var idx := PackedInt32Array()
	for r in rows - 1:
		for i in ax - 1:
			var a := r * ax + i
			idx.append_array([a, a + ax, a + 1, a + 1, a + ax, a + ax + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TANGENT] = tan
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_extension = MeshInstance3D.new()
	_extension.mesh = mesh
	_extension.material_override = river.surface_material()
	_extension.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_extension.custom_aabb = mesh.get_aabb().grow(0.6)
	add_child(_extension, false, Node.INTERNAL_MODE_BACK)
	# the mesh was built in world space (end_frame() is global)
	_extension.top_level = true
	_extension.global_transform = Transform3D.IDENTITY


func _manager_call(method: String, arg) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var mgr := tree.root.get_node_or_null("WaterManager")
	if mgr != null:
		mgr.call(method, arg)
