# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends CharacterBody3D
## Example character controller. The water plugin never moves the
## character: this script reads the WaterInteractor child and decides what
## the current and the depth do.
##
## Click to capture the mouse; WASD to walk, Space to jump, Esc to release.
## Walk into floating objects to shove them; E picks up / drops the one you
## are looking at, F throws it.

const SPEED := 4.2
const JUMP := 4.8
const PUSH := 2.2          # shove strength when walking into a body
const REACH := 2.6         # how far away something can be picked up
const HOLD_DISTANCE := 1.5

var _yaw := 0.0
var _pitch := -0.25
@onready var _interactor: WaterInteractor = $WaterInteractor
@onready var _pivot: Node3D = $CameraPivot
var _held: RigidBody3D


func _ready() -> void:
	_yaw = rotation.y
	_interactor.swept_away.connect(func(): print("player: swept away by the current"))
	_interactor.entered_water.connect(func(speed: float): print("player: entered water at %.1f m/s" % speed))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		if _held != null:
			_held = null
		else:
			_held = _body_in_reach()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F and _held != null:
		_held.linear_velocity = -_pivot.global_transform.basis.z * 7.0 + Vector3.UP * 2.0
		_held = null
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.003
		_pitch = clampf(_pitch - event.relative.y * 0.003, -1.2, 0.6)
		rotation.y = _yaw
		_pivot.rotation.x = _pitch


func _physics_process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir -= transform.basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += transform.basis.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= transform.basis.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += transform.basis.x
	dir.y = 0.0
	dir = dir.normalized()

	var speed := SPEED
	var grip := 10.0
	if _interactor.in_water:
		# wading slows you down; the current pushes; deep water floats you
		speed *= lerpf(1.0, 0.35, _interactor.submerged_ratio)
		grip = lerpf(10.0, 2.0, _interactor.submerged_ratio)
		velocity += _interactor.get_push() * delta
		if _interactor.submerged_ratio > 0.7:
			velocity.y += 14.0 * delta * (_interactor.submerged_ratio - 0.7) / 0.3
			velocity.y *= 1.0 - 2.0 * delta
	velocity.x = lerpf(velocity.x, dir.x * speed, grip * delta)
	velocity.z = lerpf(velocity.z, dir.z * speed, grip * delta)
	velocity.y -= 9.8 * delta
	if is_on_floor() and Input.is_physical_key_pressed(KEY_SPACE):
		velocity.y = JUMP
	move_and_slide()
	# shove whatever we walk into: a CharacterBody does not push rigid
	# bodies on its own
	for n in get_slide_collision_count():
		var col := get_slide_collision(n)
		var rb := col.get_collider() as RigidBody3D
		if rb != null and rb != _held:
			var push := -col.get_normal()
			push.y = 0.0
			rb.apply_impulse(push * PUSH * rb.mass * delta * 6.0 * maxf(velocity.length(), 1.0),
				col.get_position() - rb.global_position)
	# carry the held body in front of the camera
	if _held != null:
		if not is_instance_valid(_held):
			_held = null
		else:
			var target := _pivot.global_position - _pivot.global_transform.basis.z * HOLD_DISTANCE
			_held.linear_velocity = (target - _held.global_position) * 14.0
			_held.angular_velocity *= 0.8
			if target.distance_to(_held.global_position) > REACH * 1.6:
				_held = null


## The rigid body the camera is pointing at, within reach.
func _body_in_reach() -> RigidBody3D:
	var from := _pivot.global_position
	var dir := -_pivot.global_transform.basis.z
	var best: RigidBody3D = null
	var best_score := 0.82
	for node in get_tree().get_nodes_in_group("flowing_water_grabbable"):
		var rb := node as RigidBody3D
		if rb == null:
			continue
		var to := rb.global_position - from
		if to.length() > REACH + 1.0:
			continue
		var score := to.normalized().dot(dir)
		if score > best_score:
			best_score = score
			best = rb
	return best
