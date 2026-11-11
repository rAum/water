# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node3D
## Look-dev capture tool. Loads a scene, waits for bakes, renders shots.
## Run: godot --path . res://tools/screenshot.tscn -- scene=res://... \
##        shot=name:px,py,pz:lx,ly,lz [shot=...] [wait=3] [debug=N] [style=name] [player=x,y,z]

var scene: Node
var cam: Camera3D
var _ripples: Array[Vector3] = []
var _quality := -1
var _storm := -1.0
var _t := 0.0


func _process(delta: float) -> void:
	# keep disturbing the water at the requested points (a walking player)
	_t += delta
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	if mgr == null:
		return
	for n in _ripples.size():
		if Engine.get_process_frames() % 9 == n % 9:
			var p := _ripples[n] + Vector3(sin(_t * 1.3 + n), 0, cos(_t * 0.9 + n)) * 0.6
			mgr.add_ripple(p, 0.05, 0.35)


func _ready() -> void:
	var scene_path := "res://examples/demo/demo.tscn"
	var shots: Array = []
	var wait := 2.5
	var debug := -1
	var style := ""
	var fov := 60.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("scene="):
			scene_path = a.substr(6)
		elif a.begins_with("shot="):
			shots.append(a.substr(5))
		elif a.begins_with("wait="):
			wait = float(a.substr(5))
		elif a.begins_with("debug="):
			debug = int(a.substr(6))
		elif a.begins_with("style="):
			style = a.substr(6)
		elif a.begins_with("fov="):
			fov = float(a.substr(4))
		elif a.begins_with("ripple="):
			var r := a.substr(7).split(",")
			_ripples.append(Vector3(float(r[0]), float(r[1]), float(r[2])))
		elif a.begins_with("storm="):
			_storm = float(a.substr(6))
		elif a.begins_with("quality="):
			_quality = int(a.substr(8))
		elif a.begins_with("underwater="):
			# underwater=0 switches the underwater view off (raw surface from below)
			get_tree().root.get_node("WaterManager").underwater_enabled = a.substr(11) != "0"
	scene = load(scene_path).instantiate()
	add_child(scene)
	cam = Camera3D.new()
	cam.fov = fov
	add_child(cam)
	cam.current = true
	_run.call_deferred(shots, wait, debug, style)


func _bodies(n: Node, out: Array) -> void:
	if n is WaterRiver or n is WaterPond:
		out.append(n)
	for c in n.get_children():
		_bodies(c, out)


func _run(shots: Array, wait: float, debug: int, style: String) -> void:
	# let scenes that bake at startup finish
	for i in 30:
		await get_tree().process_frame
	var bodies: Array = []
	_bodies(scene, bodies)
	var tries := 0
	while tries < 600:
		var ready := true
		for b in bodies:
			if b is WaterRiver and b.baked_segments.is_empty():
				ready = false
			if b is WaterPond and b.baked_data == null:
				ready = false
		if ready:
			break
		tries += 1
		await get_tree().process_frame
	if _quality >= 0:
		get_tree().root.get_node("WaterManager").quality = _quality
	if _storm >= 0.0:
		get_tree().root.get_node("WaterManager").storm_turbidity = _storm
	if style != "":
		var st: WaterStyle = load("res://addons/flowing_water/styles/%s.tres" % style)
		for b in bodies:
			b.style = st
	if debug >= 0:
		for b in bodies:
			b.debug_view = debug
	# make sure our camera wins over any scene camera
	cam.make_current()
	var first := true
	for s: String in shots:
		var parts := s.split(":")
		if parts[1] == "at":
			# eye-level view from beside a river:
			# name:at:River:offset_along:side_offset:eye_height:look_offset_along
			var rv := scene.get_node_or_null(String(parts[2])) as WaterRiver
			var f := rv.frame_at(float(parts[3]))
			var pos: Vector3 = rv.global_transform * (f["pos"] + f["side"] * float(parts[4]))
			var space := get_viewport().find_world_3d().direct_space_state
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 30.0, pos + Vector3.DOWN * 30.0, 1))
			var ground: float = hit["position"].y if not hit.is_empty() else pos.y
			cam.global_position = Vector3(pos.x, maxf(ground, pos.y) + float(parts[5]), pos.z)
			var lf := rv.frame_at(float(parts[6]))
			cam.look_at(rv.global_transform * (lf["pos"] as Vector3))
		elif parts[1] == "cam":
			# use the scene's own camera placement
			var sc_cam := scene.get_node_or_null("Camera") as Camera3D
			if sc_cam != null:
				cam.global_transform = sc_cam.global_transform
				cam.fov = sc_cam.fov
		else:
			var p := parts[1].split(",")
			var l := parts[2].split(",")
			cam.global_position = Vector3(float(p[0]), float(p[1]), float(p[2]))
			cam.look_at(Vector3(float(l[0]), float(l[1]), float(l[2])))
		cam.make_current()
		await get_tree().create_timer(wait if first else 1.2).timeout
		first = false
		var img := get_viewport().get_texture().get_image()
		var path := "res://tools/shots/%s.png" % parts[0]
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tools/shots"))
		img.save_png(path)
		print("shot: ", path)
	get_tree().quit()
