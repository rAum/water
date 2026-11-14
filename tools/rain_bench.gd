# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Rain cost: a fixed view over the demo's pond and stream (water filling
## most of the screen), vsync off. Average and 95th-percentile frame time
## with no rain, with raindrop ripples only, and with ripples + falling
## rain, at intensity 1. Metal has no GPU timestamps, so run at a high
## resolution to make the frame GPU-bound.
## Run: godot --path . res://tools/rain_bench.tscn --resolution 2560x1600 [-- quality=3 secs=4]

var _scene: Node3D
var _cam: Camera3D
var _quality := 3
var _secs := 4.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("quality="):
			_quality = int(a.substr(8))
		elif a.begins_with("secs="):
			_secs = float(a.substr(5))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_scene = load("res://examples/demo/demo.tscn").instantiate()
	add_child(_scene)
	var ui := _scene.get_node_or_null("UI")
	if ui != null:
		ui.visible = false
	_cam = Camera3D.new()
	add_child(_cam)
	_run.call_deferred()


func _measure(sec: float) -> Array:
	await get_tree().create_timer(1.0).timeout
	var times := PackedFloat32Array()
	var t0 := Time.get_ticks_usec()
	var last := t0
	while Time.get_ticks_usec() - t0 < int(sec * 1e6):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times.append(float(now - last) / 1000.0)
		last = now
	times.sort()
	var sum := 0.0
	for t in times:
		sum += t
	return [sum / times.size(), times[int(times.size() * 0.95)]]


func _run() -> void:
	for i in 30:
		await get_tree().process_frame
	var mgr := get_tree().root.get_node("WaterManager")
	mgr.quality = _quality
	_cam.global_position = Vector3(1.0, 1.4, 3.0)
	_cam.look_at(Vector3(1.0, 0.0, -1.5))
	_cam.make_current()
	print("rain_bench: %s, quality %d, window %s" % [RenderingServer.get_video_adapter_name(), _quality, str(DisplayServer.window_get_size())])
	var base := [0.0]
	for mode: String in ["off", "ripples", "ripples+streaks", "off "]:
		mgr.rain_ripples = 0.0 if mode.begins_with("off") else 1.0
		mgr.rain_intensity = 1.0 if mode == "ripples+streaks" else 0.0
		var r := await _measure(_secs)
		if mode == "off":
			base[0] = r[0]
		print("%-16s avg %6.2f ms  p95 %6.2f ms  delta %+5.2f ms" % [mode, r[0], r[1], r[0] - base[0]])
	get_tree().quit()
