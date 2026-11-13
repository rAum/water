# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Walking into a floating log must shove it well clear, and it must keep
## drifting once the push ends.
## Run: godot --path . res://tools/push_check.tscn [-- verbose]

var _demo: Node


func _ready() -> void:
	_demo = load("res://examples/demo/demo.tscn").instantiate()
	add_child(_demo)
	_run.call_deferred()


func _key(down: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_W
	ev.keycode = KEY_W
	ev.pressed = down
	Input.parse_input_event(ev)


func _trial(label: String, start: Vector3, yaw: float) -> Vector2:
	var p := _demo.get_node("Player") as CharacterBody3D
	var lg: RigidBody3D = load("res://examples/shared/log.tscn").instantiate()
	_demo.add_child(lg)
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var space := p.get_world_3d().direct_space_state
	var log_xz := start + fwd * 1.6
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(log_xz + Vector3.UP * 5.0, log_xz + Vector3.DOWN * 5.0, 1))
	var mgr := get_tree().root.get_node("WaterManager")
	var q = mgr.query(log_xz)
	var ground: float = hit["position"].y if not hit.is_empty() else start.y
	var y := maxf(ground + 0.12, q.height if q.valid else -99.0)
	# across the walking direction, so the capsule meets its side
	lg.global_transform = Transform3D(Basis(Vector3.UP, yaw + PI * 0.5), Vector3(log_xz.x, y, log_xz.z))
	var ground_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(start + Vector3.UP * 5.0, start + Vector3.DOWN * 5.0, 1))
	p.global_position = (ground_hit["position"] as Vector3) + Vector3.UP * 0.05 if not ground_hit.is_empty() else start
	p.velocity = Vector3.ZERO
	p.rotation.y = yaw
	p.set("_yaw", yaw)
	for n in 90:
		await get_tree().physics_frame
	var before := lg.global_position
	_key(true)
	var verbose := OS.get_cmdline_user_args().has("verbose")
	if verbose:
		print("  start %s, log %s" % [p.global_position.snapped(Vector3.ONE * 0.01), lg.global_position.snapped(Vector3.ONE * 0.01)])
	for n in 120:
		await get_tree().physics_frame
		if verbose and n % 5 == 0:
			var hits := []
			for c in p.get_slide_collision_count():
				hits.append((p.get_slide_collision(c).get_collider() as Node).name)
			print("  f%02d player v=%s log v=%s gap=%.2f %s" % [n, p.velocity.snapped(Vector3.ONE * 0.01),
				lg.linear_velocity.snapped(Vector3.ONE * 0.01), p.global_position.distance_to(lg.global_position), hits])
	_key(false)
	var at_release := lg.global_position
	for n in 60:
		await get_tree().physics_frame
	var moved := Vector2(lg.global_position.x - before.x, lg.global_position.z - before.z).length()
	var coast := Vector2(lg.global_position.x - at_release.x, lg.global_position.z - at_release.z).length()
	print("%s: log moved %.2f m, %.2f m of it coasting after the push (afloat=%s)" % [
		label, moved, coast, (lg.get_node("WaterFloater") as WaterFloater).in_water])
	lg.queue_free()
	return Vector2(moved, coast)


## A start with a clear run ahead along `yaw`: waist-deep water the whole
## way (afloat = true) or flat dry ground (afloat = false). No rocks.
func _find_start(yaw: float, afloat: bool) -> Vector3:
	var mgr := get_tree().root.get_node("WaterManager")
	var space := (_demo as Node3D).get_world_3d().direct_space_state
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var c0 := Vector3(2.0, 0.0, 0.0) if afloat else Vector3(12.0, 0.0, 0.0)
	var best := Vector3.INF
	var best_d := INF
	for x in range(-24, 25):
		for z in range(-24, 25):
			var start := c0 + Vector3(x * 0.5, 0.0, z * 0.5)
			var ok := true
			for t in ([0.0, 0.8, 1.6, 2.4, 3.2, 4.0] if afloat else [-2.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]):
				var at: Vector3 = start + fwd * t
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 8.0, at + Vector3.DOWN * 8.0, 1))
				if hit.is_empty() or not (hit["collider"] as Node).name.begins_with("Terrain"):
					ok = false
					break
				var q = mgr.query(at)
				if afloat:
					ok = q.valid and q.depth > 0.3 and q.depth < 1.3
				else:
					ok = (not q.valid or q.depth <= 0.0) and (hit["normal"] as Vector3).y > 0.94 \
						and mgr.query(at + Vector3(fwd.z, 0.0, -fwd.x) * 2.0).depth <= 0.0 \
						and mgr.query(at - Vector3(fwd.z, 0.0, -fwd.x) * 2.0).depth <= 0.0
				if not ok:
					break
			var d := start.distance_to(c0)
			if ok and d < best_d:
				best = start
				best_d = d
	if best == Vector3.INF:
		push_warning("push_check: no clear run found (afloat=%s)" % afloat)
		return c0
	return best


func _run() -> void:
	for i in 60:
		await get_tree().physics_frame
	var wet := await _trial("pond", _find_start(PI * 0.5, true), PI * 0.5)
	var dry := await _trial("land", _find_start(PI * 0.5, false), PI * 0.5)
	# A floating log is shoved well clear and keeps drifting once let go
	# (before the fix it moved 0.45 m and stopped dead). The land trial is
	# for reference: there the character can kick it along at walking pace.
	var ok := wet.x > 1.2 and wet.y > 0.2
	print("PUSH %s: in water %.2f m (coast %.2f); on land %.2f m (coast %.2f)" % [
		"OK" if ok else "FAIL", wet.x, wet.y, dry.x, dry.y])
	get_tree().quit()
