# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
@icon("../editor/icons/water_interactor.svg")
class_name WaterInteractor
extends Node3D
## Ripples, splashes and current push for characters and objects. Add as a
## child of your character (or anything that moves through water).
##
## The plugin never moves your character. It reports; your controller
## decides:
##
##     var in_water: bool
##     var depth_at_feet: float
##     var submerged_ratio: float          # 0-1 of character height
##     func get_push() -> Vector3          # force from the current
##     signal entered_water(speed), exited_water(), swept_away()

## Character height used for submerged_ratio.
@export var height := 1.8
## Radius used for ripple injection.
@export var radius := 0.35
## get_push() scale: push is proportional to depth x speed^2.
@export var push_scale := 1.0
## When the push force magnitude exceeds this, swept_away is emitted.
@export var sweep_threshold := 6.0

var in_water := false
var depth_at_feet := 0.0
var submerged_ratio := 0.0

signal entered_water(speed: float)
signal exited_water()
signal swept_away()

var _was_in_water := false
var _last_pos := Vector3.ZERO
var _ripple_accum := 0.0
var _push := Vector3.ZERO
var _swept := false
var _low_rate_accum := 0.0


func get_push() -> Vector3:
	return _push


func _ready() -> void:
	_last_pos = global_position


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	if mgr == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.global_position.distance_to(global_position) > 60.0:
		_low_rate_accum += delta
		if _low_rate_accum < 0.1:
			return
		delta = _low_rate_accum
		_low_rate_accum = 0.0

	var feet := global_position
	var q = mgr.query(feet)
	var vel := (feet - _last_pos) / maxf(delta, 0.001)
	_last_pos = feet

	if not q.valid or q.height <= feet.y:
		_set_in_water(false, 0.0)
		depth_at_feet = 0.0
		submerged_ratio = 0.0
		_push = Vector3.ZERO
		_swept = false
		return

	depth_at_feet = q.depth
	submerged_ratio = clampf((q.height - feet.y) / maxf(height, 0.01), 0.0, 1.0)
	# push from the current: proportional to immersion depth x speed^2
	var speed: float = q.flow.length()
	var immersion: float = minf(q.height - feet.y, q.depth)
	_push = q.flow * speed * immersion * push_scale
	_set_in_water(true, vel.length())

	if _push.length() > sweep_threshold and not _swept:
		_swept = true
		swept_away.emit()
	elif _push.length() < sweep_threshold * 0.6:
		_swept = false

	# ripples along the movement
	var planar := Vector3(vel.x, 0.0, vel.z)
	if planar.length() > 0.4:
		_ripple_accum += delta * planar.length()
		if _ripple_accum > 0.35:
			_ripple_accum = 0.0
			mgr.add_ripple(feet, 0.015 + minf(planar.length() * 0.008, 0.025), radius)
	else:
		# standing still in a current still disturbs the surface a little
		if speed > 0.8:
			_ripple_accum += delta
			if _ripple_accum > 0.25:
				_ripple_accum = 0.0
				mgr.add_ripple(feet, 0.012, radius * 0.8)


func _set_in_water(now: bool, speed: float) -> void:
	in_water = now
	if now and not _was_in_water:
		entered_water.emit(speed)
		var mgr := get_tree().root.get_node_or_null("WaterManager")
		if mgr != null and speed > 1.0:
			# entry ring and splash
			mgr.add_ripple(global_position, clampf(speed * 0.02, 0.02, 0.1), radius * 2.0)
	elif not now and _was_in_water:
		exited_water.emit()
	_was_in_water = now
