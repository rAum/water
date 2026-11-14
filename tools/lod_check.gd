# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Open-world LOD checks on the example scenes:
## - the query grid answers exactly like asking every body (random points
##   over and around the water), and how much faster;
## - every river chunk carries distance LOD index buffers, coarser per level;
## - chunks and pond tiles switch to the far shader when the camera is far
##   and back when it returns;
## - draw_distance reaches every water mesh instance.
## Run: godot --path . res://tools/lod_check.tscn  (exit code 1 on failure)
const SCENES := [
	"res://examples/02_pond.tscn",
	"res://examples/03_waterfall.tscn",
	"res://examples/04_river_pond_river.tscn",
	"res://examples/demo/demo.tscn",
]

var _fails := 0


func _ready() -> void:
	_run.call_deferred()


func _fail(msg: String) -> void:
	_fails += 1
	print("   FAIL ", msg)


func _run() -> void:
	var mgr := get_tree().root.get_node("WaterManager")
	var cam := Camera3D.new()
	cam.far = 4000.0
	add_child(cam)
	cam.make_current()
	for path: String in SCENES:
		var scene: Node = load(path).instantiate()
		add_child(scene)
		cam.make_current()
		for n in 30:
			await get_tree().process_frame
		var bodies: Array = []
		_collect(scene, bodies)
		var box := AABB()
		for i in bodies.size():
			box = bodies[i].get_water_aabb() if i == 0 else box.merge(bodies[i].get_water_aabb())
		box = box.grow(6.0)

		# 1. grid query == brute force
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var pts: Array[Vector3] = []
		for n in 3000:
			pts.append(Vector3(rng.randf_range(box.position.x, box.end.x),
				rng.randf_range(box.position.y, box.end.y), rng.randf_range(box.position.z, box.end.z)))
		var mism := 0
		var wet := 0
		var t0 := Time.get_ticks_usec()
		var grid_res: Array = []
		for p in pts:
			var q = mgr.query(p)
			grid_res.append([q.valid, q.height, q.flow, q.body])
		var t_grid := Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		for k in pts.size():
			var b := _brute(mgr, pts[k])
			var g: Array = grid_res[k]
			if b[0]:
				wet += 1
			if b[0] != g[0] or (b[0] and (absf(b[1] - g[1]) > 1e-4 or b[2].distance_to(g[2]) > 1e-4 or b[3] != g[3])):
				mism += 1
				if mism <= 6:
					var inbox := []
					if b[3] != null:
						for bx: AABB in (b[3].get_water_boxes() if b[3].has_method("get_water_boxes") else [b[3].get_water_aabb()]):
							inbox.append(Rect2(bx.position.x, bx.position.z, bx.size.x, bx.size.z).grow(1.0).has_point(Vector2(pts[k].x, pts[k].z)))
					var rv = b[3]
					if rv is WaterRiver:
						var so: float = rv.curve.get_closest_offset(rv.to_local(pts[k]))
						var cp: Vector3 = rv.to_global(rv.curve.sample_baked(so))
						print("     s=%.2f of %.2f closest=%s ja=%s jb=%s segs=%d" % [so, rv.curve.get_baked_length(), cp, rv._junction_a, rv._junction_b, rv.baked_segments.size()])
					print("   diff at %s brute=%s(%s) grid=%s(%s) in boxes %s" % [pts[k], b[0], b[3].name if b[3] else "-", g[0], g[3].name if g[3] else "-", inbox])
		var t_brute := Time.get_ticks_usec() - t0
		if mism > 0:
			_fail("%s: %d of %d queries differ from brute force" % [path.get_file(), mism, pts.size()])

		# 2. LOD index buffers on river chunks
		var chunks := 0
		var lod_ok := 0
		for b in bodies:
			if b is WaterRiver:
				for c: MeshInstance3D in b._chunks:
					chunks += 1
					var surf: Dictionary = RenderingServer.mesh_get_surface(c.mesh.get_rid(), 0)
					var lods: Array = surf.get("lods", [])
					var full: int = c.mesh.surface_get_array_index_len(0)
					var ok := lods.size() >= 2
					var prev_n := full
					var prev_e := 0.0
					for l: Dictionary in lods:
						var n: int = l["index_data"].size() / 4
						var e: float = l["edge_length"]
						ok = ok and n < prev_n and e > prev_e
						prev_n = n
						prev_e = e
					if ok:
						lod_ok += 1
					elif lod_ok == chunks - 1:
						print("   chunk lods: full=%d %s" % [full, str(lods.map(func(l): return [l["edge_length"], l["index_data"].size() / 4]))])
		if lod_ok != chunks:
			_fail("%s: %d of %d chunks lack proper LODs" % [path.get_file(), chunks - lod_ok, chunks])

		# 3. far switching: camera far above, then back at the water
		var center := box.get_center()
		cam.global_position = center + Vector3(0, 2500, 0)
		for n in 4:
			await get_tree().process_frame
		var near_left := 0
		var meshes := _meshes(bodies)
		for mi: MeshInstance3D in meshes:
			var mat := mi.material_override as ShaderMaterial
			if mat == null or not String(mat.shader.resource_path).ends_with("_far.gdshader"):
				near_left += 1
		if near_left > 0:
			_fail("%s: %d of %d meshes not on the far shader from 2.5 km" % [path.get_file(), near_left, meshes.size()])
		cam.global_position = center + Vector3(0, 2, 0)
		for n in 4:
			await get_tree().process_frame
		var near_any := false
		for mi: MeshInstance3D in meshes:
			var mat := mi.material_override as ShaderMaterial
			if mat != null and not String(mat.shader.resource_path).ends_with("_far.gdshader"):
				near_any = true
		if not near_any:
			_fail("%s: nothing returned to the near shader at the water" % path.get_file())

		# 4. draw distance
		mgr.draw_distance = 300.0
		var ranged := 0
		for mi: MeshInstance3D in meshes:
			if mi.visibility_range_end > 0.0 and mi.visibility_range_end <= 300.0:
				ranged += 1
		mgr.draw_distance = 0.0
		var cleared := meshes.all(func(mi): return mi.visibility_range_end == 0.0)
		if ranged != meshes.size() or not cleared:
			_fail("%s: draw distance reached %d of %d meshes (cleared %s)" % [path.get_file(), ranged, meshes.size(), cleared])

		print("%s: %d bodies, %d meshes, %d chunks with LODs; queries %d (%d wet) grid %.1f us vs all-bodies %.1f us" % [
			path.get_file(), bodies.size(), meshes.size(), lod_ok, pts.size(), wet,
			float(t_grid) / pts.size(), float(t_brute) / pts.size()])
		scene.queue_free()
		for n in 5:
			await get_tree().process_frame
	await _scale_bench(mgr)
	print("lod_check: %d failure(s)" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


## Timing only: 100 copies of the waterfall river spread over 3 x 3 km
## (their bakes stay where the original was, so answers are meaningless;
## the cost of asking every body is what is measured).
func _scale_bench(mgr: Node) -> void:
	var scene: Node = load("res://examples/03_waterfall.tscn").instantiate()
	add_child(scene)
	for n in 10:
		await get_tree().process_frame
	var bodies: Array = []
	_collect(scene, bodies)
	var river: Node3D = bodies[0]
	for k in 99:
		var dup := river.duplicate() as Node3D
		scene.add_child(dup)
		dup.global_position = river.global_position + Vector3((k % 10) * 300.0, 0.0, (k / 10) * 300.0)
	for n in 10:
		await get_tree().process_frame
	var pts: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for n in 2000:
		pts.append(river.global_position + Vector3(rng.randf_range(-50, 3000), 0.0, rng.randf_range(-50, 3000)))
	var t0 := Time.get_ticks_usec()
	for p in pts:
		mgr.query(p)
	var t_grid := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for p in pts:
		_brute(mgr, p)
	var t_brute := Time.get_ticks_usec() - t0
	print("scale: %d rivers, query grid %.1f us vs all-bodies %.1f us" % [mgr.get_bodies().size(),
		float(t_grid) / pts.size(), float(t_brute) / pts.size()])
	scene.queue_free()
	for n in 5:
		await get_tree().process_frame


## The query as it was before the grid: every body asked.
func _brute(mgr: Node, pos: Vector3) -> Array:
	var total_w := 0.0
	var height := 0.0
	var flow := Vector3.ZERO
	var best_w := 0.0
	var best: Node = null
	for body in mgr.get_bodies():
		if not body.has_method("query_water"):
			continue
		var r: Array = body.query_water(pos)
		if r.is_empty() or r[3] <= 0.0:
			continue
		total_w += r[3]
		height += r[0] * r[3]
		flow += r[1] * r[3]
		if r[3] > best_w:
			best_w = r[3]
			best = body
	if total_w <= 0.0:
		return [false, NAN, Vector3.ZERO, null]
	return [true, height / total_w, flow / total_w, best]


func _meshes(bodies: Array) -> Array:
	var out := []
	for b in bodies:
		if b is WaterRiver:
			out.append_array(b._chunks)
		elif b is WaterPond:
			out.append_array(b._tiles)
	return out


func _collect(n: Node, out: Array) -> void:
	if n is WaterRiver or n is WaterPond:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)
