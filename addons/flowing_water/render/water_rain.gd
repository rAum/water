# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

class_name WaterRain
extends GPUParticles3D
## Falling rain around the camera: one emitter of thin streaks in a box that
## follows the camera, made and freed by WaterManager with its
## `rain_intensity`. The drops live in world space (they keep falling where
## they are while the camera walks on), the box only decides where new ones
## start. Streaks are a few millimetres wide: dozens of them on screen cost
## less than one big mist puff.

## Half the width of the box the drops start in (m). Further away a streak
## is thinner than a pixel and the fog takes it anyway.
const RADIUS := 13.0
## How high above the camera they start, and how fast they fall (m/s): the
## terminal speed of a large raindrop.
const TOP := 9.0
const SPEED := 8.5
const LIFETIME := 2.1

var _mat: ShaderMaterial
var _pm: ParticleProcessMaterial
var _wind := Vector3.INF


func _init() -> void:
	local_coords = false
	draw_order = DRAW_ORDER_INDEX
	transform_align = TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	lifetime = LIFETIME
	preprocess = LIFETIME
	fixed_fps = 0
	interpolate = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	visibility_aabb = AABB(Vector3(-RADIUS - 4.0, -TOP - 14.0, -RADIUS - 4.0),
		Vector3(RADIUS * 2.0 + 8.0, TOP * 2.0 + 16.0, RADIUS * 2.0 + 8.0))
	_pm = ParticleProcessMaterial.new()
	_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_pm.emission_box_extents = Vector3(RADIUS, 0.5, RADIUS)
	_pm.direction = Vector3.DOWN
	_pm.spread = 1.5
	_pm.initial_velocity_min = SPEED * 0.9
	_pm.initial_velocity_max = SPEED * 1.1
	_pm.gravity = Vector3.ZERO
	# drops of different sizes: the streak's length and width scale together
	_pm.scale_min = 0.6
	_pm.scale_max = 1.25
	process_material = _pm
	var quad := QuadMesh.new()
	# a drop's blur in one frame of a film camera: long and very thin
	quad.size = Vector2(0.007, 0.5)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://addons/flowing_water/render/water_rain.gdshader")
	_mat.set_shader_parameter("fade_far", RADIUS)
	quad.material = _mat
	draw_pass_1 = quad


func set_color(c: Color) -> void:
	_mat.set_shader_parameter("rain_color", c)


## max_drops: the quality preset's drop count at full intensity.
func configure(max_drops: int, intensity: float) -> void:
	if amount != max_drops:
		amount = max_drops   # (restarts the emitter: only on a quality change)
	amount_ratio = clampf(intensity, 0.0, 1.0)
	# a shower is fine drops, a downpour heavy ones that fall faster
	_pm.initial_velocity_min = SPEED * lerpf(0.75, 0.95, intensity)
	_pm.initial_velocity_max = SPEED * lerpf(0.9, 1.12, intensity)
	_mat.set_shader_parameter("intensity", intensity)
	emitting = intensity > 0.001


## Keeps the box over the camera and lets the wind slant the rain. Hidden
## while the camera is under water.
func follow(cam: Camera3D, under_water: bool, wind: Vector3) -> void:
	visible = cam != null and not under_water
	if cam == null:
		return
	global_position = cam.global_position + Vector3(0.0, TOP, 0.0)
	# the box leads the camera a little in the direction it looks: most of
	# what is seen lies ahead
	var fwd := -cam.global_basis.z
	global_position += Vector3(fwd.x, 0.0, fwd.z) * 4.0
	if not wind.is_equal_approx(_wind):
		_wind = wind
		# drops drift with the air: a 5 m/s wind slants them by about 30 degrees
		var d := Vector3(wind.x, 0.0, wind.z) / SPEED + Vector3.DOWN
		_pm.direction = d.normalized()
