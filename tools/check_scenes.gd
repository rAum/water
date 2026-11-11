# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Loads and runs every example scene for a moment; any script or resource
## error shows up in the log. Run: godot --path . res://tools/check_scenes.tscn
const SCENES := [
	"res://examples/01_stream.tscn",
	"res://examples/02_pond.tscn",
	"res://examples/03_waterfall.tscn",
	"res://examples/04_river_pond_river.tscn",
	"res://examples/05_styles.tscn",
	"res://examples/06_gameplay.tscn",
	"res://examples/07_lowland_river.tscn",
	"res://examples/demo/demo.tscn",
]

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var mgr := get_tree().root.get_node("WaterManager")
	for path: String in SCENES:
		var scene: Node = load(path).instantiate()
		add_child(scene)
		for n in 90:
			await get_tree().physics_frame
		# every body must be baked, fresh, and answer queries
		var bodies: Array = []
		_collect(scene, bodies)
		var ok := true
		for b in bodies:
			if b is WaterRiver:
				ok = ok and not b.baked_segments.is_empty() and b.baked_segments[0].is_valid()
				ok = ok and b._collider_hash() == b.baked_segments[0].scene_hash
				var mid: Vector3 = b.global_transform * b.curve.sample_baked(b.curve.get_baked_length() * 0.5, true)
				var q = mgr.query(mid)
				ok = ok and q.valid and q.flow.length() > 0.05
			elif b is WaterPond:
				ok = ok and b.baked_data != null and b.baked_data.is_valid()
				ok = ok and b._collider_hash() == b.baked_data.scene_hash
				ok = ok and not is_nan(mgr.get_height(b.global_position))
		# logs must be floating, not sunk or launched
		var logs_ok := true
		for c in scene.get_children():
			if c is RigidBody3D:
				var h: float = mgr.get_height(c.global_position)
				if is_nan(h) or absf(c.global_position.y - h) > 0.6:
					logs_ok = false
					print("   log %s y=%.2f water=%.2f" % [c.name, c.global_position.y, h])
		print("%s: %d bodies, baked+fresh+query %s, logs %s" % [path.get_file(), bodies.size(), "OK" if ok else "FAIL", "OK" if logs_ok else "CHECK"])
		scene.queue_free()
		for n in 5:
			await get_tree().process_frame
	get_tree().quit()

func _collect(n: Node, out: Array) -> void:
	if n is WaterRiver or n is WaterPond:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)
