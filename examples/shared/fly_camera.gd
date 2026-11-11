# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Camera3D
## Free camera for the example scenes.
## Hold the right mouse button to look; WASD to move, Q/E down/up,
## Shift to go faster. Left-click a floating object to give it a shove.

@export var speed := 6.0
var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# shove the rigid body under the cursor
		var from := project_ray_origin(event.position)
		var dir := project_ray_normal(event.position)
		var hit := get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(from, from + dir * 60.0, 2))
		if not hit.is_empty() and hit["collider"] is RigidBody3D:
			var rb := hit["collider"] as RigidBody3D
			rb.apply_impulse((dir + Vector3.UP * 0.25) * rb.mass * 3.5, hit["position"] - rb.global_position)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.003
		_pitch = clampf(_pitch - event.relative.y * 0.003, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += basis.x
	if Input.is_physical_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q):
		dir += Vector3.DOWN
	var s := speed * (3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	if dir != Vector3.ZERO:
		global_position += dir.normalized() * s * delta
