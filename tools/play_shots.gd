# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Play-through capture: runs the demo with its own player and third-person
## camera (not a free look-dev camera), puts the player at points along a
## river and saves what the player would see, a few frames apart, so pops
## and jumps between frames show up side by side.
## Run: godot --path . res://tools/play_shots.tscn --resolution 1280x800 -- \
##        shot=name:River:s:side:yaw_deg:pitch[:walk_s] [frames=3] [gap=0.25]
## yaw_deg is relative to downstream (0 = looking downstream, 180 = upstream);
## shot=name:x,y,z:-:-:yaw_deg:pitch places the player at a world position.
## walk_s > 0 holds W for that many seconds before capturing.

var _demo: Node


func _ready() -> void:
	var scene_path := "res://examples/demo/demo.tscn"
	var shots: Array = []
	var frames := 3
	var gap := 0.25
	for a in OS.get_cmdline_user_args():
		if a.begins_with("scene="):
			scene_path = a.substr(6)
		elif a.begins_with("shot="):
			shots.append(a.substr(5))
		elif a.begins_with("frames="):
			frames = int(a.substr(7))
		elif a.begins_with("gap="):
			gap = float(a.substr(4))
	_demo = load(scene_path).instantiate()
	add_child(_demo)
	_run.call_deferred(shots, frames, gap)


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


func _run(shots: Array, frames: int, gap: float) -> void:
	for i in 60:
		await get_tree().process_frame
	var p := _demo.get_node("Player") as CharacterBody3D
	var pivot := p.get_node("CameraPivot") as Node3D
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tools/shots"))
	for s: String in shots:
		var parts := s.split(":")
		var pos: Vector3
		var yaw: float
		if parts[1].contains(","):
			# name:x,y,z:-:-:yaw_deg:pitch - a world position, absolute yaw
			var c := parts[1].split(",")
			pos = Vector3(float(c[0]), float(c[1]), float(c[2]))
			yaw = deg_to_rad(float(parts[4]))
		else:
			var rv := _demo.get_node(String(parts[1])) as WaterRiver
			var f := rv.frame_at(float(parts[2]))
			pos = rv.global_transform * (f["pos"] + f["side"] * float(parts[3]))
			var dir: Vector3 = rv.global_transform.basis * (f["dir"] as Vector3)
			yaw = atan2(-dir.x, -dir.z) + deg_to_rad(float(parts[4]))
		p.global_position = pos + Vector3.UP * 0.4
		p.velocity = Vector3.ZERO
		p.rotation.y = yaw
		p.set("_yaw", yaw)
		pivot.rotation.x = float(parts[5])
		p.set("_pitch", float(parts[5]))
		await get_tree().create_timer(1.5).timeout
		var walk := float(parts[6]) if parts.size() > 6 else 0.0
		if walk > 0.0:
			_key(KEY_W, true)
			await get_tree().create_timer(walk).timeout
		for k in frames:
			var img := get_viewport().get_texture().get_image()
			var path := "res://tools/shots/%s_%d.png" % [parts[0], k]
			img.save_png(path)
			print("shot: ", path, " player=", p.global_position)
			await get_tree().create_timer(gap).timeout
		_key(KEY_W, false)
	get_tree().quit()
