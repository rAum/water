# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## The player must stand on the terrain, walk into the stream and get pushed.
func _ready() -> void:
	var demo: Node = load("res://examples/demo/demo.tscn").instantiate()
	add_child(demo)
	_run.call_deferred(demo)

func _run(demo: Node) -> void:
	var p: CharacterBody3D = demo.get_node("Player")
	var inter: WaterInteractor = p.get_node("WaterInteractor")
	for n in 120:
		await get_tree().physics_frame
	print("after 2 s: player y=%.2f on_floor=%s in_water=%s" % [p.global_position.y, p.is_on_floor(), inter.in_water])
	# walk it into the stream: teleport above the channel and let it settle
	var river: WaterRiver = demo.get_node("Stream")
	var f := river.frame_at(18.0)
	p.global_position = river.global_transform * (f["pos"] as Vector3) + Vector3.UP * 0.5
	p.velocity = Vector3.ZERO
	var x0 := p.global_position
	for n in 180:
		await get_tree().physics_frame
	print("in rapids 3 s: in_water=%s depth_at_feet=%.2f submerged=%.2f push=%.1f N-ish, drifted %.2f m, y=%.2f" % [
		inter.in_water, inter.depth_at_feet, inter.submerged_ratio, inter.get_push().length(),
		Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length(), p.global_position.y])
	get_tree().quit()
