# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Sleep and streaming on the demo, with the manager's sim_focus moved away
## and back:
## - far away every floater is frozen and stays put, every body's flow data
##   is released and queries find no water there;
## - back at the water the data is read back in the background, queries
##   answer exactly as before and the logs float on again.
## Run: godot --path . res://tools/stream_check.tscn  (exit code 1 on failure)

var _fails := 0


func _fail(msg: String) -> void:
	_fails += 1
	print("   FAIL ", msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var mgr := get_tree().root.get_node("WaterManager")
	var demo: Node = load("res://examples/demo/demo.tscn").instantiate()
	add_child(demo)
	var player := demo.get_node_or_null("Player")
	if player != null:
		player.process_mode = Node.PROCESS_MODE_DISABLED
	var focus := Node3D.new()
	add_child(focus)
	var logs: Array[RigidBody3D] = []
	var floaters: Array = []
	for n in demo.get_children():
		if n is RigidBody3D:
			for c in n.get_children():
				if c is WaterFloater:
					logs.append(n)
					floaters.append(c)
	var log_home: Vector3 = logs[0].global_position
	focus.global_position = log_home
	mgr.sim_focus = focus
	for n in 60:
		await get_tree().physics_frame

	# sample the water while everything is loaded
	var box := AABB()
	var bodies: Array = mgr.get_bodies()
	for i in bodies.size():
		box = bodies[i].get_water_aabb() if i == 0 else box.merge(bodies[i].get_water_aabb())
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var pts: Array[Vector3] = []
	var before: Array = []
	while pts.size() < 400:
		var p := Vector3(rng.randf_range(box.position.x, box.end.x), 0.0,
			rng.randf_range(box.position.z, box.end.z))
		p.y = box.end.y
		var q = mgr.query(p)
		if q.valid:
			p.y = q.height - 0.1
			q = mgr.query(p)
			pts.append(p)
			before.append([q.valid, q.height, q.flow, q.depth])
	var bytes := 0
	var datas := {}
	for b in bodies:
		for d in mgr._body_data(b):
			if not datas.has(d):
				datas[d] = true
				bytes += d.cell_bytes()
	print("demo: %d bodies, %d data files, %.1f MB of per-cell arrays, %d floaters" % [
		bodies.size(), datas.size(), bytes / 1048576.0, floaters.size()])

	# --- far away ---------------------------------------------------------------
	mgr.sim_distance = 40.0
	mgr.stream_distance = 60.0
	focus.global_position = log_home + Vector3(3000, 0, 0)
	for n in 30:
		await get_tree().physics_frame
	var at_sleep: Array = logs.map(func(l): return l.global_position)
	for n in 120:
		await get_tree().physics_frame
	var awake: Array = floaters.filter(func(f): return not f.is_sim_asleep() or not f.get_parent().freeze)
	if not awake.is_empty():
		_fail("%d of %d floaters still awake 3 km away" % [awake.size(), floaters.size()])
	var moved := 0
	for i in logs.size():
		if logs[i].global_position.distance_to(at_sleep[i]) > 0.001:
			moved += 1
	if moved > 0:
		_fail("%d sleeping logs moved" % moved)
	var resident: Array = datas.keys().filter(func(d): return d.is_resident())
	if not resident.is_empty():
		_fail("%d of %d data files still loaded" % [resident.size(), datas.size()])
	var loaded_bodies: Array = bodies.filter(func(b): return mgr.is_body_loaded(b))
	if not loaded_bodies.is_empty():
		_fail("%d bodies still report loaded" % loaded_bodies.size())
	var left := 0
	for d in datas:
		left += d.cell_bytes()
	# a released pond still answers with its level and still water; a
	# released river answers nothing
	var wet := 0
	for p in pts:
		var q = mgr.query(p)
		if q.valid and not (q.body is WaterPond and q.flow == Vector3.ZERO):
			wet += 1
	if wet > 0:
		_fail("%d queries found moving water over released data" % wet)
	print("far: %d floaters asleep, %.1f MB released (%.2f MB left), %d queries on moving water" % [
		floaters.size() - awake.size(), (bytes - left) / 1048576.0, left / 1048576.0, wet])

	# --- back ---------------------------------------------------------------------
	focus.global_position = log_home
	var t0 := Time.get_ticks_msec()
	var back_ms := -1
	for n in 600:
		await get_tree().process_frame
		if datas.keys().all(func(d): return d.is_resident()) and bodies.all(func(b): return mgr.is_body_loaded(b)):
			back_ms = Time.get_ticks_msec() - t0
			break
	if back_ms < 0:
		_fail("data not back within 600 frames")
	var diff := 0
	for k in pts.size():
		var q = mgr.query(pts[k])
		var b: Array = before[k]
		if q.valid != b[0] or (q.valid and (absf(q.height - b[1]) > 1e-5 or q.flow.distance_to(b[2]) > 1e-5 or absf(q.depth - b[3]) > 1e-5)):
			diff += 1
			if diff <= 5:
				print("   diff at %s before=%s now=%s,%s,%s body=%s" % [pts[k], b, q.height, q.flow, q.depth,
					q.body.name if q.body else "-"])
	if diff > 0:
		_fail("%d of %d queries differ after reloading" % [diff, pts.size()])
	for n in 30:
		await get_tree().physics_frame
	var near_awake := 0
	var near_total := 0
	for f in floaters:
		if f.global_position.distance_to(log_home) < 40.0:
			near_total += 1
			if not f.is_sim_asleep() and not f.get_parent().freeze:
				near_awake += 1
	if near_awake != near_total or near_total == 0:
		_fail("%d of %d floaters near the focus awake" % [near_awake, near_total])
	var p0 := logs[0].global_position
	for n in 120:
		await get_tree().physics_frame
	var drift := logs[0].global_position.distance_to(p0)
	var q0 = mgr.query(logs[0].global_position)
	if drift < 0.2:
		_fail("woken log did not drift (%.2f m in 2 s)" % drift)
	if q0.valid and absf(logs[0].global_position.y - q0.height) > 0.5:
		_fail("woken log %.2f m off the surface" % (logs[0].global_position.y - q0.height))
	print("back: data loaded in %d ms, %d queries checked (%d differ), %d/%d floaters awake, log drifted %.2f m" % [
		back_ms, pts.size(), diff, near_awake, near_total, drift])
	print("stream_check: %d failure(s)" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
