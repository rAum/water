# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node3D
## Frame cost of the underwater view: holds the camera under the demo pond
## and compares frame times with the effect on and off at each quality
## preset (vsync off). Metal has no GPU timestamps, so this is the
## frame-time delta, the same measure the main benchmark uses.
## Run: godot --path . res://tools/uw_bench.tscn --resolution 1280x800

const FRAMES := 240
const ROUNDS := 7


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var scene: Node = load("res://examples/demo/demo.tscn").instantiate()
	add_child(scene)
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = Vector3(2, -0.8, 3.5)
	cam.look_at(Vector3(1.5, -0.6, -6))
	cam.make_current()
	_run.call_deferred(cam)


func _measure() -> float:
	for i in 40:
		await get_tree().process_frame
	var t0 := Time.get_ticks_usec()
	for i in FRAMES:
		await get_tree().process_frame
	return float(Time.get_ticks_usec() - t0) / 1000.0 / FRAMES


func _run(cam: Camera3D) -> void:
	var mgr := get_tree().root.get_node("WaterManager")
	for i in 120:
		await get_tree().process_frame
	cam.make_current()
	var size := get_viewport().get_visible_rect().size
	print("underwater bench at %dx%d" % [size.x, size.y])
	for q in [WaterManager.Quality.HIGH, WaterManager.Quality.MEDIUM, WaterManager.Quality.LOW, WaterManager.Quality.DECK]:
		mgr.quality = q
		var on: Array[float] = []
		var off: Array[float] = []
		for r in ROUNDS:
			mgr.underwater_enabled = false
			off.append(await _measure())
			mgr.underwater_enabled = true
			on.append(await _measure())
		on.sort()
		off.sort()
		var a := on[ROUNDS / 2]
		var b := off[ROUNDS / 2]
		print("%-7s frame %.3f ms with, %.3f ms without: underwater pass %.3f ms" % [
			WaterManager.Quality.keys()[q], a, b, a - b])
	get_tree().quit()
