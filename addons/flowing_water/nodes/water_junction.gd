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
##   3. the river ribbon cross-fades with the pond only where the pond's
##      surface lies under it (inside the shore), so no strip of half-faded
##      water ever hangs over bare channel; its sides fade too, so it leaves
##      no edge on open water. Where the two overlap the river is drawn
##      above the pond (render_priority + OVERLAP_LIFT, its own surface
##      offset flattened to the pond's level) so the two never fight for
##      depth, and its style blends from river values to pond values over
##      the same metres.

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
		_cache_valid = false
		_update_blend()
## Metres of river flattened to meet the pond level without a kink.
@export_range(1.0, 20.0) var flatten_length := 6.0

## Height of the river over the pond where the two overlap: enough that
## the pond's own small waves and offsets never poke through it.
const OVERLAP_LIFT := 0.03
## The river starts to fade this far inside the shore.
const FADE_START := 0.15

var _extension: MeshInstance3D
# cached shore crossing: x = arc length, y/z = fade range inside the shore
var _cache := Vector3.ZERO
var _cache_valid := false

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
	# the river's mesh carries the overlap fade: rebuild it now that it
	# knows its pond (the river may have been built before this node)
	if river != null and river.is_node_ready():
		river.rebuild_mesh()
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
	refresh_cache()
	var fade := _fade_range()
	var s0 := shore_offset()
	# the style blends over the same metres the ribbon fades over: by the
	# time the river is gone it already looks like the pond
	var span := maxf(fade.y - FADE_START, 0.5)
	if direction == Direction.RIVER_INTO_POND:
		river.set_blend_uniforms(s0, span, OVERLAP_LIFT, 0.0, 0.0, pond.style)
	else:
		# reversed: pond style at the start of the river, its own downstream
		river.set_blend_uniforms(s0, -span, OVERLAP_LIFT, 0.0, 0.0, pond.style)
	var rm := river.surface_material()
	if rm != null:
		rm.render_priority = 1
	var pm := pond.surface_material()
	if pm != null:
		pm.render_priority = 0
	if direction == Direction.RIVER_INTO_POND:
		_build_extension()


## Recomputes the cached shore crossing (after the river or pond moved).
func refresh_cache() -> void:
	_cache_valid = false
	_cache = Vector3(_shore_offset_uncached(), 0.0, 0.0)
	var tip := _tip_inside()
	_cache.y = FADE_START
	_cache.z = clampf(tip - 0.25, FADE_START + 0.6, FADE_START + blend_length)
	_cache_valid = true


## Arc length along the river where its centre line crosses into the pond
## (FADE_START inside the shore).
func shore_offset() -> float:
	if not _cache_valid:
		refresh_cache()
	return _cache.x


func _shore_offset_uncached() -> float:
	var river := get_river()
	var pond := get_pond()
	if river == null or pond == null or river.curve == null:
		return 0.0
	var length: float = river.curve.get_baked_length()
	var into := direction == Direction.RIVER_INTO_POND
	# walk from the junction end back out of the pond
	var s := length if into else 0.0
	var step := 0.1
	while s >= 0.0 and s <= length:
		var p: Vector3 = river.global_transform * river.frame_at(s)["pos"]
		if pond.inside_distance(p) < FADE_START:
			break
		s += -step if into else step
	return clampf(s, 0.0, length)


## How far inside the shore the ribbon's tip lies (the tip of the extension
## for an inlet, the river's first row for an outlet).
func _tip_inside() -> float:
	var river := get_river()
	var pond := get_pond()
	if river == null or pond == null or river.curve == null:
		return 0.0
	if direction == Direction.RIVER_INTO_POND:
		var f := river.end_frame()
		var dir: Vector3 = f["dir"]
		dir.y = 0.0
		return pond.inside_distance(f["pos"] + dir.normalized() * blend_length)
	return pond.inside_distance(river.global_transform * river.frame_at(0.0)["pos"])


## (start, end) of the fade, in metres inside the shore: it ends just before
## the ribbon's tip, so the tip itself is never seen as a line.
func _fade_range() -> Vector2:
	if not _cache_valid:
		refresh_cache()
	return Vector2(_cache.y, _cache.z)


## Per-vertex junction weights for the river ribbon at a world position:
## x = opacity (COLOR.r), y = overlap mask (COLOR.g: lift above the pond,
## river offset flattened). `side_m` is the distance to the ribbon's side.
func overlap_weights(world_pos: Vector3, side_m: float) -> Vector2:
	var pond := get_pond()
	if pond == null:
		return Vector2(1.0, 0.0)
	var inside := pond.inside_distance(world_pos)
	if inside < -(WaterPond.SKIRT + 1.5):
		return Vector2(1.0, 0.0)
	var fr := _fade_range()
	var fade := 1.0 - smoothstep(fr.x, fr.y, inside)
	# over open pond water the ribbon's sides fade as well
	fade *= lerpf(1.0, smoothstep(0.0, 0.6, side_m), smoothstep(0.0, 0.8, inside))
	# lifted wherever the pond's surface (its skirt included) may lie under it
	var lift := smoothstep(-(WaterPond.SKIRT + 1.2), -WaterPond.SKIRT + 0.1, inside)
	return Vector2(fade, lift)


## Weight of the river in blended queries near its tail.
func river_tail_weight(river: WaterRiver, s: float) -> float:
	if direction != Direction.RIVER_INTO_POND or river.curve == null:
		return 1.0
	# matches what is drawn: the river gives way to the pond inside the shore
	var span := maxf(_fade_range().y - FADE_START, 0.5)
	return 1.0 - clampf((s - shore_offset()) / span, 0.0, 1.0)


## Weight of an outgoing river in blended queries near its start.
func river_head_weight(river: WaterRiver, s: float) -> float:
	if direction != Direction.POND_INTO_RIVER:
		return 1.0
	var span := maxf(_fade_range().y - FADE_START, 0.5)
	return 1.0 - clampf((shore_offset() - s) / span, 0.0, 1.0)


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
	var hw: float = f["half_width"] + WaterRiver.MARGIN
	var level := pond.water_level()
	var length: float = river.curve.get_baked_length()

	var rows := 13
	var ax := 25
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	for r in rows:
		var t := float(r) / float(rows - 1)
		var center := c + dir * t * blend_length
		center.y = lerpf(c.y, level, t * t * (3.0 - 2.0 * t))
		for i in ax:
			var u := float(i) / float(ax - 1)
			var d := -hw + u * 2.0 * hw
			var p := center + side * d
			pos.append(p)
			nrm.append(Vector3.UP)
			tan.append_array([dir.x, dir.y, dir.z, 1.0])
			uv.append(Vector2(u, 1.0))
			uv2.append(Vector2(d, length + t * blend_length))
			# the same weights as the river's own last row: no seam where
			# the ribbon becomes the extension
			var w := overlap_weights(p, hw - absf(d))
			col.append(Color(w.x, w.y, 0.0))
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
