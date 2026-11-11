# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Follows the demo's first log for 100 s: it should ride the rapids, go over
## the fall, cross the pond and leave through the outlet without hovering,
## sinking or being launched.
func _ready() -> void:
	var demo: Node = load("res://examples/demo/demo.tscn").instantiate()
	add_child(demo)
	var player := demo.get_node_or_null("Player")
	if player != null:
		player.process_mode = Node.PROCESS_MODE_DISABLED
	_run.call_deferred(demo)

func _run(demo: Node) -> void:
	var mgr := get_tree().root.get_node("WaterManager")
	var lg: RigidBody3D = demo.get_node("Log1")
	var max_above := 0.0
	var max_below := 0.0
	var max_speed := 0.0
	for step in 60:
		for n in 120:
			await get_tree().physics_frame
			var q = mgr.query(lg.global_position)
			if q.valid:
				max_above = maxf(max_above, lg.global_position.y - q.height)
				max_below = maxf(max_below, q.height - lg.global_position.y)
			max_speed = maxf(max_speed, lg.linear_velocity.length())
		var q2 = mgr.query(lg.global_position)
		print("t=%3ds pos=(%.1f, %.2f, %.1f) water=%s body=%s v=%.2f" % [
			(step + 1) * 2, lg.global_position.x, lg.global_position.y, lg.global_position.z,
			("%.2f" % q2.height) if q2.valid else "none",
			q2.body.name if q2.body != null else "-", lg.linear_velocity.length()])
	print("max above surface %.2f m, max below %.2f m, max speed %.1f m/s" % [max_above, max_below, max_speed])
	get_tree().quit()
