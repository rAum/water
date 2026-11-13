# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
@icon("../editor/icons/water_floater.svg")
class_name WaterFloater
extends Node3D
## Buoyancy for a RigidBody3D parent. 4-8 sample points (auto-generated from
## the collision shape, or your own Marker3D children) each push up in
## proportion to how deep they sit, so the body tilts with the slope and the
## standing waves; drag toward the water velocity makes it drift downstream,
## speed up in rapids, slow in ponds and turn in eddies.
##
## The height used is the baked surface plus the baked surface offset, so
## objects sit on the visible surface, including on slopes. Over a waterfall
## the push fades out (the baked fall rows barely lift) and the body falls
## freely, splashing on landing.

## Leave empty to auto-generate 4-8 points from the collision shape; or add
## Marker3D children and they are used instead.
@export var buoyancy := 1.0
## How deep the sample points sit at rest, in metres. 0 = automatic (from
## the collision shape's height).
@export var draft := 0.0
## Damping of bobbing and spinning while afloat.
@export var vertical_damping := 5.0
@export var angular_drag := 1.6
## Drag toward the water's velocity: how quickly the body takes on the
## speed of the current.
@export var flow_drag := 2.4
## When the body runs aground or jams against a rock while the water around
## it is moving, nudge it toward deeper water (like a real log working free).
@export var unstick := true
@export var inject_ripples := true

var in_water := false

var _body: RigidBody3D
var _points: Array[Vector3] = []
var _was_in_water := false
var _entry_speed := 0.0
var _sleep_check := 0.0
var _low_rate_accum := 0.0
var _auto_draft := 0.06
var _stuck_time := 0.0
var _last_wet_time := -100000

signal entered_water(speed: float)
signal exited_water()


func _get_configuration_warnings() -> PackedStringArray:
	if not (get_parent() is RigidBody3D):
		return PackedStringArray(["WaterFloater must be the child of a RigidBody3D."])
	return PackedStringArray()


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_body = get_parent() as RigidBody3D
	if _body == null:
		push_warning("WaterFloater: parent is not a RigidBody3D; disabled.")
		set_physics_process(false)
		return
	_collect_points()
	_body.can_sleep = true
	# lets game code find things the player can pick up or shove
	_body.add_to_group("flowing_water_grabbable")
	add_to_group(WaterRiver.FALL_BLOCKER_GROUP)


## The body as waterfalls see it: a short column at each sample point
## (WaterRiver parts a falling sheet around it - hold a log in a fall).
func fall_blocker_shapes() -> Array:
	var out := []
	if _body == null:
		return out
	var xf := _body.global_transform
	for p in _points:
		var w := xf * p
		out.append([w - Vector3.UP * 0.12, w.y + 0.3, 0.2])
	return out


func _collect_points() -> void:
	_points.clear()
	for child in get_children():
		if child is Marker3D:
			_points.append((child as Marker3D).position)
	if not _points.is_empty():
		return
	# auto-generate from the collision shape's AABB
	var aabb := AABB(Vector3(-0.25, -0.1, -0.25), Vector3(0.5, 0.2, 0.5))
	for child in _body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			var shape := (child as CollisionShape3D).shape
			var dbg := shape.get_debug_mesh()
			if dbg != null:
				aabb = dbg.get_aabb()
			break
	var ext := aabb.size * 0.5
	var c := aabb.get_center()
	_auto_draft = clampf(minf(ext.y, minf(ext.x, ext.z)) * 0.55, 0.03, 0.6)
	var y := c.y - ext.y * 0.4
	var long_x := ext.x > ext.z * 1.6
	var long_z := ext.z > ext.x * 1.6
	if long_x or long_z:
		# elongated bodies (logs): 6 points in a line plus 2 outriggers
		var axis := Vector3.RIGHT if long_x else Vector3.BACK
		var side := Vector3.BACK if long_x else Vector3.RIGHT
		var half := (ext.x if long_x else ext.z) * 0.85
		var w := (ext.z if long_x else ext.x) * 0.7
		for t in [-1.0, -0.33, 0.33, 1.0]:
			_points.append(c + axis * half * t + Vector3.UP * (y - c.y))
		_points.append(c + side * w + Vector3.UP * (y - c.y))
		_points.append(c - side * w + Vector3.UP * (y - c.y))
	else:
		for sx in [-0.7, 0.7]:
			for sz in [-0.7, 0.7]:
				_points.append(Vector3(c.x + ext.x * sx, y, c.z + ext.z * sz))


func _physics_process(delta: float) -> void:
	if _body == null:
		return
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	if mgr == null:
		return
	# Far from the camera the forces are recomputed at a lower rate. They are
	# held as the body's constant force/torque in between, so buoyancy keeps
	# acting every physics step no matter how often it is refreshed.
	var far := false
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.global_position.distance_to(global_position) > 60.0:
		far = true
		_low_rate_accum += delta
		if _low_rate_accum < 0.05:
			return
		delta = _low_rate_accum
		_low_rate_accum = 0.0

	var q = mgr.query(_body.global_position)
	var any_submerged := false
	var mass: float = _body.mass
	var g: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var n_points := float(maxi(_points.size(), 1))
	var rest_draft := draft if draft > 0.0 else _auto_draft
	if far:
		# a softer spring stays stable at the lower refresh rate
		rest_draft *= 1.4
	var net_force := Vector3.ZERO
	var net_torque := Vector3.ZERO
	var mean_flow := Vector3.ZERO
	var wet := 0
	for local in _points:
		var world: Vector3 = _body.global_transform * local
		mgr.query(world, q)
		if not q.valid:
			continue
		var sub: float = q.height - world.y
		if sub <= 0.0:
			continue
		any_submerged = true
		wet += 1
		mean_flow += q.flow
		# buoyancy: weight is carried when every point sits `rest_draft` deep
		var up := Vector3.UP * (mass * g / n_points) * buoyancy * clampf(sub / rest_draft, 0.0, 2.5)
		# drag toward the water velocity at the point (not toward rest), plus
		# damping of the bobbing
		var arm: Vector3 = world - _body.global_position
		var point_vel: Vector3 = _body.linear_velocity + _body.angular_velocity.cross(arm)
		var rel: Vector3 = q.flow - point_vel
		var immersion := clampf(sub / rest_draft, 0.2, 1.0)
		# Water drag grows with the square of the relative speed: a body
		# barely slower than the current is carried along, and one that
		# is shoved coasts instead of stopping dead (a purely linear drag
		# made a floating log harder to push than one lying on the bank).
		var rel_h := Vector3(rel.x, 0.0, rel.z)
		var k_drag := flow_drag * clampf(0.25 + 0.75 * rel_h.length(), 0.25, 1.8)
		var drag := rel_h * k_drag * mass / n_points * immersion
		drag.y = -point_vel.y * vertical_damping * mass / n_points * immersion
		var force := up + drag
		# clamp per point so nothing explodes
		var fmax := mass * g * 4.0 / n_points
		if force.length() > fmax:
			force = force.normalized() * fmax
		net_force += force
		net_torque += arm.cross(force)
	if any_submerged:
		_body.linear_damp = 0.05
		_body.angular_damp = angular_drag
		# a floating body must not fall asleep: the current keeps acting on it
		_body.can_sleep = false
		_body.sleeping = false
		mean_flow /= float(wet)
		var nudge := _work_free(mgr, q, mean_flow, mass, delta)
		net_force += nudge[0]
		net_torque += nudge[1]
	else:
		_body.linear_damp = 0.0
		_body.angular_damp = 0.0
		# beached on a rock or a bar with moving water right underneath:
		# keep it awake and let it work free
		mgr.query(_body.global_position, q)
		var beached: bool = q.valid and _body.global_position.y - q.height < 0.45 \
			and q.flow.length() > 0.25
		# stranded right beside the water (on a rock or the edge of a bar
		# where there is no water under it at all): slide back toward it
		var to_water := Vector3.ZERO
		if not q.valid and _was_in_water_recently():
			to_water = _nearest_water(mgr, q)
		_body.can_sleep = not beached and to_water == Vector3.ZERO
		if beached:
			_body.sleeping = false
			var nudge := _work_free(mgr, q, q.flow, mass, delta)
			net_force += nudge[0]
			net_torque += nudge[1]
		elif to_water != Vector3.ZERO:
			_body.sleeping = false
			_stuck_time += delta
			net_force += (to_water + Vector3.UP * 0.5) * mass * 3.0 * minf(_stuck_time, 3.0)
		else:
			_stuck_time = 0.0
	_body.constant_force = net_force
	_body.constant_torque = net_torque

	in_water = any_submerged
	if any_submerged:
		_last_wet_time = Time.get_ticks_msec()
	if any_submerged and not _was_in_water:
		var speed: float = _body.linear_velocity.length()
		entered_water.emit(speed)
		if inject_ripples:
			mgr.add_ripple(_body.global_position, clampf(0.015 + speed * 0.015, 0.015, 0.1), 0.5)
	elif not any_submerged and _was_in_water:
		exited_water.emit()
	_was_in_water = any_submerged

	# moving floaters leave ripples
	if inject_ripples and any_submerged and _body.linear_velocity.length() > 0.4:
		_sleep_check += delta
		if _sleep_check > 0.12:
			_sleep_check = 0.0
			mgr.add_ripple(_body.global_position, 0.012, 0.35)


func _was_in_water_recently() -> bool:
	return Time.get_ticks_msec() - _last_wet_time < 20000


## Horizontal direction to the closest water within about a metre, or zero.
func _nearest_water(mgr: Node, q) -> Vector3:
	var pos := _body.global_position
	for r in [0.5, 1.0]:
		var best := Vector3.ZERO
		var best_depth := 0.08
		for n in 8:
			var a := TAU * float(n) / 8.0
			var dir := Vector3(cos(a), 0.0, sin(a))
			mgr.query(pos + dir * r, q)
			if q.valid and q.depth > best_depth:
				best_depth = q.depth
				best = dir
		if best != Vector3.ZERO:
			return best
	return Vector3.ZERO


## Ran aground or jammed against a rock while the water is moving: slide
## toward deeper water and turn, the way the prototype's logs slid back
## toward the middle of the channel. Returns [force, torque].
func _work_free(mgr: Node, q, flow: Vector3, mass: float, delta: float) -> Array:
	if not unstick:
		return [Vector3.ZERO, Vector3.ZERO]
	var flow_speed := flow.length()
	var planar := Vector3(_body.linear_velocity.x, 0.0, _body.linear_velocity.z).length()
	# stuck = clearly slower than the water around it
	if flow_speed < 0.25 or planar > maxf(flow_speed * 0.35, 0.22):
		_stuck_time = maxf(_stuck_time - delta, 0.0)
		return [Vector3.ZERO, Vector3.ZERO]
	_stuck_time += delta
	if _stuck_time < 0.6:
		return [Vector3.ZERO, Vector3.ZERO]
	var dir := flow / flow_speed
	var side := Vector3(dir.z, 0.0, -dir.x)
	var pos := _body.global_position
	mgr.query(pos + side * 0.7, q)
	var depth_r: float = q.depth if q.valid else 0.0
	mgr.query(pos - side * 0.7, q)
	var depth_l: float = q.depth if q.valid else 0.0
	# toward deeper water when one side clearly is; otherwise try one side,
	# then the other, the way a snagged log rocks itself loose
	var toward := side if depth_r >= depth_l else -side
	if absf(depth_r - depth_l) < 0.08 and int(_stuck_time / 1.5) % 2 == 1:
		toward = -toward
	# the longer it has been stuck, the harder the water works on it
	var strength := minf(_stuck_time, 5.0)
	return [
		(toward * 1.0 + dir * 1.3 + Vector3.UP * 0.7) * mass * 2.6 * strength,
		Vector3.UP * mass * 0.7 * strength * (1.0 if toward == side else -1.0),
	]
