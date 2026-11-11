# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node3D
## Dev tool: generates the example scenes of the Flowing Water plugin as real
## saved scenes (terrain, rocks, vegetation, lighting, water nodes), bakes the
## water and saves everything under examples/ and demo/.
##
## Run (needs a real renderer so the baked textures are real):
##   godot --path . res://tools/build_examples.tscn [-- only=01_stream]

const ADDON := "res://addons/flowing_water/"
const EX := "res://examples/"
const SH := EX + "shared/"
const STEP := 0.5

var _rng := RandomNumberGenerator.new()

# ------------------------------------------------------------------ specs --

func _specs() -> Array:
	var out: Array = []

	# 01 - a single stream
	out.append({
		"name": "01_stream", "dir": EX, "size": Vector2(60, 66), "seed": 11,
		"title": "01 - A stream",
		"description": "One WaterRiver: a Path3D with a width per point. Select 'Stream' to see the\ncurve and width handles; the inspector has Snap / Make downhill / Rebuild / Bake.",
		"rivers": [{
			"name": "Stream", "style": "clear_mountain", "discharge": 1.4, "rocks": 16,
			"points": _meander(2.0, 64.0, 5.0, 0.0, 3.5, 0.11, 0.3,
				func(z: float) -> float: return 6.0 - 0.028 * z - 0.7 * smoothstep(26.0, 38.0, z),
				func(z: float) -> float: return 2.1 - 0.8 * smoothstep(24.0, 28.0, z) * (1.0 - smoothstep(36.0, 40.0, z))),
		}],
		"camera": [Vector3(6.5, 6.6, 17.0), Vector3(1.0, 4.6, 31.0)],
	})

	# 02 - a pond
	out.append({
		"name": "02_pond", "dir": EX, "size": Vector2(60, 60), "seed": 23,
		"title": "02 - A pond",
		"description": "One WaterPond: a closed outline at the node's height. No junctions, so the\nflow is zero and the surface gets wind ripples. Logs float with WaterFloater.",
		"ponds": [{"name": "Pond", "center": Vector3(0, 4.0, 30), "radius": 11.5, "depth": 2.3,
			"style": "clear_mountain", "rocks": 7}],
		"logs": [Vector3(-3, 4.4, 27), Vector3(3.5, 4.4, 32), Vector3(0.5, 4.4, 35)],
		"log_spawn": Vector3(0, 5.0, 29),
		"camera": [Vector3(13.5, 6.4, 14.5), Vector3(0.0, 3.6, 30.0)],
	})

	# 03 - rapids and a waterfall
	out.append({
		"name": "03_waterfall", "dir": EX, "size": Vector2(64, 80), "seed": 37,
		"title": "03 - Rapids and a waterfall",
		"description": "Rows steeper than 'waterfall_threshold' become a fall: the water accelerates\nwith the drop, the plunge pool below gets foam and mist.",
		"rivers": [{
			"name": "Stream", "style": "clear_mountain", "discharge": 1.8, "rocks": 18,
			"points": _with_fall(_meander(2.0, 78.0, 4.0, 0.0, 3.0, 0.1, 1.2,
				func(z: float) -> float: return 12.0 - 0.03 * z - 0.9 * smoothstep(16.0, 30.0, z),
				func(z: float) -> float:
					return 2.0 - 0.6 * smoothstep(15.0, 18.0, z) * (1.0 - smoothstep(28.0, 32.0, z)) \
						+ 1.7 * smoothstep(38.0, 41.0, z) * (1.0 - smoothstep(47.0, 54.0, z))),
				36.0, 3.2),
		}],
		"log_spawn": ["Stream", 3.0],
		"camera": [Vector3(8.5, 7.9, 50.5), Vector3(-0.5, 7.6, 37.0)],
	})

	# 04 - river -> pond -> river
	var pond4 := {"name": "Pond", "center": Vector3(1.0, 4.0, 46.0), "radius": 11.0, "depth": 2.2,
		"style": "clear_mountain", "rocks": 5}
	out.append({
		"name": "04_river_pond_river", "dir": EX, "size": Vector2(72, 92), "seed": 41,
		"title": "04 - River -> pond -> river",
		"description": "Two WaterJunctions join the stream and the outlet to the pond. 'Bake river + pond'\nbakes in order: the stream's last row is the pond's inflow; the outlet starts at pond speed.",
		"rivers": [
			{"name": "Stream", "style": "clear_mountain", "discharge": 1.5, "rocks": 12,
				"points": _into_pond(_meander(2.0, 30.0, 4.5, 1.0, 3.0, 0.13, 0.5,
					func(z: float) -> float: return 5.6 - 0.05 * z,
					func(_z: float) -> float: return 2.0), pond4, true)},
			{"name": "Outlet", "style": "clear_mountain", "discharge": 1.5, "rocks": 8,
				"points": _into_pond(_meander(62.0, 90.0, 4.5, 1.0, 2.5, 0.15, 2.0,
					func(z: float) -> float: return 4.0 - 0.04 * (z - 60.0),
					func(_z: float) -> float: return 1.8), pond4, false)},
		],
		"ponds": [pond4],
		"junctions": [
			{"name": "Inlet", "river": "Stream", "pond": "Pond", "into_pond": true},
			{"name": "Outflow", "river": "Outlet", "pond": "Pond", "into_pond": false},
		],
		"log_spawn": ["Stream", 3.0],
		"camera": [Vector3(15.0, 8.0, 27.0), Vector3(1.0, 3.6, 44.0)],
	})

	# 05 - every style preset side by side
	var styles := ["spring", "clear_mountain", "glacial", "lowland", "peat", "muddy", "stylized", "toon"]
	var rivers5: Array = []
	for n in styles.size():
		var cx := -49.0 + 14.0 * n
		rivers5.append({
			"name": styles[n].capitalize().replace(" ", ""), "style": styles[n], "discharge": 1.3,
			"rocks": 5, "label": styles[n],
			"points": _meander(3.0, 50.0, 4.5, cx, 1.3, 0.2, float(n),
				func(z: float) -> float: return 6.0 - 0.05 * z,
				func(_z: float) -> float: return 1.9),
		})
	out.append({
		"name": "05_styles", "dir": EX, "size": Vector2(124, 54), "seed": 53,
		"title": "05 - Style presets",
		"description": "The same stream eight times, one WaterStyle preset each (no re-bake needed to swap).\nLeft to right: spring, clear_mountain, glacial, lowland, peat, muddy, stylized, toon.",
		"rivers": rivers5, "allow_style_cycle": false, "trees": 0.5,
		"camera": [Vector3(0.0, 17.0, 60.0), Vector3(0.0, 2.0, 24.0)],
	})

	# 06 - gameplay: character, push, floaters
	out.append({
		"name": "06_gameplay", "dir": EX, "size": Vector2(64, 74), "seed": 67,
		"title": "06 - Character and floating objects",
		"description": "The player has a WaterInteractor: it reports in_water / depth / get_push() and the\ncontroller (shared/player.gd) decides. Logs use WaterFloater. Wade into the rapids.",
		"rivers": [{
			"name": "Stream", "style": "clear_mountain", "discharge": 2.4, "rocks": 14,
			"points": _meander(2.0, 72.0, 5.0, 0.0, 4.0, 0.1, 2.2,
				func(z: float) -> float: return 6.5 - 0.03 * z - 0.9 * smoothstep(34.0, 48.0, z),
				func(z: float) -> float: return 2.6 - 1.2 * smoothstep(32.0, 36.0, z) * (1.0 - smoothstep(46.0, 52.0, z))),
		}],
		"player": ["Stream", 18.0, 6.0],
		"logs": [["Stream", 4.0], ["Stream", 9.0], ["Stream", 15.0]],
		"log_spawn": ["Stream", 2.5],
	})

	# 07 - a slow, turbid lowland river
	out.append({
		"name": "07_lowland_river", "dir": EX, "size": Vector2(120, 124), "seed": 83,
		"title": "07 - Slow lowland river",
		"description": "A wide, slow, silty river: the 'lowland' style (turbidity, sediment colour, surface slicks).\nPress 5 to compare: peat is clear but tea-stained, muddy is a flood. No re-bake needed.",
		"rivers": [{
			"name": "River", "style": "lowland", "discharge": 12.0, "rocks": 3, "boulders": 0.08,
			"points": _meander(2.0, 122.0, 8.0, 0.0, 9.0, 0.045, 0.5,
				func(z: float) -> float: return 3.0 - 0.0012 * z,
				func(z: float) -> float: return 7.2 + 1.4 * sin(z * 0.07)),
		}],
		"bank": "mud", "bank_scale": 0.55, "hill_amp": 2.5, "trees": 0.35, "reeds": true,
		"logs": [["River", 20.0], ["River", 34.0, 2.5], ["River", 52.0, -2.0]],
		"log_spawn": ["River", 6.0],
		"camera_at": ["River", 36.0, 13.5, 2.3, 62.0],
	})

	# showcase demo: stream -> rapids -> waterfall -> pond -> outlet
	var pond_d := {"name": "Pond", "center": Vector3(2.0, 3.9, 56.0), "radius": 9.5, "depth": 1.5,
		"style": "clear_mountain", "rocks": 6}
	out.append({
		"name": "demo", "dir": "res://examples/demo/", "size": Vector2(110, 112), "seed": 7,
		"title": "Flowing Water demo",
		"description": "Stream -> rapids -> waterfall -> pond -> outlet. Click to capture the mouse,\nWASD to walk, Space to jump.",
		"rivers": [
			{"name": "Stream", "style": "clear_mountain", "discharge": 1.6, "rocks": 20,
				"points": _into_pond(_with_fall(_meander(3.0, 42.0, 4.0, 0.0, 4.0, 0.15, 0.0,
					func(z: float) -> float: return 8.4 - 0.045 * z - 0.5 * smoothstep(12.0, 24.0, z),
					func(z: float) -> float:
						return 2.1 - 0.7 * smoothstep(11.0, 14.0, z) * (1.0 - smoothstep(24.0, 28.0, z)) \
							+ 0.6 * smoothstep(34.0, 38.0, z)),
					31.0, 2.3), pond_d, true)},
			{"name": "Outlet", "style": "clear_mountain", "discharge": 1.6, "rocks": 10,
				"points": _into_pond(_meander(70.0, 108.0, 4.5, 2.0, 3.0, 0.14, 1.0,
					func(z: float) -> float: return 3.9 - 0.045 * (z - 68.0),
					func(_z: float) -> float: return 1.8), pond_d, false)},
		],
		"ponds": [pond_d],
		"junctions": [
			{"name": "Inlet", "river": "Stream", "pond": "Pond", "into_pond": true},
			{"name": "Outflow", "river": "Outlet", "pond": "Pond", "into_pond": false},
		],
		"player": ["Stream", 7.0, 6.0],
		"logs": [["Stream", 3.0], ["Stream", 10.0], ["Stream", 18.0], Vector3(1.0, 4.3, 53), Vector3(4.0, 4.3, 58)],
		"log_spawn": ["Stream", 2.5],
		"audio": true, "bench_path": true,
	})
	return out


## Control points [x, y, z, half_width] of a meandering river.
func _meander(z0: float, z1: float, step: float, cx: float, amp: float, freq: float, phase: float,
		y_of: Callable, w_of: Callable) -> Array:
	var pts: Array = []
	var z := z0
	while z <= z1 + 0.01:
		pts.append([cx + amp * sin(z * freq + phase) + amp * 0.3 * sin(z * freq * 2.3 + phase * 1.7),
			y_of.call(z), z, w_of.call(z)])
		z += step
	return pts


## Inserts a waterfall: everything at or below z_fall drops by `drop`, with a
## lip and a base control point 2.1 m apart (the water's horizontal throw).
func _with_fall(pts: Array, z_fall: float, drop: float) -> Array:
	var out: Array = []
	var inserted := false
	for p: Array in pts:
		if p[2] < z_fall - 1.5:
			out.append(p)
		elif not inserted:
			inserted = true
			var x_at := func(z: float) -> float:
				# interpolate x / y / w from the original polyline
				return _interp(pts, z, 0)
			var lip := z_fall
			out.append([x_at.call(lip), _interp(pts, lip, 1), lip, _interp(pts, lip, 3)])
			out.append([x_at.call(lip + 2.1), _interp(pts, lip + 2.1, 1) - drop, lip + 2.1, _interp(pts, lip + 2.1, 3)])
			if p[2] > z_fall + 3.6:
				out.append([p[0], p[1] - drop, p[2], p[3]])
		elif p[2] > z_fall + 3.6:
			out.append([p[0], p[1] - drop, p[2], p[3]])
	return out


func _interp(pts: Array, z: float, comp: int) -> float:
	for n in pts.size() - 1:
		if z >= pts[n][2] and z <= pts[n + 1][2]:
			var t: float = (z - pts[n][2]) / (pts[n + 1][2] - pts[n][2])
			return lerpf(pts[n][comp], pts[n + 1][comp], t)
	return pts[pts.size() - 1][comp] if z > pts[0][2] else pts[0][comp]


func _pond_r(pond: Dictionary, a: float) -> float:
	return pond["radius"] * (1.0 + 0.12 * sin(3.0 * a + 1.0) + 0.06 * sin(5.0 * a))


## Joins a river to a pond: for an inlet the last points flatten onto the
## pond level and end just inside the shore; for an outlet the first do.
func _into_pond(pts: Array, pond: Dictionary, inlet: bool) -> Array:
	var c: Vector3 = pond["center"]
	var level := c.y
	var out: Array = []
	if inlet:
		var edge_z := c.z - _pond_r(pond, -PI / 2.0)
		for p: Array in pts:
			if p[2] < edge_z - 9.0:
				out.append(p)
		var last: Array = out[out.size() - 1]
		var y_prev: float = last[1]
		out.append([lerpf(last[0], c.x, 0.5), lerpf(y_prev, level, 0.75), edge_z - 5.5, last[3] + 0.3])
		out.append([lerpf(last[0], c.x, 0.85), level, edge_z - 2.0, last[3] + 0.6])
		out.append([c.x, level, edge_z + 1.5, last[3] + 0.9])
		# keep everything upstream above the pond level
		for p: Array in out:
			p[1] = maxf(p[1], level)
	else:
		var edge_z := c.z + _pond_r(pond, PI / 2.0)
		var first: Array = pts[0]
		out.append([c.x, level, edge_z - 1.5, first[3] + 0.6])
		out.append([lerpf(c.x, first[0], 0.4), level, edge_z + 2.5, first[3] + 0.2])
		for p: Array in pts:
			if p[2] > edge_z + 6.0:
				out.append([p[0], minf(p[1], level - 0.02 * (p[2] - edge_z)), p[2], p[3]])
	return out


# -------------------------------------------------------------------- main --

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="):
			only = a.substr(5)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SH))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EX + "data"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://examples/demo/data"))
	_make_shared()
	for spec: Dictionary in _specs():
		if only != "" and spec["name"] != only:
			continue
		var t0 := Time.get_ticks_msec()
		await _build(spec)
		print("built %s in %d ms" % [spec["name"], Time.get_ticks_msec() - t0])
	get_tree().quit()


# ----------------------------------------------------------- shared assets --

const PH := SH + "polyhaven/"

var _rock_meshes: Array[ArrayMesh] = []
var _rock_hulls: Array[PackedVector3Array] = []
var _rock_radius := PackedFloat32Array()     # half of the larger horizontal extent
var _rock_height := PackedFloat32Array()
var _terrain_mat: ShaderMaterial
var _tree_mesh: ArrayMesh
var _grass_mesh: ArrayMesh
var _env: Environment
var _log_scene: PackedScene


func _save(res: Resource, path: String) -> Resource:
	res.take_over_path(path)
	var flags := ResourceSaver.FLAG_COMPRESS if path.ends_with(".res") else 0
	var err := ResourceSaver.save(res, path, flags)
	if err != OK:
		push_error("save failed: %s (%d)" % [path, err])
	return res


func _tex(tex_name: String) -> Texture2D:
	return load(PH + "textures/" + tex_name + ".jpg")


func _make_shared() -> void:
	_rng.seed = 1234
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SH + "rocks"))
	_load_rocks()
	_terrain_mat = ShaderMaterial.new()
	_terrain_mat.shader = load(SH + "terrain.gdshader")
	for pair: Array in [["meadow", "forrest_ground_01"], ["soil", "forest_ground_04"],
			["bar", "ganges_river_pebbles"], ["silt", "river_small_rocks"], ["rock", "mossy_rock"]]:
		_terrain_mat.set_shader_parameter(pair[0] + "_albedo", _tex(pair[1] + "_diff"))
		_terrain_mat.set_shader_parameter(pair[0] + "_normal", _tex(pair[1] + "_nor"))
		if pair[0] in ["meadow", "bar", "rock"]:
			_terrain_mat.set_shader_parameter(pair[0] + "_rough", _tex(pair[1] + "_rough"))
	_save(_terrain_mat, SH + "terrain_material.tres")

	var branch_tex := _make_branch_texture()
	_save(branch_tex, SH + "conifer_branch.res")
	var tree_mat := ShaderMaterial.new()
	tree_mat.shader = load(SH + "tree.gdshader")
	tree_mat.set_shader_parameter("branch_tex", branch_tex)
	_save(tree_mat, SH + "tree_material.tres")
	_tree_mesh = _make_conifer(tree_mat)
	_save(_tree_mesh, SH + "conifer.res")

	var blade_tex := _make_grass_texture()
	_save(blade_tex, SH + "grass_blades.res")
	var grass_mat := ShaderMaterial.new()
	grass_mat.shader = load(SH + "grass.gdshader")
	grass_mat.set_shader_parameter("blade_tex", blade_tex)
	_save(grass_mat, SH + "grass_material.tres")
	_grass_mesh = _make_grass_tuft()
	_grass_mesh.surface_set_material(0, grass_mat)
	_save(_grass_mesh, SH + "grass_tuft.res")

	_env = _make_environment()
	_save(_env, SH + "environment.tres")
	_log_scene = _make_log_scene()


## Scanned rocks from Poly Haven's rock_moss_set_01/02: each rock becomes its
## own mesh, recentred to sit on its base, with the water-receiving rock
## material and a convex hull for collision (and for the bake raycasts).
func _load_rocks() -> void:
	var n := 0
	for id: String in ["rock_moss_set_01", "rock_moss_set_02"]:
		var mat := ShaderMaterial.new()
		mat.shader = load(ADDON + "render/rock_receiver_textured.gdshader")
		var tdir := PH + "models/%s/textures/%s_" % [id, id]
		mat.set_shader_parameter("albedo_map", load(tdir + "diff_1k.jpg"))
		mat.set_shader_parameter("normal_map", load(tdir + "nor_gl_1k.jpg"))
		mat.set_shader_parameter("roughness_map", load(tdir + "rough_1k.jpg"))
		_save(mat, SH + "rocks/%s_material.tres" % id)
		var sc: Node = load(PH + "models/%s/%s.gltf" % [id, id]).instantiate()
		for child in sc.get_children():
			var mi := child as MeshInstance3D
			if mi == null:
				continue
			var arrays := mi.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var aabb := AABB(mi.transform * verts[0], Vector3.ZERO)
			for i in verts.size():
				verts[i] = mi.transform * verts[i]
				normals[i] = (mi.transform.basis * normals[i]).normalized()
				aabb = aabb.expand(verts[i])
			var shift := Vector3(aabb.get_center().x, aabb.position.y, aabb.get_center().z)
			for i in verts.size():
				verts[i] -= shift
			arrays[Mesh.ARRAY_VERTEX] = verts
			arrays[Mesh.ARRAY_NORMAL] = normals
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(0, mat)
			var hull := mesh.create_convex_shape(true, true) as ConvexPolygonShape3D
			_rock_meshes.append(_save(mesh, SH + "rocks/rock_%02d.res" % n))
			_rock_hulls.append(hull.points)
			_rock_radius.append(maxf(aabb.size.x, aabb.size.z) * 0.5)
			_rock_height.append(aabb.size.y)
			n += 1
		sc.free()
	print("  rocks: %d scanned meshes" % n)


func _make_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.20, 0.40, 0.74)
	mat.sky_horizon_color = Color(0.66, 0.77, 0.88)
	mat.sky_curve = 0.12
	mat.ground_horizon_color = Color(0.64, 0.74, 0.82)
	mat.ground_bottom_color = Color(0.50, 0.58, 0.62)
	mat.sun_angle_max = 28.0
	mat.sun_curve = 0.12
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 5.0
	env.tonemap_exposure = 1.05
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.04
	env.fog_enabled = true
	env.fog_light_color = Color(0.70, 0.78, 0.86)
	env.fog_density = 0.0032
	env.fog_aerial_perspective = 0.6
	env.fog_sun_scatter = 0.15
	env.fog_sky_affect = 0.0
	return env


func _make_log_scene() -> PackedScene:
	var body := RigidBody3D.new()
	body.name = "Log"
	body.mass = 9.0
	body.collision_layer = 2
	body.collision_mask = 1 | 2
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 1.1)
	shape.shape = box
	body.add_child(shape)
	shape.owner = body
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.095
	cyl.bottom_radius = 0.11
	cyl.height = 1.1
	cyl.radial_segments = 12
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.36, 0.25, 0.15)
	m.roughness = 0.9
	cyl.material = m
	mi.mesh = cyl
	mi.rotation_degrees.x = 90.0
	body.add_child(mi)
	mi.owner = body
	var fl := WaterFloater.new()
	fl.name = "WaterFloater"
	body.add_child(fl)
	fl.owner = body
	var ps := PackedScene.new()
	ps.pack(body)
	_save(ps, SH + "log.tscn")
	body.free()
	return load(SH + "log.tscn")


# --- noise helpers
func _vn(x: float, z: float, seed: int) -> float:
	var ix := int(floor(x))
	var iz := int(floor(z))
	var fx := x - ix
	var fz := z - iz
	fx = fx * fx * (3.0 - 2.0 * fx)
	fz = fz * fz * (3.0 - 2.0 * fz)
	var a := WaterNoise._h2(ix, iz, seed)
	var b := WaterNoise._h2(ix + 1, iz, seed)
	var c := WaterNoise._h2(ix, iz + 1, seed)
	var d := WaterNoise._h2(ix + 1, iz + 1, seed)
	return a + (b - a) * fx + (c - a) * fz + (a - b - c + d) * fx * fz


func _fbm(x: float, z: float, seed: int) -> float:
	return _vn(x, z, seed) * 0.55 + _vn(x * 2.1, z * 2.1, seed + 1) * 0.3 + _vn(x * 4.3, z * 4.3, seed + 2) * 0.15


func _n3(p: Vector3, seed: int) -> float:
	# cheap 3D-ish noise from three 2D slices
	return (_vn(p.x, p.y, seed) + _vn(p.y + 7.3, p.z, seed + 3) + _vn(p.z + 3.1, p.x, seed + 5)) / 3.0


# --- vegetation: textured cards
# Draws a soft-edged line into an image (used to paint the card textures).
func _line(img: Image, a: Vector2, b: Vector2, w0: float, w1: float, c0: Color, c1: Color) -> void:
	var n := int(a.distance_to(b)) + 1
	var iw := img.get_width()
	var ih := img.get_height()
	for i in n + 1:
		var t := float(i) / float(n)
		var p := a.lerp(b, t)
		var w := lerpf(w0, w1, t)
		var c := c0.lerp(c1, t)
		var r := int(ceil(w * 0.5))
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if float(dx * dx + dy * dy) <= w * w * 0.25 + 0.3:
					var x := int(p.x) + dx
					var y := int(p.y) + dy
					if x >= 0 and y >= 0 and x < iw and y < ih:
						img.set_pixel(x, y, c)


func _needles(img: Image, rng: RandomNumberGenerator, a: Vector2, b: Vector2, len0: float, len1: float) -> void:
	var along := (b - a).normalized()
	var perp := Vector2(-along.y, along.x)
	var n := int(a.distance_to(b) / 2.2)
	for i in n:
		var t := float(i) / float(maxi(n - 1, 1))
		var p := a.lerp(b, t)
		for side: float in [-1.0, 1.0]:
			var ln := lerpf(len0, len1, t) * (0.75 + 0.5 * rng.randf())
			var ang := deg_to_rad(48.0 + rng.randf() * 16.0)
			var tip := p + (perp * side * sin(ang) + along * cos(ang)) * ln
			var sh := rng.randf()
			var c := Color(0.06 + 0.07 * sh, 0.15 + 0.13 * sh, 0.055 + 0.04 * sh, 1.0)
			_line(img, p, tip, 2.4, 1.0, c, c.lightened(0.12))


## A fir branch seen from above: a twig with side twigs and needles, on a
## transparent background. v = 0 at the trunk, v = 1 at the tip.
func _make_branch_texture() -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	var img := Image.create_empty(256, 512, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.09, 0.18, 0.07, 0.0))
	var base := Vector2(128, 2)
	var tip := Vector2(128, 504)
	# side twigs first, the main twig on top
	var y0 := 34.0
	while y0 < 430.0:
		for side: float in [-1.0, 1.0]:
			var f := y0 / 504.0
			var ln := lerpf(112.0, 38.0, f) * (0.85 + 0.3 * rng.randf())
			var ang := deg_to_rad(36.0 + rng.randf() * 10.0)
			var a := Vector2(128, y0 + rng.randf() * 10.0)
			var b := a + Vector2(side * sin(ang), cos(ang)) * ln
			_needles(img, rng, a, b, 24.0, 9.0)
			_line(img, a, b, 3.0, 1.2, Color(0.20, 0.14, 0.08), Color(0.24, 0.19, 0.10))
		y0 += 40.0
	_needles(img, rng, base, tip, 46.0, 12.0)
	_line(img, base, tip, 5.0, 1.5, Color(0.19, 0.13, 0.075), Color(0.25, 0.2, 0.1))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## A clump of grass blades on a transparent background, roots at the bottom.
func _make_grass_texture() -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var img := Image.create_empty(512, 512, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.38, 0.14, 0.0))
	for b in 60:
		var x0 := 28.0 + rng.randf() * 456.0
		var h := 190.0 + rng.randf() * 300.0
		var lean := (rng.randf() - 0.5) * 200.0
		var sh := rng.randf()
		var root := Color(0.20 + 0.05 * sh, 0.25 + 0.05 * sh, 0.09, 1.0)
		var top := Color(0.42 + 0.18 * sh, 0.50 + 0.12 * sh, 0.2 + 0.08 * sh, 1.0)
		var prev := Vector2(x0, 511.0)
		for seg in range(1, 13):
			var t := float(seg) / 12.0
			var pt := Vector2(x0 + lean * t * t, 511.0 - h * t)
			_line(img, prev, pt, lerpf(10.0, 2.0, t - 0.08), lerpf(10.0, 2.0, t), root.lerp(top, t - 0.08), root.lerp(top, t))
			prev = pt
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## A conifer built the way game trees are: a trunk plus whorls of branch
## cards carrying the needle texture, drooping with their own weight.
func _make_conifer(card_mat: Material) -> ArrayMesh:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var height := 10.5
	var whorls := 19
	for w in whorls:
		var f := float(w) / float(whorls - 1)
		var y := lerpf(1.5, height - 1.0, f)
		var radius := 2.8 * pow(1.0 - f, 0.85) + 0.4
		var count := 5 if f < 0.75 else 4
		var a0 := rng.randf() * TAU
		for b in count:
			var a := a0 + TAU * float(b) / float(count) + (rng.randf() - 0.5) * 0.4
			var dir := Vector3(cos(a), 0.0, sin(a))
			var side := Vector3(-dir.z, 0.0, dir.x)
			var ln := radius * (0.85 + 0.3 * rng.randf())
			var wd := ln * 0.6
			var droop := ln * (0.22 + 0.2 * (1.0 - f))
			var stations := [
				Vector3(0, y, 0) + dir * 0.08,
				Vector3(0, y, 0) + dir * ln * 0.5 + Vector3.UP * ln * 0.05,
				Vector3(0, y, 0) + dir * ln - Vector3.UP * droop,
			]
			# a flat card and an upright one through the same branch
			for card in 2:
				var across := side * wd * 0.5 if card == 0 else Vector3.UP * wd * 0.28
				var n := (Vector3.UP * 0.9 + dir * 0.45).normalized() if card == 0 else (dir * 0.5 + Vector3.UP * 0.6 + side * 0.5).normalized()
				var i0 := pos.size()
				for st in 3:
					var v := float(st) * 0.5
					pos.append(stations[st] - across)
					pos.append(stations[st] + across)
					uv.append(Vector2(0.0, v))
					uv.append(Vector2(1.0, v))
					nrm.append(n)
					nrm.append(n)
					col.append(Color(1, 1, 1, f * 0.6 + v * 0.4))
					col.append(Color(1, 1, 1, f * 0.6 + v * 0.4))
				for st in 2:
					var k := i0 + st * 2
					idx.append_array([k, k + 1, k + 2, k + 1, k + 3, k + 2])
	# the leader: two crossed upright cards at the top
	for card in 2:
		var across := (Vector3.RIGHT if card == 0 else Vector3.BACK) * 0.55
		var i0 := pos.size()
		for st in 2:
			var yy := height - 2.1 + float(st) * 2.4
			pos.append(Vector3(0, yy, 0) - across)
			pos.append(Vector3(0, yy, 0) + across)
			uv.append(Vector2(0.0, float(st)))
			uv.append(Vector2(1.0, float(st)))
			nrm.append(Vector3.UP)
			nrm.append(Vector3.UP)
			col.append(Color(1, 1, 1, 1))
			col.append(Color(1, 1, 1, 1))
		idx.append_array([i0, i0 + 1, i0 + 2, i0 + 1, i0 + 3, i0 + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, card_mat)
	# trunk
	var tp := PackedVector3Array()
	var tn := PackedVector3Array()
	var ti := PackedInt32Array()
	var segs := 8
	for ring in 2:
		for sgm in segs:
			var a := TAU * float(sgm) / float(segs)
			var r := 0.24 if ring == 0 else 0.04
			tp.append(Vector3(cos(a) * r, 0.0 if ring == 0 else height - 0.6, sin(a) * r))
			tn.append(Vector3(cos(a), 0.15, sin(a)).normalized())
	for sgm in segs:
		var s2 := (sgm + 1) % segs
		ti.append_array([sgm, segs + sgm, s2, s2, segs + sgm, segs + s2])
	var ta := []
	ta.resize(Mesh.ARRAY_MAX)
	ta[Mesh.ARRAY_VERTEX] = tp
	ta[Mesh.ARRAY_NORMAL] = tn
	ta[Mesh.ARRAY_INDEX] = ti
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ta)
	var bark := StandardMaterial3D.new()
	bark.albedo_color = Color(0.22, 0.16, 0.11)
	bark.roughness = 0.95
	mesh.surface_set_material(1, bark)
	return mesh


## A tuft of grass: three crossed cards carrying the blade texture.
func _make_grass_tuft() -> ArrayMesh:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var w := 0.62
	var h := 0.44
	for card in 3:
		var a := PI * float(card) / 3.0 + 0.2
		var right := Vector3(cos(a), 0.0, sin(a)) * w * 0.5
		var i0 := pos.size()
		pos.append_array([-right, right, -right + Vector3.UP * h, right + Vector3.UP * h])
		uv.append_array([Vector2(0, 1), Vector2(1, 1), Vector2(0, 0), Vector2(1, 0)])
		col.append_array([Color(0, 0, 0), Color(0, 0, 0), Color(1, 0, 0), Color(1, 0, 0)])
		for n in 4:
			nrm.append(Vector3.UP)
		idx.append_array([i0, i0 + 1, i0 + 2, i0 + 1, i0 + 3, i0 + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ----------------------------------------------------------------- terrain --

# per-build terrain features
var _f_pts: Array[PackedVector3Array] = []      # river samples (world)
var _f_hw: Array[PackedFloat32Array] = []
var _f_ponds: Array = []                        # [center, outline world PackedVector2Array, depth]
var _seed := 0
var _hill_amp := 7.0
var _bank_scale := 1.0
var _mud := 0.0


func _bed_depth(hw: float) -> float:
	return 0.42 * pow(hw / 2.0, 1.25)


func _bank(d: float) -> float:
	if d < 1.2:
		return 0.09 * d
	if d < 4.0:
		return 0.108 + (d - 1.2) * 0.42
	var e := d - 4.0
	return 1.284 + e * 0.14 + minf(e, 30.0) * minf(e, 30.0) * 0.004


static func _smin(a: float, b: float, k: float) -> float:
	var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) - k * h * (1.0 - h)


## Returns Vector2(height, distance outside the nearest water edge).
func _height(x: float, z: float) -> Vector2:
	var best := 1e9
	var dmin := 1e9
	var wobble := 0.7 + 0.6 * _vn(x * 0.09, z * 0.09, _seed + 40)
	for r in _f_pts.size():
		var pts := _f_pts[r]
		var bi := 0
		var bd := 1e18
		for n in pts.size():
			var dx := pts[n].x - x
			var dz := pts[n].z - z
			var d2 := dx * dx + dz * dz
			if d2 < bd:
				bd = d2
				bi = n
		var dist := sqrt(bd)
		var hw := _f_hw[r][bi]
		var wy := pts[bi].y
		var d := dist - hw
		var v: float
		if d < 0.0:
			v = wy - _bed_depth(hw) * (1.0 - pow(dist / hw, 2.4)) - 0.03
		else:
			v = wy + _bank(d * wobble) * _bank_scale
		best = _smin(best, v, 0.7) if best < 1e8 else v
		dmin = minf(dmin, d)
	for pond: Array in _f_ponds:
		var c: Vector3 = pond[0]
		var poly: PackedVector2Array = pond[1]
		var p := Vector2(x, z)
		var sd := 1e9
		for n in poly.size():
			sd = minf(sd, p.distance_to(Geometry2D.get_closest_point_to_segment(p, poly[n], poly[(n + 1) % poly.size()])))
		if Geometry2D.is_point_in_polygon(p, poly):
			sd = -sd
		var v: float
		if sd < 0.0:
			v = c.y - float(pond[2]) * pow(smoothstep(0.0, 5.0, -sd), 0.85) - 0.04
		else:
			v = c.y + _bank(sd * wobble)
		best = _smin(best, v, 0.7) if best < 1e8 else v
		dmin = minf(dmin, sd)
	# hills grow away from the water; small relief everywhere on land
	var far := smoothstep(5.0, 38.0, dmin)
	best += (_fbm(x * 0.028, z * 0.028, _seed) - 0.28) * _hill_amp * far
	best += (_fbm(x * 0.33, z * 0.33, _seed + 7) - 0.5) * 0.3 * smoothstep(-0.3, 3.0, dmin)
	# stones on the bed
	best += (_vn(x * 1.7, z * 1.7, _seed + 13) - 0.5) * 0.1 * (1.0 - smoothstep(-0.2, 0.6, dmin))
	return Vector2(best, dmin)


var _grid_h: PackedFloat32Array
var _grid_d: PackedFloat32Array
var _grid_nx := 0
var _grid_nz := 0
var _grid_x0 := 0.0
var _z0 := 0.0          # world z of the terrain's first row (scenes are centred on the origin)


func _grid_sample(arr: PackedFloat32Array, x: float, z: float) -> float:
	var fi := clampf((x - _grid_x0) / STEP, 0.0, _grid_nx - 1.001)
	var fj := clampf((z - _z0) / STEP, 0.0, _grid_nz - 1.001)
	var i := int(fi)
	var j := int(fj)
	var tx := fi - i
	var tz := fj - j
	var k := j * _grid_nx + i
	return lerpf(lerpf(arr[k], arr[k + 1], tx), lerpf(arr[k + _grid_nx], arr[k + _grid_nx + 1], tx), tz)


func _grid_normal(x: float, z: float) -> Vector3:
	var e := STEP
	return Vector3(
		_grid_sample(_grid_h, x - e, z) - _grid_sample(_grid_h, x + e, z), 2.0 * e,
		_grid_sample(_grid_h, x, z - e) - _grid_sample(_grid_h, x, z + e)).normalized()


func _build_terrain(root: Node3D, spec: Dictionary, data_dir: String) -> void:
	var size: Vector2 = spec["size"]
	var nx := int(size.x / STEP) + 1
	var nz := int(size.y / STEP) + 1
	var x0 := -size.x * 0.5
	_grid_nx = nx
	_grid_nz = nz
	_grid_x0 = x0
	_grid_h = PackedFloat32Array()
	_grid_h.resize(nx * nz)
	_grid_d = PackedFloat32Array()
	_grid_d.resize(nx * nz)
	var pos := PackedVector3Array()
	pos.resize(nx * nz)
	var col := PackedColorArray()
	col.resize(nx * nz)
	for j in nz:
		for i in nx:
			var x := x0 + i * STEP
			var z := _z0 + j * STEP
			var hv := _height(x, z)
			var k := j * nx + i
			_grid_h[k] = hv.x
			_grid_d[k] = hv.y
			pos[k] = Vector3(x, hv.x, z)
			col[k] = Color(1.0 - smoothstep(0.2, 2.4, hv.y), _mud, smoothstep(7.0, 16.0, hv.y))
	# A height grid cannot hold a vertical face: where a cliff crosses it
	# diagonally it turns into stair-steps. Relax just those cells so rock
	# faces come out as clean steep slopes.
	for smooth_pass in 2:
		var relaxed := _grid_h.duplicate()
		for j in range(1, nz - 1):
			for i in range(1, nx - 1):
				var k := j * nx + i
				var lo := 1e9
				var hi := -1e9
				var sum := 0.0
				for dj in range(-1, 2):
					for di in range(-1, 2):
						var hh := _grid_h[k + dj * nx + di]
						lo = minf(lo, hh)
						hi = maxf(hi, hh)
						sum += hh
				if hi - lo > 0.75:
					relaxed[k] = lerpf(_grid_h[k], sum / 9.0, 0.8)
		_grid_h = relaxed
	for k in nx * nz:
		pos[k].y = _grid_h[k]

	var nrm := PackedVector3Array()
	nrm.resize(nx * nz)
	for j in nz:
		for i in nx:
			var il := maxi(i - 1, 0)
			var ir := mini(i + 1, nx - 1)
			var ju := maxi(j - 1, 0)
			var jd := mini(j + 1, nz - 1)
			nrm[j * nx + i] = Vector3(
				_grid_h[j * nx + il] - _grid_h[j * nx + ir], STEP * float(ir - il),
				_grid_h[ju * nx + i] - _grid_h[jd * nx + i]).normalized()
	var idx := PackedInt32Array()
	idx.resize((nx - 1) * (nz - 1) * 6)
	var q := 0
	for j in nz - 1:
		for i in nx - 1:
			var a := j * nx + i
			# clockwise seen from above = front face up
			idx[q] = a
			idx[q + 1] = a + 1
			idx[q + 2] = a + nx
			idx[q + 3] = a + 1
			idx[q + 4] = a + nx + 1
			idx[q + 5] = a + nx
			q += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _terrain_mat)
	_save(mesh, data_dir + spec["name"] + "_terrain.res")
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	root.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	mi.add_child(body)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var shape := mesh.create_trimesh_shape()
	_save(shape, data_dir + spec["name"] + "_terrain_shape.res")
	cs.shape = shape
	body.add_child(cs)


# ------------------------------------------------------------------- build --

func _build(spec: Dictionary) -> void:
	var name: String = spec["name"]
	var dir: String = spec["dir"]
	var data_dir := dir + "data/"
	_seed = spec.get("seed", 1)
	_rng.seed = _seed
	_hill_amp = spec.get("hill_amp", 7.0)
	_bank_scale = spec.get("bank_scale", 1.0)
	_mud = 1.0 if spec.get("bank", "gravel") == "mud" else 0.0
	spec = _centred(spec)
	_z0 = -float(spec["size"].y) * 0.5
	var root := Node3D.new()
	root.name = name.capitalize().replace(" ", "")
	add_child(root)

	# lighting
	var we := WorldEnvironment.new()
	we.name = "Environment"
	we.environment = _env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-40.0, -55.0, 0.0)
	sun.light_energy = 1.55
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.light_angular_distance = 0.6
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 110.0
	sun.shadow_blur = 1.4
	root.add_child(sun)

	# water nodes first: the terrain is shaped around them
	_f_pts.clear()
	_f_hw.clear()
	_f_ponds.clear()
	var rivers := {}
	var ponds := {}
	for rs: Dictionary in spec.get("rivers", []):
		var river := WaterRiver.new()
		river.name = rs["name"]
		var c := Curve3D.new()
		var widths := PackedFloat32Array()
		var pts: Array = rs["points"]
		for n in pts.size():
			var p := Vector3(pts[n][0], pts[n][1], pts[n][2])
			var prev := Vector3(pts[maxi(n - 1, 0)][0], pts[maxi(n - 1, 0)][1], pts[maxi(n - 1, 0)][2])
			var next := Vector3(pts[mini(n + 1, pts.size() - 1)][0], pts[mini(n + 1, pts.size() - 1)][1], pts[mini(n + 1, pts.size() - 1)][2])
			var tan := (next - prev) / 6.0
			# monotone height: no overshoot above/below the neighbours
			var m0 := p.y - prev.y
			var m1 := next.y - p.y
			var run := Vector2(tan.x, tan.z).length()
			var l0 := maxf(Vector2(p.x - prev.x, p.z - prev.z).length(), 0.01)
			var l1 := maxf(Vector2(next.x - p.x, next.z - p.z).length(), 0.01)
			var s0 := m0 / l0
			var s1 := m1 / l1
			var slope := 0.0
			if s0 * s1 > 0.0:
				slope = 2.0 * s0 * s1 / (s0 + s1)
			tan.y = slope * run
			c.add_point(p, -tan, tan)
			widths.append(pts[n][3])
		river.curve = c
		river.widths = widths
		river.discharge = rs.get("discharge", 1.5)
		river.style = load(ADDON + "styles/%s.tres" % rs["style"])
		root.add_child(river)
		rivers[rs["name"]] = river
		var samples := PackedVector3Array()
		var hws := PackedFloat32Array()
		var length := c.get_baked_length()
		var s := 0.0
		river.frame_at(0.0)   # finds the waterfalls
		while s <= length:
			var sp := c.sample_baked(s, true)
			# the ground steps down just past a waterfall's lip, so the water
			# arcs clear of the rock instead of sliding down a ramp
			for fl: Array in river._falls:
				if s > fl[0] and s < fl[1]:
					var lip: Vector2 = fl[4]
					var th := clampf(Vector2(sp.x - lip.x, sp.z - lip.y).length() / float(fl[5]), 0.0, 1.0)
					sp.y = fl[2] if th < 0.06 else fl[3]
			samples.append(sp)
			hws.append(river.width_at_offset(s))
			s += 0.5
		# the channel continues past both ends of the river (to the terrain
		# edge or into a pond), so the flow never runs into a wall
		var ext_a := PackedVector3Array()
		var ext_hw_a := PackedFloat32Array()
		var d0 := (samples[0] - samples[2]).normalized()
		var d1 := (samples[samples.size() - 1] - samples[samples.size() - 3]).normalized()
		for e in range(16, 0, -1):
			ext_a.append(samples[0] + d0 * 0.5 * e)
			ext_hw_a.append(hws[0])
		ext_a.append_array(samples)
		ext_hw_a.append_array(hws)
		for e in range(1, 17):
			ext_a.append(samples[samples.size() - 1] + d1 * 0.5 * e)
			ext_hw_a.append(hws[hws.size() - 1])
		_f_pts.append(ext_a)
		_f_hw.append(ext_hw_a)
		if rs.has("label"):
			var label := Label3D.new()
			label.name = "Label_" + String(rs["name"])
			label.text = rs["label"]
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.outline_size = 10
			var lp: Array = pts[pts.size() - 3]
			label.position = Vector3(lp[0], lp[1] + 2.2, lp[2])
			label.pixel_size = 0.008
			root.add_child(label)
	for ps: Dictionary in spec.get("ponds", []):
		var pond := WaterPond.new()
		pond.name = ps["name"]
		var c3: Vector3 = ps["center"]
		pond.position = c3
		var outline := PackedVector2Array()
		var world_outline := PackedVector2Array()
		for n in 26:
			var a := TAU * float(n) / 26.0
			var r := _pond_r(ps, a)
			outline.append(Vector2(cos(a) * r, sin(a) * r))
			world_outline.append(Vector2(c3.x + cos(a) * r, c3.z + sin(a) * r))
		pond.outline = outline
		pond.style = load(ADDON + "styles/%s.tres" % ps["style"])
		root.add_child(pond)
		ponds[ps["name"]] = pond
		# the basin is a little larger than the outline so the surface always
		# reaches the bank
		var basin := PackedVector2Array()
		for n in world_outline.size():
			basin.append(Vector2(c3.x, c3.z) + (world_outline[n] - Vector2(c3.x, c3.z)) * 1.04)
		_f_ponds.append([c3, basin, ps["depth"]])

	_build_terrain(root, spec, data_dir)
	_place_rocks(root, spec, rivers)
	_place_vegetation(root, spec, data_dir)

	var junctions: Array[WaterJunction] = []
	for js: Dictionary in spec.get("junctions", []):
		var j := WaterJunction.new()
		j.name = js["name"]
		root.add_child(j)
		j.direction = WaterJunction.Direction.RIVER_INTO_POND if js["into_pond"] \
			else WaterJunction.Direction.POND_INTO_RIVER
		j.river_path = j.get_path_to(rivers[js["river"]])
		j.pond_path = j.get_path_to(ponds[js["pond"]])
		junctions.append(j)

	# camera / player
	if spec.has("player"):
		var pp := _place(spec["player"], rivers)
		pp.y = _grid_sample(_grid_h, pp.x, pp.z) + 0.2
		root.add_child(_make_player(pp))
	else:
		var cam := Camera3D.new()
		cam.name = "Camera"
		cam.set_script(load(SH + "fly_camera.gd"))
		cam.fov = 62.0
		root.add_child(cam)
		if spec.has("camera_at"):
			# [river, offset_along, side_offset, height, look_at_offset_along]
			var ca: Array = spec["camera_at"]
			var cr: WaterRiver = rivers[ca[0]]
			var cf := cr.frame_at(float(ca[1]))
			cam.global_position = cf["pos"] + cf["side"] * float(ca[2]) + Vector3.UP * float(ca[3])
			cam.look_at(cr.frame_at(float(ca[4]))["pos"])
		else:
			var cs: Array = spec["camera"]
			cam.global_position = cs[0]
			cam.look_at(cs[1])
		cam.current = true
	if spec.has("log_spawn"):
		var mk := Marker3D.new()
		mk.name = "LogSpawn"
		mk.position = _place(spec["log_spawn"], rivers) + Vector3.UP * 0.4
		root.add_child(mk)
	var log_n := 0
	for lp_spec in spec.get("logs", []):
		var lp := _place(lp_spec, rivers)
		var lg: Node3D = _log_scene.instantiate()
		log_n += 1
		lg.name = "Log%d" % log_n
		root.add_child(lg)
		lg.position = lp
		lg.rotation.y = _rng.randf() * TAU
	if spec.get("audio", false):
		var audio := WaterAudio.new()
		audio.name = "WaterAudio"
		root.add_child(audio)
	if spec.get("bench_path", false):
		root.add_child(_make_bench_path(rivers, ponds))
	var ui := CanvasLayer.new()
	ui.name = "UI"
	ui.set_script(load(SH + "example_ui.gd"))
	ui.set("title", spec["title"])
	ui.set("description", spec["description"])
	ui.set("allow_style_cycle", spec.get("allow_style_cycle", true))
	root.add_child(ui)

	_own(root, root)

	# bake: let physics see the colliders first
	for n in 4:
		await get_tree().physics_frame
	var baked_ponds := {}
	for j in junctions:
		var pond := j.get_pond()
		if not baked_ponds.has(pond):
			baked_ponds[pond] = true
			j.bake_all()
	for river: WaterRiver in rivers.values():
		if river.baked_segments.is_empty():
			river.bake_segments_blocking()
		river.save_baked_data(data_dir + name + "_" + String(river.name))
		var d: WaterData = river.baked_segments[0]
		print("  %s: %d rows, max %.1f m/s, %.0f ms" % [river.name, d.rows, d.max_speed, d.bake_ms])
	for pond: WaterPond in ponds.values():
		if pond.baked_data == null:
			pond.bake_blocking()
		pond.save_baked_data(data_dir + name + "_" + String(pond.name))
	await get_tree().process_frame

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		push_error("pack failed for %s" % name)
	err = ResourceSaver.save(packed, dir + name + ".tscn")
	if err != OK:
		push_error("scene save failed for %s" % name)
	root.queue_free()
	for n in 3:
		await get_tree().process_frame


## A placement is a Vector3, or [river_name, offset_along, side_offset=0]:
## a point on (or beside) that river, just above the water.
func _place(spec_pos, rivers: Dictionary) -> Vector3:
	if spec_pos is Vector3:
		return spec_pos
	var river: WaterRiver = rivers[spec_pos[0]]
	var f := river.frame_at(float(spec_pos[1]))
	var side: float = spec_pos[2] if spec_pos.size() > 2 else 0.0
	return f["pos"] + f["side"] * side + Vector3.UP * 0.35


func _own(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		if child.scene_file_path == "":
			_own(child, root)


## Returns a copy of the spec moved so the scene is centred on the origin:
## the terrain spans z = -depth/2 .. +depth/2 and the water at the middle of
## the scene sits at y = 0.
func _centred(src: Dictionary) -> Dictionary:
	var spec := src.duplicate(true)
	var size: Vector2 = spec["size"]
	var yc := 0.0
	if spec.get("ponds", []).size() > 0:
		yc = spec["ponds"][0]["center"].y
	elif spec.get("rivers", []).size() > 0:
		var pts: Array = spec["rivers"][0]["points"]
		yc = pts[pts.size() / 2][1]
	var sh := Vector3(0.0, -yc, -size.y * 0.5)
	for rs: Dictionary in spec.get("rivers", []):
		for pt: Array in rs["points"]:
			pt[1] += sh.y
			pt[2] += sh.z
	for ps: Dictionary in spec.get("ponds", []):
		ps["center"] = ps["center"] + sh
	if spec.has("camera"):
		spec["camera"] = [spec["camera"][0] + sh, spec["camera"][1] + sh]
	var logs: Array = spec.get("logs", [])
	for n in logs.size():
		if logs[n] is Vector3:
			logs[n] = logs[n] + sh
	if spec.get("log_spawn") is Vector3:
		spec["log_spawn"] = spec["log_spawn"] + sh
	return spec


func _near_fall(river: WaterRiver, s: float, margin: float) -> bool:
	for fl: Array in river._falls:
		if s > fl[0] - margin and s < fl[1] + margin:
			return true
	return false


func _place_rocks(root: Node3D, spec: Dictionary, rivers: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "Rocks"
	root.add_child(holder)
	var count := 0
	var size: Vector2 = spec["size"]
	for rs: Dictionary in spec.get("rivers", []):
		var river: WaterRiver = rivers[rs["name"]]
		var length: float = river.curve.get_baked_length()
		# in the channel (falls get their own rocks below)
		var placed := 0
		var tries := 0
		while placed < int(rs.get("rocks", 10)) and tries < 400:
			tries += 1
			var s := 2.0 + _rng.randf() * (length - 6.0)
			if _near_fall(river, s, 2.5):
				continue
			var f := river.frame_at(s)
			var hw: float = f["half_width"]
			var across := (_rng.randf() * 2.0 - 1.0) * hw * 0.8
			var p: Vector3 = f["pos"] + f["side"] * across
			var r := 0.24 + pow(_rng.randf(), 2.0) * 0.5
			count += 1
			_add_rock(holder, count, Vector3(p.x, _grid_sample(_grid_h, p.x, p.z), p.z), r)
			placed += 1
		# boulders on the banks
		var s2 := 3.0
		while s2 < length - 2.0:
			if not _near_fall(river, s2, 3.0) and _rng.randf() < float(rs.get("boulders", 0.3)):
				var f := river.frame_at(s2)
				var side_sign := -1.0 if _rng.randf() < 0.5 else 1.0
				var d: float = f["half_width"] + 0.5 + _rng.randf() * 2.5
				var p: Vector3 = f["pos"] + f["side"] * d * side_sign
				if absf(p.x) < size.x * 0.5 - 2.0 and p.z > _z0 + 1.0 and p.z < _z0 + size.y - 1.0 \
						and _grid_normal(p.x, p.z).y > 0.8:
					count += 1
					_add_rock(holder, count, Vector3(p.x, _grid_sample(_grid_h, p.x, p.z), p.z), 0.35 + _rng.randf() * 0.6)
			s2 += 2.2
		# waterfalls pour over a ledge of big rocks, with one rock sitting in
		# the water's path at the lip so the fall parts around it
		for fl: Array in river._falls:
			var lipf := river.frame_at(float(fl[0]))
			var lip: Vector3 = lipf["pos"]
			var dir: Vector3 = lipf["dir"]
			var side: Vector3 = lipf["side"]
			var hw: float = lipf["half_width"]
			for side_sign: float in [-1.0, 1.0]:
				for k in 5:
					for row in 2:
						var d := hw + 0.9 + float(k) * 1.8 + _rng.randf() * 0.6
						var p := lip + side * d * side_sign + dir * (0.2 + float(row) * 1.3 + _rng.randf() * 0.5)
						if absf(p.x) > size.x * 0.5 - 2.0:
							continue
						count += 1
						_add_rock(holder, count, Vector3(p.x, _grid_sample(_grid_h, p.x, p.z), p.z), 1.15 + _rng.randf() * 0.75)
			if rs.get("rock_in_fall", true):
				# on the bed just above the brink, not hanging over the drop, and
				# off-centre so the main current (and a drifting log) passes it
				var p := lip + side * hw * 0.38 - dir * 1.1
				count += 1
				_add_rock(holder, count, Vector3(p.x, minf(_grid_sample(_grid_h, p.x, p.z), lip.y - 0.3) - 0.2, p.z), 0.9, false)
	for ps: Dictionary in spec.get("ponds", []):
		var c: Vector3 = ps["center"]
		for n in int(ps.get("rocks", 5)):
			var a := _rng.randf() * TAU
			var rr := _pond_r(ps, a) * (0.55 + _rng.randf() * 0.5)
			var x := c.x + cos(a) * rr
			var z := c.z + sin(a) * rr
			count += 1
			_add_rock(holder, count, Vector3(x, _grid_sample(_grid_h, x, z), z), 0.4 + _rng.randf() * 0.65)


## Adds one scanned rock: `r` is its horizontal radius in metres, `pos` the
## ground point it sits on (it is sunk in a little unless `bury` is false).
func _add_rock(holder: Node3D, n: int, pos: Vector3, r: float, bury: bool = true) -> void:
	var variant := _rng.randi() % _rock_meshes.size()
	var sc := r / _rock_radius[variant]
	var body := StaticBody3D.new()
	body.name = "Rock%d" % n
	body.collision_layer = 1
	holder.add_child(body)
	body.position = pos - (Vector3.UP * _rock_height[variant] * sc * 0.22 if bury else Vector3.ZERO)
	body.rotation.y = _rng.randf() * TAU
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = _rock_meshes[variant]
	mi.scale = Vector3.ONE * sc
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var hull := ConvexPolygonShape3D.new()
	var pts := PackedVector3Array()
	for p in _rock_hulls[variant]:
		pts.append(p * sc)
	hull.points = pts
	cs.shape = hull
	body.add_child(cs)


func _place_vegetation(root: Node3D, spec: Dictionary, data_dir: String) -> void:
	var size: Vector2 = spec["size"]
	var x0 := -size.x * 0.5
	# trees: away from the water, denser far away
	var tree_xf: Array[Transform3D] = []
	var tree_density: float = spec.get("trees", 1.0)
	var attempts := int(size.x * size.y * 0.09 * tree_density)
	for n in attempts:
		var x := x0 + 2.0 + _rng.randf() * (size.x - 4.0)
		var z := _z0 + 2.0 + _rng.randf() * (size.y - 4.0)
		var d := _grid_sample(_grid_d, x, z)
		if d < 9.0 or _rng.randf() > smoothstep(8.0, 24.0, d) * 0.85 + 0.05:
			continue
		if _grid_normal(x, z).y < 0.78:
			continue
		# keep the example's viewpoint clear
		var view: Vector3 = spec["camera"][0] if spec.has("camera") else Vector3(1e6, 0, 0)
		if Vector2(x - view.x, z - view.z).length() < 6.0:
			continue
		var sc := 0.65 + _rng.randf() * 0.75
		var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(sc, sc * (0.9 + _rng.randf() * 0.3), sc))
		tree_xf.append(Transform3D(basis, Vector3(x, _grid_sample(_grid_h, x, z) - 0.15, z)))
	if not tree_xf.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _tree_mesh
		mm.instance_count = tree_xf.size()
		for n in tree_xf.size():
			mm.set_instance_transform(n, tree_xf[n])
			mm.set_instance_custom_data(n, Color(_rng.randf(), 0, 0, 0))
		_save(mm, data_dir + spec["name"] + "_trees.res")
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Trees"
		mmi.multimesh = mm
		root.add_child(mmi)

	# grass: on the banks and meadows near the water
	var grass_xf: Array[Transform3D] = []
	var spacing := 0.36
	var z := _z0 + 1.0
	while z < _z0 + size.y - 1.0:
		var x := x0 + 1.0
		while x < size.x * 0.5 - 1.0:
			var gx := x + (_rng.randf() - 0.5) * spacing
			var gz := z + (_rng.randf() - 0.5) * spacing
			var d := _grid_sample(_grid_d, gx, gz)
			x += spacing
			if d < 1.5 or d > 28.0:
				continue
			# thin out with distance and in patches
			var keep := (1.0 - smoothstep(14.0, 28.0, d)) * smoothstep(1.5, 2.8, d)
			keep *= 0.3 + 0.7 * smoothstep(0.3, 0.6, _vn(gx * 0.25, gz * 0.25, _seed + 77))
			if _rng.randf() > keep:
				continue
			if _grid_normal(gx, gz).y < 0.8:
				continue
			var sc := 0.75 + _rng.randf() * 0.7
			var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(sc, sc * (0.7 + _rng.randf() * 0.7), sc))
			grass_xf.append(Transform3D(basis, Vector3(gx, _grid_sample(_grid_h, gx, gz) - 0.03, gz)))
		z += spacing
	if not grass_xf.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _grass_mesh
		mm.instance_count = grass_xf.size()
		for n in grass_xf.size():
			mm.set_instance_transform(n, grass_xf[n])
			mm.set_instance_custom_data(n, Color(_rng.randf(), 0, 0, 0))
		_save(mm, data_dir + spec["name"] + "_grass.res")
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Grass"
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)

	# reeds: tall tufts standing in the shallow margin and on the wet bank
	if spec.get("reeds", false):
		var reed_xf: Array[Transform3D] = []
		var rz := _z0 + 1.0
		while rz < _z0 + size.y - 1.0:
			var rx := x0 + 1.0
			while rx < size.x * 0.5 - 1.0:
				var px := rx + (_rng.randf() - 0.5) * 0.35
				var pz := rz + (_rng.randf() - 0.5) * 0.35
				rx += 0.35
				var d := _grid_sample(_grid_d, px, pz)
				if d < -0.9 or d > 1.2:
					continue
				# stands of reeds, not a continuous hedge
				if _vn(px * 0.12, pz * 0.12, _seed + 91) < 0.5 or _rng.randf() > 0.6:
					continue
				var sc := 2.6 + _rng.randf() * 1.6
				var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(sc * 0.5, sc, sc * 0.5))
				reed_xf.append(Transform3D(basis, Vector3(px, _grid_sample(_grid_h, px, pz) - 0.05, pz)))
			rz += 0.35
		if not reed_xf.is_empty():
			var rmm := MultiMesh.new()
			rmm.transform_format = MultiMesh.TRANSFORM_3D
			rmm.use_custom_data = true
			rmm.mesh = _grass_mesh
			rmm.instance_count = reed_xf.size()
			for n in reed_xf.size():
				rmm.set_instance_transform(n, reed_xf[n])
				rmm.set_instance_custom_data(n, Color(0.6 + 0.4 * _rng.randf(), 0, 0, 0))
			_save(rmm, data_dir + spec["name"] + "_reeds.res")
			var rmmi := MultiMeshInstance3D.new()
			rmmi.name = "Reeds"
			rmmi.multimesh = rmm
			rmmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(rmmi)
		print("  reeds: %d" % reed_xf.size())
	print("  vegetation: %d trees, %d grass tufts" % [tree_xf.size(), grass_xf.size()])


func _make_player(pos: Vector3) -> CharacterBody3D:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.collision_layer = 4
	player.collision_mask = 1 | 2
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.33
	capsule.height = 1.75
	shape.shape = capsule
	shape.position.y = 0.875
	player.add_child(shape)
	var mesh := MeshInstance3D.new()
	mesh.name = "Body"
	var cm := CapsuleMesh.new()
	cm.radius = 0.33
	cm.height = 1.75
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.62, 0.22, 0.14)
	pm.roughness = 0.7
	cm.material = pm
	mesh.mesh = cm
	mesh.position.y = 0.875
	player.add_child(mesh)
	var inter := WaterInteractor.new()
	inter.name = "WaterInteractor"
	player.add_child(inter)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.position.y = 1.55
	pivot.rotation.x = -0.25
	player.add_child(pivot)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.position = Vector3(0.0, 0.3, 3.3)
	cam.fov = 65.0
	cam.current = true
	pivot.add_child(cam)
	player.set_script(load(SH + "player.gd"))
	player.position = pos
	# face downstream (+z)
	player.rotation.y = PI
	return player


func _make_bench_path(rivers: Dictionary, ponds: Dictionary) -> Path3D:
	var path := Path3D.new()
	path.name = "BenchPath"
	var c := Curve3D.new()
	var stream: WaterRiver = rivers["Stream"]
	var outlet: WaterRiver = rivers["Outlet"]
	var pond: WaterPond = ponds["Pond"]
	for river: WaterRiver in [stream, outlet]:
		var length: float = river.curve.get_baked_length()
		var s := 2.0
		while s < length:
			var f := river.frame_at(s)
			var p: Vector3 = f["pos"] + f["side"] * (f["half_width"] + 2.5) + Vector3.UP * 2.3
			c.add_point(p)
			s += 6.0
		if river == stream:
			c.add_point(pond.position + Vector3(9.0, 2.6, 0.0))
	path.curve = c
	return path
