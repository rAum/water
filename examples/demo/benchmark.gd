# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node3D
## Benchmark: a fixed camera path (the demo's "BenchPath" node) at every
## quality preset. For each preset it flies the path twice - water visible
## and water hidden - and reports average / worst frame time, GPU time and
## the water-only cost (the difference). Results print to the console and
## are written to user://water_benchmark.txt.
##
## Run it from the editor, or:
##   godot --path . res://examples/demo/benchmark.tscn
## (set WATER_BENCH_QUIT=1 to quit when done)

const PASS_SECONDS := 10.0
const WARMUP_SECONDS := 1.5

var demo: Node3D
var cam: Camera3D
var path: Curve3D
var _report := ""
var _bodies: Array = []


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	demo = load("res://examples/demo/demo.tscn").instantiate()
	add_child(demo)
	# the benchmark flies its own camera; park the player
	var player := demo.get_node_or_null("Player")
	if player != null:
		player.process_mode = Node.PROCESS_MODE_DISABLED
	path = (demo.get_node("BenchPath") as Path3D).curve
	_collect(demo)
	cam = Camera3D.new()
	cam.fov = 65.0
	add_child(cam)
	cam.make_current()
	_run.call_deferred()


func _collect(n: Node) -> void:
	if n is WaterRiver or n is WaterPond:
		_bodies.append(n)
	for c in n.get_children():
		_collect(c)


func _run() -> void:
	await get_tree().create_timer(1.5).timeout
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	var vp_rid := get_viewport().get_viewport_rid()
	_log("Flowing Water benchmark - %s, %s, window %s" % [
		OS.get_name(), RenderingServer.get_video_adapter_name(),
		str(DisplayServer.window_get_size())])
	for preset in [0, 1, 2, 3]:
		if mgr != null:
			mgr.quality = preset
		await get_tree().create_timer(0.5).timeout
		var with_water := await _fly(vp_rid, true)
		var without := await _fly(vp_rid, false)
		var preset_name: String = ["Deck", "Low", "Medium", "High"][preset]
		# GPU timestamps are 0 on drivers without them (e.g. Metal): the
		# frame-time delta is the fallback water cost
		_log("%s: frame avg %.2f ms worst %.2f ms | GPU avg %.2f ms | water cost ~%.2f ms (GPU) / %.2f ms (frame delta)" % [
			preset_name, with_water["avg_frame"], with_water["worst_frame"],
			with_water["avg_gpu"],
			maxf(with_water["avg_gpu"] - without["avg_gpu"], 0.0),
			maxf(with_water["avg_frame"] - without["avg_frame"], 0.0)])
	_log("done.")
	var f := FileAccess.open("user://water_benchmark.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(_report)
		print("benchmark: written to ", ProjectSettings.globalize_path("user://water_benchmark.txt"))
	if OS.has_environment("WATER_BENCH_QUIT"):
		get_tree().quit()


func _fly(vp_rid: RID, water_visible: bool) -> Dictionary:
	for b: Node3D in _bodies:
		b.visible = water_visible
	var length := path.get_baked_length()
	var t := 0.0
	var frames := 0
	var sum_frame := 0.0
	var worst_frame := 0.0
	var sum_gpu := 0.0
	var warm := WARMUP_SECONDS
	var last := Time.get_ticks_usec()
	while t < 1.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - last) / 1000.0
		last = now
		t += (dt / 1000.0) / PASS_SECONDS
		var s := clampf(t, 0.0, 0.97) * length
		var pos := path.sample_baked(s, true)
		var ahead := path.sample_baked(minf(s + 6.0, length), true) - Vector3(0, 1.6, 0)
		cam.global_position = pos
		if (ahead - pos).cross(Vector3.UP).length() > 0.01:
			cam.look_at(ahead)
		if warm > 0.0:
			warm -= dt / 1000.0
			continue
		frames += 1
		sum_frame += dt
		worst_frame = maxf(worst_frame, dt)
		sum_gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
	return {
		"avg_frame": sum_frame / maxf(frames, 1.0),
		"worst_frame": worst_frame,
		"avg_gpu": sum_gpu / maxf(frames, 1.0),
	}


func _log(line: String) -> void:
	print("benchmark: ", line)
	_report += line + "\n"
