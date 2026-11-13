# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Records the short README clips: scripted play in the demo (the real
## player, camera and keys), one PNG per frame into tools/clips/<name>/.
## tools/make_gifs.sh turns them into small GIFs in docs/images/.
## Run (deterministic timing: one frame = 1/30 s):
##   godot --path . res://tools/record_clips.tscn --resolution 640x360 --fixed-fps 30 -- clip=wade
## Clips: wade, shove, carry, fall, styles, flow

const FPS := 30.0

var _demo: Node3D
var _player: CharacterBody3D
var _caption: Label
var _clip := "wade"
var _dir := ""
var _frame := 0
var _recording := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("clip="):
			_clip = a.substr(5)
	_demo = load("res://examples/demo/demo.tscn").instantiate()
	add_child(_demo)
	var ui := _demo.get_node_or_null("UI") as CanvasLayer
	if ui != null:
		# keep it working (it handles the keys), but draw nothing of it
		ui.visible = false
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_caption = Label.new()
	_caption.add_theme_font_size_override("font_size", 30)
	_caption.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_caption.add_theme_constant_override("shadow_offset_x", 1)
	_caption.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(_caption)
	# (the project scales the UI from its base size: anchor, not pixels)
	_caption.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 18)
	_player = _demo.get_node("Player") as CharacterBody3D
	_run.call_deferred()


func _process(_delta: float) -> void:
	if not _recording:
		return
	# (after the frame is drawn: grab what the previous frame showed)
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/f%04d.png" % [_dir, _frame])
	_frame += 1


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


func _tap(code: Key) -> void:
	_key(code, true)
	await get_tree().process_frame
	_key(code, false)


func _wait(sec: float) -> void:
	for i in int(sec * FPS):
		await get_tree().process_frame


## Puts the player on a river: s metres along, side metres across,
## yaw_deg relative to downstream (180 = facing upstream), camera pitch.
func _place(river: String, s: float, side: float, yaw_deg: float, pitch: float) -> void:
	var rv := _demo.get_node(river) as WaterRiver
	var f := rv.frame_at(s)
	var pos: Vector3 = rv.global_transform * (f["pos"] + f["side"] * side)
	var dir: Vector3 = rv.global_transform.basis * (f["dir"] as Vector3)
	var yaw := atan2(-dir.x, -dir.z) + deg_to_rad(yaw_deg)
	_player.global_position = pos + Vector3.UP * 0.4
	_player.velocity = Vector3.ZERO
	_player.rotation.y = yaw
	_player.set("_yaw", yaw)
	_player.set("_pitch", pitch)
	(_player.get_node("CameraPivot") as Node3D).rotation.x = pitch


## A log lying on the water dist metres in front of the player.
func _log_ahead(dist: float, across := true, side := 0.0) -> RigidBody3D:
	var lg: RigidBody3D = load("res://examples/shared/log.tscn").instantiate()
	_demo.add_child(lg)
	var yaw: float = _player.get("_yaw")
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var at := _player.global_position + fwd * dist + Vector3(-fwd.z, 0.0, fwd.x) * side
	var mgr := get_tree().root.get_node("WaterManager")
	var h: float = mgr.get_height(at)
	if is_nan(h):
		h = at.y
	lg.global_transform = Transform3D(Basis(Vector3.UP, yaw + (PI * 0.5 if across else 0.0)),
		Vector3(at.x, h + 0.1, at.z))
	return lg


## Turns the camera boom: yaw by dyaw (radians), pitch to pitch.
func _look(dyaw: float, pitch: float) -> void:
	var yaw: float = float(_player.get("_yaw")) + dyaw
	_player.set("_yaw", yaw)
	_player.rotation.y = yaw
	_player.set("_pitch", pitch)
	(_player.get_node("CameraPivot") as Node3D).rotation.x = pitch


func _start(caption: String) -> void:
	_caption.text = caption
	_dir = ProjectSettings.globalize_path("res://tools/clips/" + _clip)
	DirAccess.make_dir_recursive_absolute(_dir)
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir + "/" + f)
	_frame = 0
	_recording = true


func _run() -> void:
	await _wait(2.0)
	match _clip:
		"wade":
			_place("Stream", 9.0, 0.3, 0.0, -0.3)
			await _wait(1.0)
			_start("Wading: ripples, wake and the current's push")
			_key(KEY_W, true)
			await _wait(3.0)
			_key(KEY_W, false)
		"shove":
			# (looking down over the player's shoulder: the capsule would
			# hide a log straight ahead)
			_place("Outlet", 6.0, 0.0, 0.0, -0.7)
			await _wait(0.5)
			_log_ahead(2.6, true, 0.15)
			await _wait(1.0)
			_start("Walk into a floating log to shove it")
			await _wait(0.4)
			_key(KEY_SHIFT, true)
			_key(KEY_W, true)
			await _wait(0.9)
			_key(KEY_W, false)
			_key(KEY_SHIFT, false)
			await _wait(2.2)
		"carry":
			_place("Outlet", 6.0, -0.4, 0.0, -0.7)
			await _wait(0.5)
			_log_ahead(1.7, false, 0.55)
			await _wait(1.0)
			_start("Pick up a log (E) and throw it (F)")
			await _wait(0.5)
			await _tap(KEY_E)
			await _wait(0.4)
			for k in 12:
				_look(0.0, lerpf(-0.7, -0.42, float(k + 1) / 12.0))
				await get_tree().process_frame
			await _wait(0.4)
			await _tap(KEY_F)
			await _wait(2.0)
		"fall":
			_place("Stream", 37.0, 0.0, 180.0, -0.12)
			await _wait(1.0)
			_start("Step into the waterfall: the sheet parts around you")
			_key(KEY_W, true)
			await _wait(0.75)
			_key(KEY_W, false)
			await _wait(0.3)
			# swing the camera round to the side: the gap is behind the body
			for k in 45:
				_look(0.9 / 45.0, -0.12)
				await get_tree().process_frame
			await _wait(1.0)
			_key(KEY_S, true)
			await _wait(0.5)
			_key(KEY_S, false)
			await _wait(1.0)
		"styles":
			_place("Stream", 40.0, 1.6, 160.0, -0.2)
			await _wait(1.0)
			var styles := ["spring", "clear_mountain", "glacial", "lowland", "peat", "muddy", "stylized", "toon"]
			_start("Style: " + styles[0])
			for k in range(1, styles.size()):
				await _wait(0.75)
				await _tap(KEY_5)
				_caption.text = "Style: " + styles[k]
			await _wait(0.75)
		"flow":
			_place("Stream", 26.0, 1.8, 200.0, -0.3)
			await _wait(1.0)
			_start("Flow: x1.0 - the river is re-baked live")
			await _wait(1.2)
			for k in 3:
				await _tap(KEY_BRACKETRIGHT)
				await _wait(1.3)
				_caption.text = "Flow: x%.1f - the river is re-baked live" % pow(1.4, k + 1)
		_:
			print("unknown clip ", _clip)
	_recording = false
	print("clip %s: %d frames in %s" % [_clip, _frame, _dir])
	get_tree().quit()
