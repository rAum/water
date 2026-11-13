# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
@icon("../editor/icons/water_river.svg")
class_name WaterRiver
extends Path3D
## A river or stream drawn as a path. Edit the curve with the normal Path3D
## tools; drag the side handles to set the width per point. "Rebuild mesh"
## builds the ribbon, "Bake" computes the flow (water_baker.gd).
##
## The curve marks the water SURFACE line; depth comes from raycasts against
## `collision_mask` at bake time.

const ROW_STEP := 0.25                 # metres covered by one baked texture row
const MARGIN := 0.4                    # ribbon extends this far past the width
const CHUNK_LENGTH := 40.0
const SEGMENT_LENGTH := 1000.0         # max metres per baked segment
const STEEP_SLOPE := 0.15
const MESH_STEP_FLAT := 0.5
const MESH_STEP_STEEP := 0.25
const MESH_STEP_FALL := 0.1
## Metres over which the churn of a plunge pool fades downstream.
const PLUNGE_REACH := 1.6
## Metres from a pond junction within which the ribbon is checked against
## the pond (cross-fade and lift).
const JUNCTION_REACH := 14.0

## Half width in metres at each curve point.
@export var widths: PackedFloat32Array = []:
	set(v):
		widths = v
		_mark_dirty()

@export var style: WaterStyle:
	set(v):
		if style != null and style.changed.is_connected(_on_style_changed):
			style.changed.disconnect(_on_style_changed)
		style = v
		if style != null:
			style.changed.connect(_on_style_changed)
		_apply_style()

## What the bake raycasts against (terrain and rocks).
@export_flags_3d_physics var collision_mask: int = 1
## Water carried by the river (m^3/s).
@export var discharge := 1.5:
	set(v):
		discharge = v
		_mark_dirty()
## Rows steeper than this are waterfalls.
@export_range(0.1, 2.0) var waterfall_threshold := 0.3:
	set(v):
		waterfall_threshold = v
		_falls_valid = false
		_mark_dirty()
## Cells across the channel in the bake grid.
@export_range(16, 96) var cells_across := 48
## When snapping to terrain, the surface sits this high above the bed.
@export var snap_surface_height := 0.3
@export_range(0, 3) var debug_view := 0:
	set(v):
		debug_view = v
		for m in _materials():
			m.set_shader_parameter("debug_view", v)

## Dark glossy wet strips (Decal nodes) along both banks, for bank materials
## you cannot edit. Materials you can edit should use
## water_receiver.gdshaderinc instead.
@export var bank_wet_decals := false:
	set(v):
		bank_wet_decals = v
		_mark_dirty()

## Baked flow, one WaterData per segment of at most 1 km. Saved as .res next
## to the scene by the Bake button.
@export var baked_segments: Array[WaterData] = []

## Set when a collider inside the river bounds moved since the last bake.
var bake_out_of_date := false

var _material: ShaderMaterial
var _far_material: ShaderMaterial
# per-segment material clones (segment > 0 of a long river gets its own
# textures; segment 0 uses _material/_far_material directly)
var _seg_mats: Dictionary = {}
var _chunks: Array[MeshInstance3D] = []
var _chunk_segments: PackedInt32Array = []
var _dirty := true
var _spray: Node3D
var _junction_a: Node = null   # junction at the start, if any
var _junction_b: Node = null   # junction at the end, if any
var _hash_check_accum := 0.0
# world points along the feet of the falls, as drawn, and per point the
# downstream direction (world xz) with the landing speed in y
var _foot_points := PackedVector3Array()
var _foot_dirs := PackedVector3Array()

signal baked


func _ready() -> void:
	curve_changed.connect(_on_curve_changed)
	if curve == null:
		curve = Curve3D.new()
	if curve.point_count == 0 and Engine.is_editor_hint():
		curve.add_point(Vector3.ZERO)
		curve.add_point(Vector3(0, -1, 20))
	_ensure_widths()
	_make_materials()
	rebuild_mesh()
	_manager_call("register_body", self)
	if not Engine.is_editor_hint():
		_build_spray()


func _exit_tree() -> void:
	_manager_call("unregister_body", self)


func _enter_tree() -> void:
	if is_node_ready():
		_manager_call("register_body", self)


func _process(delta: float) -> void:
	_update_lod()
	if not Engine.is_editor_hint():
		_plunge_ripples(delta)
		_update_fall_hits(delta)
	if Engine.is_editor_hint():
		_hash_check_accum += delta
		if _hash_check_accum > 2.0:
			_hash_check_accum = 0.0
			_check_bake_freshness()


var _plunge_accum := 0.0

## Falling water keeps the pool below it moving: rings radiate from the
## foot of every waterfall near the camera.
func _plunge_ripples(delta: float) -> void:
	_plunge_accum += delta
	if _plunge_accum < 0.14:
		return
	_plunge_accum = 0.0
	var mgr := _manager()
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if mgr == null or cam == null:
		return
	for data in baked_segments:
		if data == null or data.mist_points.is_empty():
			continue
		var pt := data.mist_points[randi() % data.mist_points.size()]
		if cam.global_position.distance_to(pt) < 30.0:
			# (rings, not a churned trench: the sim adds them up)
			mgr.add_ripple(pt, 0.012 + randf() * 0.012, 0.4)


func _on_curve_changed() -> void:
	_falls_valid = false
	_ensure_widths()
	_mark_dirty()


func _on_style_changed() -> void:
	_apply_style()


func _mark_dirty() -> void:
	_dirty = true
	if Engine.is_editor_hint() and is_node_ready():
		rebuild_mesh()
	update_gizmos()
	update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _uphill_length() > 0.05:
		out.append("Part of the river goes uphill (%.1f m). Use \"Make downhill\"." % _uphill_length())
	if baked_segments.is_empty():
		out.append("Not baked yet. Press \"Bake\" after shaping the river.")
	elif bake_out_of_date:
		out.append("Bake is out of date: a collider inside the river bounds moved.")
	return out


# ------------------------------------------------------------------ widths --

func _ensure_widths() -> void:
	var n := curve.point_count if curve != null else 0
	while widths.size() < n:
		widths.append(widths[widths.size() - 1] if widths.size() > 0 else 2.0)
	if widths.size() > n:
		widths.resize(n)


func width_at_offset(offset: float) -> float:
	var n := curve.point_count
	if n == 0 or widths.is_empty():
		return 2.0
	if n == 1:
		return widths[0]
	# interpolate by the arc offsets of the control points
	var prev_off := 0.0
	var prev_w := widths[0]
	for p in range(1, n):
		var off := curve.get_closest_offset(curve.get_point_position(p))
		if p == n - 1:
			off = curve.get_baked_length()
		if offset <= off or p == n - 1:
			var t := 0.0 if off <= prev_off else clampf((offset - prev_off) / (off - prev_off), 0.0, 1.0)
			return lerpf(prev_w, widths[mini(p, widths.size() - 1)], t)
		prev_off = off
		prev_w = widths[mini(p, widths.size() - 1)]
	return widths[widths.size() - 1]


# ------------------------------------------------------------- frame sampling --

## Local-space frame of the surface at arc offset s.
func frame_at(s: float) -> Dictionary:
	var length := curve.get_baked_length()
	s = clampf(s, 0.0, length)
	var pos := curve.sample_baked(s, true)
	var ahead := curve.sample_baked(minf(s + 0.5, length), true)
	var behind := curve.sample_baked(maxf(s - 0.5, 0.0), true)
	var delta := ahead - behind
	var dir_h := Vector3(delta.x, 0.0, delta.z)
	if dir_h.length() < 0.001:
		dir_h = Vector3(0, 0, 1)
	dir_h = dir_h.normalized()
	var run := Vector2(delta.x, delta.z).length()
	var slope := -delta.y / maxf(run, 0.05)       # positive = downhill
	# Waterfalls: water leaves the lip level and falls in a free-fall arc
	# (a parabola from the lip to the foot), not down a ramp.
	var fall_t := 0.0
	var fallen := 0.0      # metres dropped since the lip
	if not _falls_valid:
		_update_falls()
	for f: Array in _falls:
		if s > f[0] and s < f[1]:
			var lip: Vector2 = f[4]
			fall_t = clampf(Vector2(pos.x - lip.x, pos.z - lip.y).length() / f[5], 0.0, 1.0)
			var drop: float = f[2] - f[3]
			pos.y = f[2] - drop * fall_t * fall_t
			slope = 2.0 * drop * fall_t / f[5]
			fallen = drop * fall_t * fall_t
			break
	return {
		"pos": pos, "dir": dir_h,
		"side": Vector3(dir_h.z, 0.0, -dir_h.x),
		"slope": maxf(slope, -2.0),
		"half_width": width_at_offset(s),
		"fall_t": fall_t,
		"fallen": fallen,
	}


# cached waterfall sections: [s_lip, s_foot, y_lip, y_foot, lip_xz, horizontal_run]
var _falls: Array = []
var _falls_valid := false
# per fall: centre line of the sheet, top to bottom, as
# [pos (local), dir, side, half width incl. margin] every FALL_LINE_STEP
var _fall_lines: Array = []


func _update_falls() -> void:
	_falls.clear()
	_fall_lines.clear()
	_falls_valid = true
	if curve == null or curve.get_baked_length() < 1.0:
		return
	var length := curve.get_baked_length()
	var s := 0.0
	var start := -1.0
	while s <= length:
		var a := curve.sample_baked(maxf(s - 0.25, 0.0), true)
		var b := curve.sample_baked(minf(s + 0.25, length), true)
		var raw := -(b.y - a.y) / maxf(Vector2(b.x - a.x, b.z - a.z).length(), 0.05)
		if raw > waterfall_threshold:
			if start < 0.0:
				start = maxf(s - 0.25, 0.0)
		elif start >= 0.0:
			_add_fall(start, minf(s + 0.1, length))
			start = -1.0
		s += 0.1
	if start >= 0.0:
		_add_fall(start, length)


func _add_fall(s0: float, s1: float) -> void:
	var p0 := curve.sample_baked(s0, true)
	var p1 := curve.sample_baked(s1, true)
	if p0.y - p1.y < 0.3:
		return
	var run := maxf(Vector2(p1.x - p0.x, p1.z - p0.z).length(), 0.2)
	_falls.append([s0, s1, p0.y, p1.y, Vector2(p0.x, p0.z), run])


func _uphill_length() -> float:
	if curve == null or curve.get_baked_length() < 0.1:
		return 0.0
	var total := 0.0
	var length := curve.get_baked_length()
	var s := 0.0
	var prev_y := curve.sample_baked(0.0, true).y
	while s < length:
		s = minf(s + 1.0, length)
		var y := curve.sample_baked(s, true).y
		if y > prev_y + 0.005:
			total += 1.0
		prev_y = y
	return total


# ------------------------------------------------------------ editor actions --

## Lowers points so the path only descends or stays level.
func make_downhill() -> void:
	var low := INF
	for p in curve.point_count:
		var pos := curve.get_point_position(p)
		low = minf(low, pos.y)
		if pos.y > low:
			pos.y = low
			curve.set_point_position(p, pos)
		low = pos.y
	_mark_dirty()


## Snaps every point onto the terrain below (surface sits snap_surface_height
## above the hit).
func snap_to_terrain() -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	for p in curve.point_count:
		var local := curve.get_point_position(p)
		var world := to_global(local)
		var ray := PhysicsRayQueryParameters3D.create(
			world + Vector3.UP * 50.0, world + Vector3.DOWN * 200.0, collision_mask)
		var hit := space.intersect_ray(ray)
		if not hit.is_empty():
			local.y = to_local(hit["position"]).y + snap_surface_height
			curve.set_point_position(p, local)
	_mark_dirty()


# -------------------------------------------------------------------- meshing --

func rebuild_mesh() -> void:
	for c in _chunks:
		if is_instance_valid(c):
			c.queue_free()
	_chunks.clear()
	_foot_points.clear()
	_foot_dirs.clear()
	_chunk_segments = PackedInt32Array()
	if curve == null or curve.get_baked_length() < 1.0:
		return
	var length := curve.get_baked_length()
	for j in [_junction_a, _junction_b]:
		if j != null and is_instance_valid(j) and j.has_method("refresh_cache"):
			j.refresh_cache()

	# adaptive row positions: 0.5 m, 0.25 m above 15 % slope, 0.1 m on falls
	var row_s := PackedFloat32Array()
	var s := 0.0
	row_s.append(0.0)
	while s < length:
		var f := frame_at(s)
		var slope: float = f["slope"]
		var step := MESH_STEP_FLAT
		if slope > waterfall_threshold:
			step = MESH_STEP_FALL
		elif slope > STEEP_SLOPE:
			step = MESH_STEP_STEEP
		if not _fall_near(s + 0.5).is_empty():
			# columns leave the ground up to a few metres above the lip, each
			# at its own row: the brink runs across the ribbon at a slant, and
			# only fine rows bend the sheet over it without a sawtooth
			step = MESH_STEP_FALL
		s = minf(s + step, length)
		row_s.append(s)

	# emit chunks of about 40 m, all sharing one material
	var chunk_start := 0
	while chunk_start < row_s.size() - 1:
		var chunk_end := chunk_start
		while chunk_end < row_s.size() - 1 and row_s[chunk_end] - row_s[chunk_start] < CHUNK_LENGTH:
			chunk_end += 1
		_build_chunk(row_s, chunk_start, chunk_end)
		chunk_start = chunk_end
	_rebuild_bank_decals()
	_dirty = false
	_apply_style()


static var _bank_decal_tex: ImageTexture

static func _bank_decal_texture() -> ImageTexture:
	if _bank_decal_tex != null:
		return _bank_decal_tex
	var n := 32
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		# dark band fading upward (v = 0 at the waterline)
		var a := clampf(1.0 - float(y) / float(n - 1), 0.0, 1.0)
		for x in n:
			img.set_pixel(x, y, Color(0.06, 0.07, 0.08, a * a * 0.55))
	_bank_decal_tex = ImageTexture.create_from_image(img)
	return _bank_decal_tex


var _bank_decals: Array[Decal] = []

func _rebuild_bank_decals() -> void:
	for d in _bank_decals:
		if is_instance_valid(d):
			d.queue_free()
	_bank_decals.clear()
	if not bank_wet_decals or curve == null or curve.get_baked_length() < 2.0:
		return
	var length := curve.get_baked_length()
	var s := 2.0
	while s < length - 2.0:
		var f := frame_at(s)
		for sign_v in [-1.0, 1.0]:
			var d := Decal.new()
			d.texture_albedo = _bank_decal_texture()
			d.size = Vector3(4.0, 1.4, 1.6)
			d.cull_mask = 0xFFFFF
			var c: Vector3 = f["pos"] + f["side"] * (f["half_width"] + MARGIN * 0.5) * sign_v
			add_child(d, false, Node.INTERNAL_MODE_BACK)
			d.position = c + Vector3.UP * 0.35
			var dir3: Vector3 = f["dir"]
			d.rotation.y = atan2(dir3.x, dir3.z)
			_bank_decals.append(d)
		s += 4.0


func _build_chunk(row_s: PackedFloat32Array, first: int, last: int) -> void:
	var ax := cells_across + 1
	var rows := last - first + 1
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	# CUSTOM0: (seconds since the water left the lip, its speed in m/s,
	# metres fallen, plunge) - the shader scrolls the falling water's texture
	# on time of flight, so it stretches as the water accelerates; plunge
	# (1 where a fall lands, fading downstream) churns the pool under it
	var flight := PackedFloat32Array()
	flight.resize(ax * rows * 4)
	pos.resize(ax * rows)
	nrm.resize(ax * rows)
	tan.resize(ax * rows * 4)
	uv.resize(ax * rows)
	uv2.resize(ax * rows)
	col.resize(ax * rows)
	# sheet thickness per vertex (0 = not in the air) and which rows fall
	var thick := PackedFloat32Array()
	thick.resize(ax * rows)
	var row_air := PackedByteArray()
	row_air.resize(rows)
	var state := PackedByteArray()     # per vertex: 1 = in the air, 2 = landed
	state.resize(ax * rows)
	var v0 := _brink_speed()
	var p := 0
	var length := curve.get_baked_length()
	var gt := global_transform if is_inside_tree() else transform
	var space: PhysicsDirectSpaceState3D = null
	if is_inside_tree() and get_world_3d() != null:
		space = get_world_3d().direct_space_state
	for r in rows:
		var s := row_s[first + r]
		var f := frame_at(s)
		# where this river runs into or out of a pond, the ribbon cross-fades
		# with the pond's surface (only over it) and rides just above it
		var junction: Node = null
		if _junction_b != null and is_instance_valid(_junction_b) and length - s < JUNCTION_REACH:
			junction = _junction_b
		elif _junction_a != null and is_instance_valid(_junction_a) and s < JUNCTION_REACH:
			junction = _junction_a
		if junction != null and not junction.has_method("overlap_weights"):
			junction = null
		var c: Vector3 = f["pos"]
		var side: Vector3 = f["side"]
		var dir: Vector3 = f["dir"]
		var hw: float = f["half_width"] + MARGIN
		# segment-local texture v
		var seg := _segment_of(s)
		var seg_range := _segment_range(seg)
		var v := (s - seg_range.x) / maxf(seg_range.y - seg_range.x, 0.001)
		# A waterfall is not one straight line across the ribbon: the bake
		# knows where each column's bed drops away (its brink can lie upstream
		# of the lip) and how far its speed throws it, so every column gets its
		# own free-fall arc.
		var fall := _fall_near(s)
		var data: WaterData = baked_segments[seg] if seg < baked_segments.size() else null
		var has_cols := data != null and data.fall_lead.size() == data.cells_across * data.rows \
			and data.fall_sheet.size() == data.fall_lead.size() \
			and data.fall_wet.size() == data.fall_lead.size()
		var fj := (s - seg_range.x) / ROW_STEP
		var along := 0.0     # metres the row's centre is past the lip (negative above it)
		if not fall.is_empty():
			along = float(f["fall_t"]) * float(fall[5]) if s > fall[0] else s - float(fall[0])
		# Where each column leaves the brink (lead) and how far it is thrown
		# vary from cell to cell in the bake; taken raw, neighbouring columns
		# fall at different rates and the sheet folds into teeth. Smoothed
		# across the ribbon (the brink a gentle curve, the throw a broad
		# swell), every column bends over the lip like its neighbours.
		var row_lead := PackedFloat32Array()
		var row_throw := PackedFloat32Array()
		if not fall.is_empty() and has_cols:
			row_lead.resize(ax)
			row_throw.resize(ax)
			var jn0 := float(clampi(roundi(fj), 0, data.rows - 1))
			for i in ax:
				var fi0 := float(i) / float(ax - 1) * float(cells_across) - 0.5
				row_lead[i] = data.sample_array(data.fall_lead, fi0, jn0)
				row_throw[i] = clampf(data.sample_array(data.fall_throw, fi0, jn0), 0.4, 1.0)
			row_lead = _smooth_across(row_lead, 3)
			row_throw = _smooth_across(row_throw, 9)
		for i in ax:
			var u := float(i) / float(ax - 1)
			var d := -hw + u * 2.0 * hw
			var y := c.y
			var slope: float = f["slope"]
			var ft := 0.0
			var th := 0.0
			var wet := 1.0
			var t_fl := 0.0
			var spd := v0
			var fallen_v := 0.0
			var plunge := _plunge_at(s)
			if not fall.is_empty():
				var lead := 0.0
				var throw := 1.0
				var fi := u * float(cells_across) - 0.5
				if has_cols:
					lead = row_lead[i]
					wet = smoothstep(0.1, 0.7, data.sample_array(data.fall_wet, fi, fj))
					throw = row_throw[i]
				var x := along + lead
				# A rock standing on the brink parts the sheet: the bake
				# fills the rock's own cells with the water around it (no
				# holes in the river), but where the water goes over the
				# edge that fill would be drawn as a white film across the
				# rock's lower ledges.
				if has_cols and x > -0.25 and data.obstacle.size() == data.cells_across * data.rows:
					wet *= 1.0 - smoothstep(0.35, 0.8, _sample_bytes(data, data.obstacle, fi, fj))
				var run: float = float(fall[5]) * throw
				var drop: float = float(fall[2]) - float(fall[3])
				if s > fall[0]:
					y = fall[2]
					slope = 0.0
				# before the lip: still the river, arriving at the brink speed
				t_fl = minf(x, 0.0) / v0
				if x > 0.0 and x < run:
					ft = x / run
					var fallen := drop * ft * ft
					fallen_v = fallen
					t_fl = sqrt(2.0 * fallen / 9.81)
					spd = sqrt(v0 * v0 + 19.62 * fallen)
					y -= fallen
					slope = 2.0 * drop * ft / run
					if has_cols:
						th = data.sample_array(data.fall_sheet, fi, fj)
					else:
						# not baked yet: an even sheet that thins toward its edges
						var t0 := clampf(discharge / (v0 * 2.0 * float(f["half_width"])), 0.1, 0.7)
						th = maxf(t0 * v0 / sqrt(v0 * v0 + 19.62 * fallen), 0.035) \
							* smoothstep(0.0, 0.25, minf(u, 1.0 - u))
						wet = smoothstep(0.0, 0.02, th)
					row_air[r] = 1
					state[p] = 1
				elif x >= run:
					state[p] = 2
					# landed: this is the pool now, water across the whole
					# ribbon (the sheet's mask only says where it falls)
					wet = 1.0
					fallen_v = drop
					spd = sqrt(v0 * v0 + 19.62 * drop)
					t_fl = sqrt(2.0 * drop / 9.81) + (x - run) / spd
					plunge = exp(-(x - run) / PLUNGE_REACH)
					# landed already: pool at the foot of the fall
					y = fall[3]
					slope = 0.0
			var t3 := (dir + Vector3.DOWN * slope).normalized()
			var n3 := side.cross(t3).normalized()
			if n3.y < 0.0:
				n3 = -n3
			pos[p] = Vector3(c.x, y, c.z) + side * d
			nrm[p] = n3
			tan[p * 4] = t3.x
			tan[p * 4 + 1] = t3.y
			tan[p * 4 + 2] = t3.z
			tan[p * 4 + 3] = 1.0
			uv[p] = Vector2(u, v)
			uv2[p] = Vector2(d, s)
			thick[p] = th
			flight[p * 4] = t_fl
			flight[p * 4 + 1] = spd
			flight[p * 4 + 2] = fallen_v
			flight[p * 4 + 3] = plunge * wet
			# in the air the ribbon only exists where there is water: red
			# fades it out past the edges of the sheet
			col[p] = Color(wet, 0.0, ft)
			# A sheet whose arc meets a rock (one standing in the pool under
			# the fall) breaks on it: it ends there instead of skimming a
			# finger above the rock's top, where its white would show as
			# slivers on the stone.
			if state[p] == 1 and ft > 0.2 and space != null:
				var wp := gt * pos[p]
				var ray := PhysicsRayQueryParameters3D.create(
					wp + Vector3.UP * 0.6, wp + Vector3.DOWN * 4.0, collision_mask)
				var hit := space.intersect_ray(ray)
				if not hit.is_empty():
					col[p].r *= smoothstep(0.04, 0.2, wp.y - (hit["position"] as Vector3).y)
			if junction != null:
				var jw: Vector2 = junction.overlap_weights(gt * pos[p], hw - absf(d))
				col[p].r *= jw.x
				col[p].g = jw.y
			p += 1
	# Columns land at different places, so along the foot of the fall a
	# vertex still in the air has neighbours already on the pool. Those are
	# the sheet's foot (progress 1): the shader turns it into the ragged,
	# boiling white where the fall hits the pool (fading the ribbon out here
	# instead leaves a see-through gap between the sheet and the pool).
	for r in rows:
		for i in ax:
			var q := r * ax + i
			if state[q] != 2:
				continue
			if (r > 0 and state[q - ax] == 1) or (i > 0 and state[q - 1] == 1) \
					or (i < ax - 1 and state[q + 1] == 1):
				col[q].b = 1.0
				# where the sheet hits the pool: spray and mist rise here
				if col[q].r > 0.3:
					var dq := gt.basis * Vector3(tan[q * 4], 0.0, tan[q * 4 + 2])
					dq = Vector3(dq.x, 0.0, dq.z).normalized()
					_foot_points.append(gt * pos[q])
					_foot_dirs.append(Vector3(dq.x, flight[q * 4 + 1], dq.z))
	# A waterfall is a sheet with thickness: an upper surface (the ribbon)
	# and a lower one behind it. The sheet is as thick as the flow at the
	# brink and thins as it speeds up (thickness x speed stays constant); at
	# its side edges the thickness runs out, so the two surfaces close.
	var back_first := -1
	var back_rows := PackedInt32Array()
	for r in rows:
		if row_air[r] == 1 or (r + 1 < rows and row_air[r + 1] == 1) or (r > 0 and row_air[r - 1] == 1):
			back_rows.append(r)
	var idx := PackedInt32Array()
	if back_rows.size() >= 2:
		back_first = pos.size()
		for br in back_rows.size():
			var r := back_rows[br]
			for i in ax:
				var src := r * ax + i
				# (never exactly in the upper surface: the two would fight
				# for the same depth and tear a crack along the brink)
				pos.append(pos[src] - nrm[src] * maxf(thick[src], 0.02))
				nrm.append(-nrm[src])
				tan.append_array([tan[src * 4], tan[src * 4 + 1], tan[src * 4 + 2], tan[src * 4 + 3]])
				uv.append(uv[src])
				uv2.append(uv2[src])
				flight.append_array([flight[src * 4], flight[src * 4 + 1], flight[src * 4 + 2], 0.0])
				# alpha 0 marks the lower surface
				col.append(Color(col[src].r, col[src].g, col[src].b, 0.0))
		# the lower surface is drawn first, the upper one over it
		for br in back_rows.size() - 1:
			if back_rows[br + 1] != back_rows[br] + 1:
				continue
			for i in ax - 1:
				# only where the sheet has thickness: a lower surface lying
				# in the upper one would hide it
				var q := back_rows[br] * ax + i
				if thick[q] <= 0.0 and thick[q + 1] <= 0.0 and thick[q + ax] <= 0.0 and thick[q + ax + 1] <= 0.0:
					continue
				var a := back_first + br * ax + i
				if absf(pos[a].y - pos[a + ax + 1].y) < absf(pos[a + 1].y - pos[a + ax].y) - 0.002:
					idx.append_array([a, a + ax + 1, a + ax, a, a + 1, a + ax + 1])
				else:
					idx.append_array([a, a + 1, a + ax, a + 1, a + ax + 1, a + ax])
	for r in rows - 1:
		for i in ax - 1:
			var a := r * ax + i
			# split each quad along the diagonal whose ends lie at the more
			# similar height: across a slanted brink that diagonal follows the
			# bend, and the quad does not fold into a tooth
			if absf(pos[a].y - pos[a + ax + 1].y) < absf(pos[a + 1].y - pos[a + ax].y) - 0.002:
				idx.append_array([a, a + ax, a + ax + 1, a, a + ax + 1, a + 1])
			else:
				idx.append_array([a, a + ax, a + 1, a + 1, a + ax, a + ax + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TANGENT] = tan
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_CUSTOM0] = flight
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _material
	# water is see-through: as a shadow caster it would be dithered, which
	# speckles the falling sheet with its own shadow
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# room for vertex waves and surface offset
	mi.custom_aabb = mesh.get_aabb().grow(0.6)
	add_child(mi, false, Node.INTERNAL_MODE_BACK)
	_chunks.append(mi)
	_chunk_segments.append(_segment_of(row_s[first]))


## Bilinear sample of a per-cell byte mask (0/1) as a float.
static func _sample_bytes(data: WaterData, arr: PackedByteArray, fi: float, fj: float) -> float:
	fi = clampf(fi, 0.0, float(data.cells_across) - 1.001)
	fj = clampf(fj, 0.0, float(data.rows) - 1.001)
	var i := int(fi)
	var j := int(fj)
	var tx := fi - float(i)
	var tz := fj - float(j)
	var k := j * data.cells_across + i
	var a := float(arr[k]) * (1.0 - tx) + float(arr[k + 1]) * tx
	var b := float(arr[k + data.cells_across]) * (1.0 - tx) + float(arr[k + data.cells_across + 1]) * tx
	return a * (1.0 - tz) + b * tz


## Box-smooths a row of per-column values (radius in columns), twice: a
## tent filter that keeps the row's ends in place.
static func _smooth_across(src: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var cur := src
	var n := src.size()
	for pass_n in 2:
		var out := PackedFloat32Array()
		out.resize(n)
		for i in n:
			var sum := 0.0
			var cnt := 0.0
			for k in range(maxi(i - radius, 0), mini(i + radius, n - 1) + 1):
				sum += cur[k]
				cnt += 1.0
			out[i] = sum / cnt
		cur = out
	return cur


## Churn of the pool below a fall, for a row past the fall's foot (1 at the
## foot, fading downstream).
func _plunge_at(s: float) -> float:
	if not _falls_valid:
		_update_falls()
	for f: Array in _falls:
		if s >= f[1] and s < f[1] + PLUNGE_REACH * 4.0:
			return exp(-(s - f[1]) / PLUNGE_REACH)
	return 0.0


## The waterfall section a row belongs to: on its arc, or within the few
## metres above the lip where a column may already have left the ground.
func _fall_near(s: float) -> Array:
	if not _falls_valid:
		_update_falls()
	for f: Array in _falls:
		if s > f[0] - 3.0 and s < f[1]:
			return f
	return []


## Speed of the water as it reaches a waterfall's brink: from the bake when
## there is one, otherwise a typical stream speed.
func _brink_speed() -> float:
	if not baked_segments.is_empty() and baked_segments[0] != null and baked_segments[0].row_mean_speed.size() > 0:
		var data := baked_segments[0]
		for j in range(1, data.rows):
			if data.row_slope[j] > waterfall_threshold:
				return clampf(data.row_mean_speed[j - 1], 0.8, 4.0)
	return 1.6


# ------------------------------------------------------- bodies in the falls --

const FALL_LINE_STEP := 0.05
const FALL_BLOCKER_GROUP := &"flowing_water_fall_blockers"
## Bodies further than this from the camera do not part the falls.
const FALL_HIT_DISTANCE := 40.0

var _fall_hits: WaterFallHits
var _fall_splash: GPUParticles3D
var _fall_hit_range := Vector2(-1.0, -1.0)
var _fall_hit_was_on := true


func _fall_line(fi: int) -> Array:
	if not _falls_valid:
		_update_falls()
	while _fall_lines.size() < _falls.size():
		var f: Array = _falls[_fall_lines.size()]
		var line := []
		var s: float = f[0]
		while s <= float(f[1]):
			var fr := frame_at(s)
			line.append([fr["pos"], fr["dir"], fr["side"], float(fr["half_width"]) + MARGIN])
			s += FALL_LINE_STEP
		_fall_lines.append(line)
	return _fall_lines[fi]


## Where a body standing in a fall meets the sheet: the topmost point of
## the sheet's centre line inside the body. Returns [] when it is not in
## the water, else [t_flight, u, half_width_u, contact (local)].
func _fall_contact(fi: int, bottom: Vector3, top_y: float, radius: float) -> Array:
	var f: Array = _falls[fi]
	for e: Array in _fall_line(fi):
		var c: Vector3 = e[0]
		if c.y > top_y + 0.05:
			continue
		if c.y < bottom.y - 0.05:
			break
		var rel := bottom - c
		var dir: Vector3 = e[1]
		var side: Vector3 = e[2]
		var hw: float = e[3]
		# (the sheet has a thickness and wobbles: a little slack)
		if absf(rel.x * dir.x + rel.z * dir.z) > radius + 0.15:
			continue
		var d := rel.x * side.x + rel.z * side.z
		if absf(d) > hw:
			continue
		var t := sqrt(2.0 * maxf(float(f[2]) - c.y, 0.0) / 9.81)
		return [t, (d + hw) / (2.0 * hw), radius / (2.0 * hw), c + side * d]
	return []


func _update_fall_hits(delta: float) -> void:
	if not _falls_valid:
		_update_falls()
	if _falls.is_empty():
		return
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	if _fall_hits == null:
		_fall_hits = WaterFallHits.new()
	elif not _fall_hits.active and not _fall_hit_was_on \
			and get_tree().get_first_node_in_group(FALL_BLOCKER_GROUP) == null:
		return
	_fall_hits.step(delta)
	var inv := global_transform.affine_inverse()
	var cam_l := inv * cam.global_position
	# one grid per river: it follows the fall nearest the camera
	var best := -1
	var best_d := FALL_HIT_DISTANCE
	for fi in _falls.size():
		var f: Array = _falls[fi]
		var lip := Vector3(f[4].x, f[2], f[4].y)
		var dd := cam_l.distance_to(lip)
		if dd < best_d:
			best_d = dd
			best = fi
	var contact := Vector3.INF
	var contact_dir := Vector3.FORWARD
	if best >= 0:
		var f: Array = _falls[best]
		for node in get_tree().get_nodes_in_group(FALL_BLOCKER_GROUP):
			if not node.has_method("fall_blocker_shapes"):
				continue
			for shape: Array in node.fall_blocker_shapes():
				# [bottom (world), top_y (world), radius]
				var b: Vector3 = inv * (shape[0] as Vector3)
				var top_y: float = (inv * Vector3(shape[0].x, shape[1], shape[0].z)).y
				var hit := _fall_contact(best, b, top_y, float(shape[2]))
				if hit.is_empty():
					continue
				_fall_hits.mark(hit[0], hit[1] - hit[2], hit[1] + hit[2], 1.0)
				if contact == Vector3.INF or (hit[3] as Vector3).y > contact.y:
					contact = hit[3]
					contact_dir = _fall_line(best)[0][1]
		_fall_hit_range = Vector2(float(f[0]) - 1.0, float(f[1]) + 0.5)
	_fall_hits.upload()
	# the shader only needs the clock while there is a gap to draw
	var on := _fall_hits.active
	if not on and not _fall_hit_was_on:
		_update_fall_splash(contact, contact_dir)
		return
	_fall_hit_was_on = on
	for m in _all_materials():
		# (a quality or style change rebuilds the materials: bind anew)
		if m.get_shader_parameter("fall_hit_tex") != _fall_hits.texture:
			m.set_shader_parameter("fall_hit_tex", _fall_hits.texture)
			m.set_shader_parameter("fall_hit_rows", float(WaterFallHits.ROWS))
			m.set_shader_parameter("fall_hit_dt", WaterFallHits.ROW_DT)
		m.set_shader_parameter("fall_hit_s", _fall_hit_range)
		m.set_shader_parameter("fall_hit_head", _fall_hits.head)
		m.set_shader_parameter("fall_hit_on", 1.0 if on else 0.0)
	_update_fall_splash(contact, contact_dir)


## Water hitting a body in a fall bursts off it in a spray of drops.
func _update_fall_splash(contact: Vector3, dir: Vector3) -> void:
	if contact == Vector3.INF:
		if _fall_splash != null:
			_fall_splash.emitting = false
		return
	if _fall_splash == null:
		_fall_splash = _make_fall_splash()
		add_child(_fall_splash, false, Node.INTERNAL_MODE_BACK)
	_fall_splash.position = contact
	var pm := _fall_splash.process_material as ParticleProcessMaterial
	# thrown out of the sheet, forward and to the sides, then falling
	pm.direction = (global_transform.basis * (dir + Vector3.UP * 0.6)).normalized()
	_fall_splash.emitting = true


func _make_fall_splash() -> GPUParticles3D:
	var em := GPUParticles3D.new()
	em.amount = 160
	em.lifetime = 0.9
	em.local_coords = false
	em.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.15
	pm.direction = Vector3(0, 0.5, 1)
	pm.spread = 75.0
	pm.initial_velocity_min = 1.2
	pm.initial_velocity_max = 3.4
	pm.gravity = Vector3(0, -9.8, 0)
	pm.damping_min = 0.4
	pm.damping_max = 1.2
	pm.scale_min = 0.025
	pm.scale_max = 0.09
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.85))
	fade.set_color(1, Color(1, 1, 1, 0.0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	em.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(0.92, 0.94, 0.95)
	m.albedo_texture = WaterSprayFactory._soft_circle()
	m.disable_receive_shadows = true
	quad.material = m
	em.draw_pass_1 = quad
	em.custom_aabb = AABB(Vector3(-4, -6, -4), Vector3(8, 10, 8))
	return em


## Every material this river draws with (segment clones included).
func _all_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for m in _materials():
		if m != null:
			out.append(m)
	for pair: Array in _seg_mats.values():
		for m in pair:
			out.append(m)
	return out


# ------------------------------------------------------------------- segments --

func segment_count() -> int:
	if curve == null:
		return 0
	return maxi(1, int(ceil(curve.get_baked_length() / SEGMENT_LENGTH)))


func _segment_of(s: float) -> int:
	return clampi(int(s / SEGMENT_LENGTH), 0, segment_count() - 1)


## Returns (start_s, end_s) of a segment, with one ROW_STEP of overlap into
## the previous segment so there is no seam.
func _segment_range(seg: int) -> Vector2:
	var start := float(seg) * SEGMENT_LENGTH
	if seg > 0:
		start -= ROW_STEP
	var end := minf(float(seg + 1) * SEGMENT_LENGTH, curve.get_baked_length())
	return Vector2(start, end)


# ----------------------------------------------------------------------- bake --

## Main-thread part: builds geometry rows and raycast depths for one segment.
func prepare_bake_data(seg: int) -> WaterData:
	var data := WaterData.new()
	var rng := _segment_range(seg)
	var n_rows := maxi(int(ceil((rng.y - rng.x) / ROW_STEP)) + 1, 2)
	data.cells_across = cells_across
	data.rows = n_rows
	data.cell_length = ROW_STEP
	data.is_pond_grid = false
	data.row_cell_width.resize(n_rows)
	data.row_slope.resize(n_rows)
	data.row_height.resize(n_rows)
	data.row_center.resize(n_rows)
	data.row_dir.resize(n_rows)
	data.row_half_width.resize(n_rows)
	data.row_fall_t.resize(n_rows)
	data.depth.resize(cells_across * n_rows)
	data.row_mean_speed.resize(n_rows)

	var space := get_world_3d().direct_space_state
	var gt := global_transform
	for j in n_rows:
		var s := clampf(rng.x + float(j) * ROW_STEP, 0.0, curve.get_baked_length())
		var f := frame_at(s)
		var c_world: Vector3 = gt * f["pos"]
		var dir_world: Vector3 = (gt.basis * f["dir"]).normalized()
		dir_world.y = 0.0
		dir_world = dir_world.normalized() if dir_world.length() > 0.001 else Vector3(0, 0, 1)
		var side_world := Vector3(dir_world.z, 0.0, -dir_world.x)
		var hw: float = f["half_width"] + MARGIN
		data.row_center[j] = c_world
		data.row_dir[j] = dir_world
		data.row_half_width[j] = hw
		data.row_height[j] = c_world.y
		data.row_slope[j] = maxf(f["slope"], 0.0)
		data.row_fall_t[j] = f["fall_t"]
		data.row_cell_width[j] = 2.0 * hw / float(cells_across)
		var cw := data.row_cell_width[j]
		for i in cells_across:
			var d := -hw + (float(i) + 0.5) * cw
			var cell_pos := c_world + side_world * d
			cell_pos.y = c_world.y
			var dep := 4.0
			if space != null:
				# The shallowest of five rays over the cell's footprint: a
				# rock's cap that lies between two cell centres (rows are a
				# quarter metre apart) must still count, or the flow is solved
				# straight through a rock that visibly stands in the water.
				for o: Vector2 in [Vector2.ZERO, Vector2(0.35, 0.0), Vector2(-0.35, 0.0),
						Vector2(0.0, 0.4), Vector2(0.0, -0.4)]:
					var at := cell_pos + side_world * (o.x * cw) + dir_world * (o.y * ROW_STEP)
					var ray := PhysicsRayQueryParameters3D.create(
						at + Vector3.UP * 1.5, at + Vector3.DOWN * 8.0, collision_mask)
					var hit := space.intersect_ray(ray)
					if not hit.is_empty():
						dep = minf(dep, c_world.y - hit["position"].y)
			else:
				dep = 0.0
			data.depth[j * cells_across + i] = dep
	return data


## Main-thread phase: raycast grids for every segment plus the inlet profile
## from an upstream junction. Returns [datas, first_inlet].
func prepare_all_bakes() -> Array:
	WaterBaker.warm_shader_cache()
	var datas: Array[WaterData] = []
	for seg in segment_count():
		datas.append(prepare_bake_data(seg))
	var first_inlet: Array = []
	if _junction_a != null and _junction_a.has_method("river_inlet_profile"):
		first_inlet = _junction_a.river_inlet_profile(self)
	return [datas, first_inlet]


## Pure math over the prepared grids; safe to run on a worker thread.
## Segments chain: each starts from the previous one's last row.
func solve_prepared(datas: Array, first_inlet: Array, progress: Callable = Callable()) -> void:
	var inlet_flux := PackedFloat32Array()
	var inlet_foam := PackedFloat32Array()
	var inlet_aer := PackedFloat32Array()
	if first_inlet.size() == 3:
		inlet_flux = first_inlet[0]
		inlet_foam = first_inlet[1]
		inlet_aer = first_inlet[2]
	for seg in datas.size():
		var data: WaterData = datas[seg]
		var params := WaterBaker.BakeParams.new()
		params.discharge = discharge
		params.waterfall_threshold = waterfall_threshold
		params.inlet_flux = inlet_flux
		params.inlet_foam = inlet_foam
		params.inlet_aeration = inlet_aer
		var seg_progress := Callable()
		if progress.is_valid():
			var base := float(seg) / float(datas.size())
			var span := 1.0 / float(datas.size())
			seg_progress = func(f: float, phase: String) -> void:
				progress.call(base + f * span, phase)
		WaterBaker.bake(data, params, seg_progress)
		inlet_flux = _row_fluxes(data, data.rows - 1)
		inlet_foam = _row_array(data.foam, data, data.rows - 1)
		inlet_aer = _row_array(data.aeration, data, data.rows - 1)


## Main-thread phase: textures, assignment, freshness hash, spray.
func finalize_bake(datas: Array) -> void:
	baked_segments.clear()
	for data: WaterData in datas:
		data.build_textures()
		baked_segments.append(data)
	bake_out_of_date = false
	rebuild_mesh()
	_remember_scene_hash()
	_bind_baked_textures()
	_apply_style()
	update_configuration_warnings()
	_invalidate_map()
	if not Engine.is_editor_hint():
		_build_spray()
	baked.emit()


## Convenience: the whole bake on the calling thread (runtime / CLI use).
func bake_segments_blocking(progress: Callable = Callable()) -> void:
	var prep := prepare_all_bakes()
	solve_prepared(prep[0], prep[1], progress)
	finalize_bake(prep[0])


static func _row_fluxes(data: WaterData, j: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(data.cells_across)
	for i in data.cells_across:
		var k := j * data.cells_across + i
		out[i] = data.vel_along[k] * data.depth[k] * data.row_cell_width[j]
	return out


static func _row_array(arr: PackedFloat32Array, data: WaterData, j: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(data.cells_across)
	for i in data.cells_across:
		out[i] = arr[j * data.cells_across + i]
	return out


## Saves the baked segments as .res files. With no argument they go next
## to the edited scene ("<scene>_<node>_water_N.res"); pass a base path
## (without extension) to choose the location.
func save_baked_data(base_path: String = "") -> void:
	if base_path == "":
		var scene := get_tree().edited_scene_root if Engine.is_editor_hint() else null
		base_path = "res://" + String(name)
		if scene != null and scene.scene_file_path != "":
			base_path = scene.scene_file_path.get_base_dir() + "/" \
				+ scene.scene_file_path.get_file().get_basename() + "_" + String(name)
	for seg in baked_segments.size():
		var data := baked_segments[seg]
		if data == null:
			continue
		var path := base_path + "_water_%d.res" % seg
		data.take_over_path(path)
		ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS)


# ---------------------------------------------------------------- freshness --

func _scene_root() -> Node:
	if owner != null:
		return owner
	if Engine.is_editor_hint():
		return get_tree().edited_scene_root
	return get_tree().current_scene


func _collider_hash() -> int:
	if curve == null or curve.get_baked_length() < 1.0:
		return 0
	return WaterBaker.collider_hash(_scene_root(), get_water_aabb().grow(1.0),
		collision_mask, global_transform)


func _remember_scene_hash() -> void:
	for data in baked_segments:
		if data != null:
			data.scene_hash = _collider_hash()


func _check_bake_freshness() -> void:
	if baked_segments.is_empty() or baked_segments[0] == null:
		return
	var fresh := _collider_hash() == baked_segments[0].scene_hash
	if bake_out_of_date == fresh:
		bake_out_of_date = not fresh
		update_configuration_warnings()


# ------------------------------------------------------------------ materials --

func _make_materials() -> void:
	_material = ShaderMaterial.new()
	_far_material = ShaderMaterial.new()
	_refresh_shaders()


func _refresh_shaders() -> void:
	var mgr := _manager()
	var variant := style.shader_variant if style != null else WaterStyle.Variant.REALISTIC
	if mgr != null:
		_material.shader = mgr.shader_for(variant, false)
		_far_material.shader = mgr.shader_for(variant, true)
	else:
		_material.shader = load(WaterRiver._shader_fallback(variant))
		_far_material.shader = load("res://addons/flowing_water/render/water_far.gdshader")
	_bind_baked_textures()


static func _shader_fallback(variant: int) -> String:
	return "res://addons/flowing_water/render/water_stylized.gdshader" \
		if variant == WaterStyle.Variant.STYLIZED \
		else "res://addons/flowing_water/render/water_full.gdshader"


func _materials() -> Array[ShaderMaterial]:
	return [_material, _far_material]


func _apply_style() -> void:
	if _material == null:
		return
	_refresh_shaders()
	for m in _materials():
		if style != null:
			style.apply_to_material(m)
			style.apply_to_material(m, "style_b_")
		var mgr := _manager()
		if mgr != null:
			m.set_shader_parameter("vertex_wave_max_dist", mgr.vertex_wave_distance())
		m.set_shader_parameter("debug_view", debug_view)
		if _manager() != null:
			m.set_shader_parameter("noise_tex", _manager().noise_texture)
			m.set_shader_parameter("fall_tex", _manager().fall_texture)
	# a junction owns the second style and the blend uniforms: restore them
	for j in [_junction_a, _junction_b]:
		if j != null and is_instance_valid(j) and j.has_method("_update_blend"):
			j._update_blend()


func apply_quality() -> void:
	_apply_style()


func _bind_baked_textures() -> void:
	if baked_segments.is_empty() or baked_segments[0] == null:
		return
	for m in _materials():
		m.set_shader_parameter("flow_tex", baked_segments[0].flow_tex)
		m.set_shader_parameter("aux_tex", baked_segments[0].aux_tex)
	_seg_mats.clear()


## Near/far materials for a segment; segment 0 shares the river materials,
## later segments of a long river get clones with their own textures.
func _segment_materials(seg: int) -> Array:
	if seg == 0 or seg >= baked_segments.size() or baked_segments[seg] == null:
		return [_material, _far_material]
	if not _seg_mats.has(seg):
		var near := _material.duplicate() as ShaderMaterial
		var far := _far_material.duplicate() as ShaderMaterial
		near.set_shader_parameter("flow_tex", baked_segments[seg].flow_tex)
		near.set_shader_parameter("aux_tex", baked_segments[seg].aux_tex)
		far.set_shader_parameter("flow_tex", baked_segments[seg].flow_tex)
		far.set_shader_parameter("aux_tex", baked_segments[seg].aux_tex)
		_seg_mats[seg] = [near, far]
	return _seg_mats[seg]


# ------------------------------------------------------------------------ LOD --

func _update_lod() -> void:
	if _chunks.is_empty():
		return
	var cam: Camera3D = null
	if Engine.is_editor_hint():
		# via the singleton: EditorInterface does not exist in export templates
		var ei: Object = Engine.get_singleton("EditorInterface")
		var vp: Viewport = ei.get_editor_viewport_3d(0) if ei != null else null
		cam = vp.get_camera_3d() if vp != null else null
	else:
		cam = get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	var mgr := _manager()
	var far_dist: float = (mgr.vertex_wave_distance() * 1.5 + 50.0) if mgr != null else 110.0
	for n in _chunks.size():
		var c := _chunks[n]
		if not is_instance_valid(c):
			continue
		var mats := _segment_materials(_chunk_segments[n] if n < _chunk_segments.size() else 0)
		var d := cam.global_position.distance_to(c.global_transform * c.custom_aabb.get_center())
		# hysteresis so the switch never flickers; the far variant only drops
		# effects that have already faded out by this distance, so no pop
		var is_far: bool = c.material_override == mats[1]
		var want_far := d > (far_dist * 0.9 if is_far else far_dist * 1.1)
		c.material_override = mats[1] if want_far else mats[0]


# -------------------------------------------------------------------- queries --

## Returns [] when the position is outside this river, else
## [surface_height, flow (Vector3, world), depth, weight].
func query_water(world_pos: Vector3) -> Array:
	if baked_segments.is_empty() or curve == null:
		return []
	var local := to_local(world_pos)
	var s := curve.get_closest_offset(local)
	var seg := _segment_of(s)
	var data := baked_segments[seg]
	if data == null or not data.is_valid():
		return []
	var rng := _segment_range(seg)
	var fj := clampf((s - rng.x) / ROW_STEP, 0.0, float(data.rows) - 1.001)
	var j := int(fj)
	var c := data.row_center[j]
	var dir := data.row_dir[j]
	var side := Vector3(dir.z, 0.0, -dir.x)
	var flat := Vector3(world_pos.x - c.x, 0.0, world_pos.z - c.z)
	var across := flat.dot(side)
	var hw := data.row_half_width[j]
	if absf(across) > hw:
		return []
	var fi := clampf((across + hw) / (2.0 * hw) * float(data.cells_across) - 0.5,
		0.0, float(data.cells_across) - 1.001)
	var depth := data.sample_array(data.depth, fi, fj)
	if depth <= 0.03:
		return []
	var u := data.sample_array(data.vel_across, fi, fj)
	var v := data.sample_array(data.vel_along, fi, fj)
	var off := data.sample_array(data.surface_offset, fi, fj)
	var height := data.row_height[j] + off
	if j + 1 < data.rows:
		height = lerpf(data.row_height[j], data.row_height[j + 1], fj - float(j)) + off
	var flow := side * u + dir * v
	# weight fades where a junction extension fades the ribbon out
	var weight := 1.0
	if _junction_b != null and _junction_b.has_method("river_tail_weight"):
		weight = _junction_b.river_tail_weight(self, s)
	if _junction_a != null and _junction_a.has_method("river_head_weight"):
		weight = minf(weight, _junction_a.river_head_weight(self, s))
	return [height, flow, depth, weight]


## Height of the surface as the vertex shader draws it at time `t`
## (WaterManager.water_time): the baked level and offset plus the standing
## waves, term for term as in water_surface_body.gdshaderinc. Player ripples
## are not included (GPU only). NAN outside the water.
func drawn_height(world_pos: Vector3, t: float) -> float:
	if baked_segments.is_empty() or curve == null:
		return NAN
	var mgr := _manager()
	var s := curve.get_closest_offset(to_local(world_pos))
	var seg := _segment_of(s)
	var data := baked_segments[seg]
	if data == null or not data.is_valid():
		return NAN
	var rng := _segment_range(seg)
	var fj := clampf((s - rng.x) / ROW_STEP, 0.0, float(data.rows) - 1.001)
	var j := int(fj)
	var c := data.row_center[j]
	var dir := data.row_dir[j]
	var side := Vector3(dir.z, 0.0, -dir.x)
	var across := Vector3(world_pos.x - c.x, 0.0, world_pos.z - c.z).dot(side)
	var hw := data.row_half_width[j]
	if absf(across) > hw:
		return NAN
	var fi := clampf((across + hw) / (2.0 * hw) * float(data.cells_across) - 0.5,
		0.0, float(data.cells_across) - 1.001)
	var base := data.row_height[j]
	if j + 1 < data.rows:
		base = lerpf(data.row_height[j], data.row_height[j + 1], fj - float(j))
	var depth := data.sample_array(data.depth, fi, fj)
	var foam := data.sample_array(data.foam, fi, fj)
	var off := data.sample_array(data.surface_offset, fi, fj)
	var slope_arr := data.cell_slope if data.cell_slope.size() == data.cells_across * data.rows else PackedFloat32Array()
	var slope := data.sample_array(slope_arr, fi, fj) if not slope_arr.is_empty() \
		else (data.row_slope[j] if j < data.row_slope.size() else 0.0)
	var speed := Vector2(data.sample_array(data.vel_across, fi, fj),
		data.sample_array(data.vel_along, fi, fj)).length()
	var fall := smoothstep(0.3, 0.7, slope)
	var shore := smoothstep(0.02, 0.2, depth)
	var wave_amp := style.standing_wave_height if style != null else 0.08
	var amp := wave_amp * (0.3 + 1.2 * foam) * clampf(speed / 2.0, 0.0, 1.3) * (1.0 - fall) * shore
	amp *= 0.85 + 0.15 * sin(t * 1.7 + s * 2.0)
	# wave_h(v_metric, t), v_metric = (across, s)
	var h0 := 0.0
	if mgr != null:
		h0 = mgr.sample_noise(Vector2(across * 0.22, s * 0.16 - t * 0.02), 2) - 0.5
	var lift := (off * (1.0 - fall) + h0 * 2.0 * amp + 0.02 * foam) * shore
	return base + lift


## Surface height of the river beside a position on its bank (within
## `margin` metres of the channel), NAN otherwise. Used for wet banks.
func surface_height_near(world_pos: Vector3, margin: float = 2.5) -> float:
	if baked_segments.is_empty() or curve == null:
		return NAN
	var s := curve.get_closest_offset(to_local(world_pos))
	var seg := _segment_of(s)
	var data := baked_segments[seg]
	if data == null or not data.is_valid():
		return NAN
	var rng := _segment_range(seg)
	var j := clampi(int((s - rng.x) / ROW_STEP), 0, data.rows - 1)
	var c := data.row_center[j]
	if Vector2(world_pos.x - c.x, world_pos.z - c.z).length() > data.row_half_width[j] + margin:
		return NAN
	return data.row_height[j]


## Splats this river's baked grid into the world water map (see
## WaterManager.MapBuild). `cursor` is a row index over all segments;
## returns Vector2i(next_cursor or -1 when done, texels written).
func splat_water_map(build, cursor: int, budget: int) -> Vector2i:
	var used := 0
	var row_base := 0
	var half: float = build.texel * float(build.n) * 0.5
	var cx: float = build.ox + half
	var cz: float = build.oz + half
	var length := curve.get_baked_length() if curve != null else 0.0
	for seg in baked_segments.size():
		var data := baked_segments[seg]
		if data == null or not data.is_valid():
			continue
		var rows := data.rows
		if cursor >= row_base + rows:
			row_base += rows
			continue
		var nx := data.cells_across
		var rng := _segment_range(seg)
		# sub-steps along the flow so no map row is skipped
		var sub_n := maxi(1, int(ceil(data.cell_length / build.texel)))
		var j := maxi(cursor - row_base, 0)
		while j < rows:
			var c := data.row_center[j]
			var hw := data.row_half_width[j]
			if absf(c.x - cx) > half + hw + 3.0 or absf(c.z - cz) > half + hw + 3.0:
				j += 1
				continue
			if used >= budget:
				return Vector2i(row_base + j, used)
			var dir := data.row_dir[j]
			var side := Vector3(dir.z, 0.0, -dir.x)
			var cw := data.row_cell_width[j]
			var i_step := maxi(1, int(build.texel / cw))
			var margin_cells := int(2.5 / cw)
			var s := rng.x + float(j) * ROW_STEP
			var w := 1.0
			if _junction_b != null and _junction_b.has_method("river_tail_weight"):
				w = _junction_b.river_tail_weight(self, s)
			if _junction_a != null and _junction_a.has_method("river_head_weight"):
				w = minf(w, _junction_a.river_head_weight(self, s))
			var jn := mini(j + 1, rows - 1)
			for sub in sub_n:
				var t := float(sub) / float(sub_n)
				var pc := c.lerp(data.row_center[jn], t)
				var h := lerpf(data.row_height[j], data.row_height[jn], t)
				var i := -margin_cells
				while i < nx + margin_cells:
					var across := -hw + (float(i) + 0.5) * cw
					var px := pc.x + side.x * across
					var pz := pc.z + side.z * across
					if i >= 0 and i < nx:
						var k := j * nx + i
						var dep := data.depth[k]
						# rocks stay walls for the ripple simulation
						if dep > 0.03 and (data.obstacle.is_empty() or data.obstacle[k] == 0):
							var u := data.vel_across[k]
							var v := data.vel_along[k]
							build.put_water(px, pz, side.x * u + dir.x * v, side.z * u + dir.z * v,
								h + data.surface_offset[k], dep, w)
						else:
							build.put_bank(px, pz, h)
					else:
						build.put_bank(px, pz, h)
					used += 1
					i += i_step
			j += 1
		row_base += rows
	return Vector2i(-1, used)


func get_water_aabb() -> AABB:
	if _chunks.is_empty():
		return AABB(global_position, Vector3.ONE)
	var aabb: AABB = _chunks[0].global_transform * _chunks[0].custom_aabb
	for c in _chunks:
		if is_instance_valid(c):
			aabb = aabb.merge(c.global_transform * c.custom_aabb)
	return aabb


# ----------------------------------------------------------- junction support --

func set_junction(junction: Node, at_end: bool) -> void:
	if at_end:
		_junction_b = junction
	else:
		_junction_a = junction


## Flow profile of the last baked row: [fluxes, foam, aeration, world
## positions, world dir]; used as the pond's inflow boundary.
func end_flow_profile() -> Array:
	if baked_segments.is_empty():
		return []
	var data := baked_segments[baked_segments.size() - 1]
	if data == null or not data.is_valid():
		return []
	var j := data.rows - 1
	var fluxes := _row_fluxes(data, j)
	var foam_row := _row_array(data.foam, data, j)
	var aer_row := _row_array(data.aeration, data, j)
	var positions := PackedVector3Array()
	for i in data.cells_across:
		positions.append(WaterBaker._cell_to_world(data, i, j))
	return [fluxes, foam_row, aer_row, positions, data.row_dir[j]]


## Downstream end frame in world space.
func end_frame() -> Dictionary:
	var s := curve.get_baked_length()
	var f := frame_at(s)
	var gt := global_transform
	return {
		"pos": gt * f["pos"],
		"dir": (gt.basis * f["dir"]).normalized(),
		"half_width": f["half_width"],
	}


func set_blend_uniforms(blend_start: float, blend_len: float, lift: float,
		fade_start: float, fade_len: float, other_style: WaterStyle, fade_in_len: float = 0.0) -> void:
	for m in _materials():
		m.set_shader_parameter("fade_in_len_m", fade_in_len)
		m.set_shader_parameter("blend_start_m", blend_start)
		m.set_shader_parameter("blend_len_m", blend_len)
		m.set_shader_parameter("blend_lift", lift)
		m.set_shader_parameter("fade_out_start_m", fade_start)
		m.set_shader_parameter("fade_out_len_m", fade_len)
		if other_style != null:
			other_style.apply_to_material(m, "style_b_")


func surface_material() -> ShaderMaterial:
	return _material


# ---------------------------------------------------------------------- spray --

func _build_spray() -> void:
	if _spray != null and is_instance_valid(_spray):
		_spray.queue_free()
		_spray = null
	if baked_segments.is_empty():
		return
	_spray = WaterSprayFactory.build_for(self, baked_segments, _foot_points, _foot_dirs)
	if _spray != null:
		add_child(_spray, false, Node.INTERNAL_MODE_BACK)


# --------------------------------------------------------------------- helpers --

func _invalidate_map() -> void:
	var mgr := _manager()
	if mgr != null:
		mgr.invalidate_map()


func _manager() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("WaterManager")


func _manager_call(method: String, arg) -> void:
	var mgr := _manager()
	if mgr != null:
		mgr.call(method, arg)
