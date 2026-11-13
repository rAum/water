# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends CharacterBody3D
## Example character controller. The water plugin never moves the
## character: this script reads the WaterInteractor child and decides what
## the current and the depth do.
##
## Click to capture the mouse; WASD to walk, Shift to run, Space to jump,
## Esc to release.
## Walk into floating objects to shove them; E picks up / drops the one you
## are looking at, F throws it.

const SPEED := 6.0
const RUN := 1.8           # Shift: run this many times faster
const JUMP := 6.0          # about 1.8 m high
## A jump still counts this long after leaving the ground, and a press this
## long before landing is kept: on rocks, slopes and in the shallows the
## body is often off the floor for a frame or two, and Space did nothing.
const COYOTE := 0.15
const JUMP_BUFFER := 0.15
const BODY_MASS := 75.0   # how heavy the character is when it shoves things
const REACH := 2.6         # how far away something can be picked up
const HOLD_DISTANCE := 1.5

var _yaw := 0.0
var _pitch := -0.25
@onready var _interactor: WaterInteractor = $WaterInteractor
@onready var _pivot: Node3D = $CameraPivot
@onready var _cam: Camera3D = $CameraPivot/Camera
var _cam_rest := Vector3.ZERO
var _cam_dist := -1.0
## The camera keeps this far from terrain and rocks.
const CAM_RADIUS := 0.25
var _held: RigidBody3D
var _since_floor := 1.0
var _jump_pressed := 1.0


func _ready() -> void:
	_yaw = rotation.y
	_cam_rest = _cam.position
	# Floating things are not platforms to ride: a spinning log would hand
	# its velocity to the character and fling it across the water. Only
	# the world (layer 1) carries the character along.
	platform_floor_layers = 1
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
	_interactor.swept_away.connect(func(): print("player: swept away by the current"))
	_interactor.entered_water.connect(func(speed: float): print("player: entered water at %.1f m/s" % speed))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		_jump_pressed = 0.0
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


## Third-person boom with collision: the camera sits at its rest offset
## unless the world (layer 1: terrain, rocks) is in the way, then in front
## of it. Without this, looking up swung the camera down through the
## ground; buried in the terrain it saw the water from beneath, with no
## water around the lens to switch the underwater view on.
func _update_camera_boom(delta: float) -> void:
	var from := _pivot.global_position
	var to := _pivot.global_transform * _cam_rest
	var sphere := SphereShape3D.new()
	sphere.radius = CAM_RADIUS
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), from)
	q.motion = to - from
	q.collision_mask = 1
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.cast_motion(q)
	var want := _cam_rest.length() * (hit[0] if hit.size() > 0 else 1.0)
	# pull in at once, ease back out (no popping when a rock passes)
	_cam_dist = want if (_cam_dist < 0.0 or want < _cam_dist) else lerpf(_cam_dist, want, 1.0 - exp(-delta * 4.0))
	_cam.position = _cam_rest.normalized() * _cam_dist


func _physics_process(delta: float) -> void:
	_update_camera_boom(delta)
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

	var speed := SPEED * (RUN if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	var grip := 10.0
	if _interactor.in_water:
		# wading slows you down; the current pushes; deep water floats you
		speed *= lerpf(1.0, 0.35, _interactor.submerged_ratio)
		grip = lerpf(10.0, 3.0, _interactor.submerged_ratio)
		velocity += _interactor.get_push() * delta
		if _interactor.submerged_ratio > 0.7:
			velocity.y += 14.0 * delta * (_interactor.submerged_ratio - 0.7) / 0.3
			velocity.y *= 1.0 - 2.0 * delta
	velocity.x = lerpf(velocity.x, dir.x * speed, grip * delta)
	velocity.z = lerpf(velocity.z, dir.z * speed, grip * delta)
	velocity.y -= 9.8 * delta
	_since_floor = 0.0 if is_on_floor() else _since_floor + delta
	_jump_pressed += delta
	# wading counts as standing: push off the bed (but not while swimming)
	var footing := _since_floor < COYOTE \
		or (_interactor.in_water and _interactor.submerged_ratio < 0.7)
	if footing and _jump_pressed < JUMP_BUFFER and velocity.y < JUMP * 0.5:
		velocity.y = JUMP
		_jump_pressed = 1.0
		_since_floor = 1.0
	move_and_slide()
	# Shove whatever we walk into: a CharacterBody does not push rigid
	# bodies on its own. The body is brought up to the speed we are trying
	# to walk at (not the speed we are left with: the collision has just
	# stopped us), shared by mass. Something afloat only has the water to
	# push aside; on the ground it also drags, so it moves less.
	var want := dir * speed
	for n in get_slide_collision_count():
		var col := get_slide_collision(n)
		var rb := col.get_collider() as RigidBody3D
		if rb == null or rb == _held:
			continue
		var push := -col.get_normal()
		push.y = 0.0
		if push.length() < 0.5:
			continue    # standing on it, not walking into it
		push = push.normalized()
		var into := want.dot(push)
		var deficit := into * 1.1 - rb.linear_velocity.dot(push)
		if into <= 0.0 or deficit <= 0.0:
			continue
		var share := BODY_MASS / (BODY_MASS + rb.mass)
		var floater := rb.get_node_or_null("WaterFloater")
		if floater == null or not floater.in_water:
			share *= 0.3
		rb.apply_impulse(push * deficit * rb.mass * share, col.get_position() - rb.global_position)
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
