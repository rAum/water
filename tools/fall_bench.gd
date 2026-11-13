# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Waterfall cost: fixed cameras on 03_waterfall's fall (front, close, in
## the mist at the foot), vsync off. Per view: average and 95th-percentile
## frame time, and the time with the river hidden (water + its particles
## off) - the difference is what the fall costs. Metal has no GPU
## timestamps, so run at a high resolution to make the frame GPU-bound.
## Run: godot --path . res://tools/fall_bench.tscn --resolution 2560x1600 [-- quality=3 secs=4]

var _scene: Node3D
var _cam: Camera3D
var _quality := 3
var _secs := 4.0
var _off: PackedStringArray = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("quality="):
			_quality = int(a.substr(8))
		elif a.begins_with("secs="):
			_secs = float(a.substr(5))
		elif a.begins_with("off="):
			# switch parts off to see what they cost: impact,mist,fall,spray
			_off = a.substr(4).split(",")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_scene = load("res://examples/03_waterfall.tscn").instantiate()
	add_child(_scene)
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
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	if mgr != null:
		mgr.quality = _quality
	var rv := _scene.get_node("Stream") as WaterRiver
	if rv._spray != null:
		for part in _off:
			var em = rv._spray.get("_" + part)
			if em != null:
				em.visible = false
				em.emitting = false
				em.set_process(false)
		rv._spray.set_process(_off.is_empty())
	var views := {
		"front": [44.0, 0.0, 1.6, 36.0],
		"close": [41.5, -0.6, 1.4, 36.5],
		"foot": [42.0, 1.0, 0.6, 38.0],
	}
	print("fall_bench: %s, quality %d, window %s, off %s" % [RenderingServer.get_video_adapter_name(), _quality, str(DisplayServer.window_get_size()), str(_off)])
	for name: String in views:
		var v: Array = views[name]
		var f := rv.frame_at(v[0])
		var pos: Vector3 = rv.global_transform * (f["pos"] + f["side"] * float(v[1]))
		_cam.global_position = pos + Vector3.UP * float(v[2])
		_cam.look_at(rv.global_transform * (rv.frame_at(v[3])["pos"] as Vector3))
		_cam.make_current()
		rv.visible = true
		var on := await _measure(_secs)
		rv.visible = false
		var off := await _measure(_secs)
		rv.visible = true
		print("%-6s avg %6.2f ms  p95 %6.2f ms | river hidden %6.2f ms | fall+river cost %5.2f ms" % [name, on[0], on[1], off[0], on[0] - off[0]])
	get_tree().quit()
