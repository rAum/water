# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## The player must be able to pick up, carry and throw a floating log.
func _ready() -> void:
	var demo: Node = load("res://examples/demo/demo.tscn").instantiate()
	add_child(demo)
	_run.call_deferred(demo)

func _run(demo: Node) -> void:
	var p: CharacterBody3D = demo.get_node("Player")
	for n in 60:
		await get_tree().physics_frame
	var lg: RigidBody3D = load("res://examples/shared/log.tscn").instantiate()
	demo.add_child(lg)
	var pivot: Node3D = p.get_node("CameraPivot")
	lg.global_position = pivot.global_position - pivot.global_transform.basis.z * 1.8
	for n in 10:
		await get_tree().physics_frame
	var found: RigidBody3D = p._body_in_reach()
	print("in reach: ", found != null and found == lg, "  (grabbable group size ", get_tree().get_nodes_in_group("flowing_water_grabbable").size(), ")")
	p._held = found
	for n in 90:
		await get_tree().physics_frame
	var target := pivot.global_position - pivot.global_transform.basis.z * 1.5
	print("carried: distance to hold point %.2f m" % target.distance_to(lg.global_position))
	lg.linear_velocity = -pivot.global_transform.basis.z * 7.0 + Vector3.UP * 2.0
	p._held = null
	for n in 45:
		await get_tree().physics_frame
	print("thrown: now %.1f m from the player" % p.global_position.distance_to(lg.global_position))
	get_tree().quit()
