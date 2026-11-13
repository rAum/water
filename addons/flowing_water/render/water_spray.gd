# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
class_name WaterSprayFactory
extends Node3D
## Builds and manages the GPUParticles3D emitters for spray (droplets at
## rocks) and mist (below falls) from baked emission points. Emits only when
## the camera is near, and scales particle counts with the quality preset.

const NEAR_DISTANCE := 45.0
const SPRAY_BASE_COUNT := 500
const MIST_BASE_COUNT := 420
const IMPACT_BASE_COUNT := 420
const TABLE_SIZE := 256

var _spray: GPUParticles3D
var _mist: GPUParticles3D
var _fall: GPUParticles3D
var _impact: GPUParticles3D
var _check_accum := 0.0


## foot_pts / foot_dirs: where falls hit their pools (as drawn by the
## river mesh), with the downstream direction and landing speed (in y).
static func build_for(owner_node: Node3D, segments: Array[WaterData],
		foot_pts := PackedVector3Array(), foot_dirs := PackedVector3Array()) -> WaterSprayFactory:
	var spray_pts := PackedVector3Array()
	var spray_w := PackedFloat32Array()
	var spray_v := PackedVector3Array()
	var mist_pts := PackedVector3Array()
	var fall_pts := PackedVector3Array()
	var fall_vel := PackedVector3Array()
	for data in segments:
		if data == null:
			continue
		fall_pts.append_array(data.fall_points)
		fall_vel.append_array(data.fall_velocities)
		spray_pts.append_array(data.spray_points)
		spray_w.append_array(data.spray_weights)
		spray_v.append_array(data.spray_velocities)
		mist_pts.append_array(data.mist_points)
	if spray_pts.is_empty() and mist_pts.is_empty() and fall_pts.is_empty() and foot_pts.is_empty():
		return null
	var node := WaterSprayFactory.new()
	node.name = "Spray"
	if not spray_pts.is_empty():
		node._spray = node._make_emitter(
			_importance_table(spray_pts, spray_w, spray_v), 0.0,
			clampi(spray_pts.size(), 12, SPRAY_BASE_COUNT), 0.6, 0.4)
	if not fall_pts.is_empty():
		var fw := PackedFloat32Array()
		fw.resize(fall_pts.size())
		fw.fill(1.0)
		node._fall = node._make_emitter(
			_importance_table(fall_pts, fw, fall_vel), 2.0,
			clampi(fall_pts.size() * 8, 80, 2400), 0.8, 0.4)
	if not foot_pts.is_empty():
		# the impact: puffs of white spray thrown up where the sheet hits
		var fw := PackedFloat32Array()
		fw.resize(foot_pts.size())
		fw.fill(1.0)
		node._impact = node._make_emitter(
			_importance_table(foot_pts, fw, foot_dirs), 3.0,
			clampi(foot_pts.size() * 10, 60, IMPACT_BASE_COUNT), 1.5, 0.5)
		# and the mist rises mostly from there, not from the whole pool
		for n in foot_pts.size():
			for rep_n in 3:
				mist_pts.append(foot_pts[n])
	if not mist_pts.is_empty():
		var w := PackedFloat32Array()
		w.resize(mist_pts.size())
		w.fill(1.0)
		var v := PackedVector3Array()
		v.resize(mist_pts.size())
		node._mist = node._make_emitter(
			_importance_table(mist_pts, w, v), 1.0,
			clampi(mist_pts.size() * 3, 12, MIST_BASE_COUNT), 3.6, 0.5)
	return node


## Expands weighted points into a fixed table so the shader can sample
## uniformly (the prototype's cumulative-sum search, done once on the CPU).
static func _importance_table(pts: PackedVector3Array, w: PackedFloat32Array,
		vel: PackedVector3Array) -> ImageTexture:
	var total := 0.0
	var cum := PackedFloat32Array()
	for n in pts.size():
		total += maxf(w[n], 0.001)
		cum.append(total)
	var data := PackedFloat32Array()
	data.resize(TABLE_SIZE * 2 * 4)
	for t in TABLE_SIZE:
		var r := (float(t) + 0.5) / float(TABLE_SIZE) * total
		var lo := 0
		var hi := cum.size() - 1
		while lo < hi:
			var mid := (lo + hi) >> 1
			if cum[mid] < r:
				lo = mid + 1
			else:
				hi = mid
		var o := t * 4
		data[o] = pts[lo].x
		data[o + 1] = pts[lo].y
		data[o + 2] = pts[lo].z
		data[o + 3] = 1.0
		var o2 := (TABLE_SIZE + t) * 4
		var v := vel[lo] if lo < vel.size() else Vector3.ZERO
		data[o2] = v.x
		data[o2 + 1] = v.y
		data[o2 + 2] = v.z
		data[o2 + 3] = 0.0
	var img := Image.create_from_data(TABLE_SIZE, 2, false, Image.FORMAT_RGBAF, data.to_byte_array())
	return ImageTexture.create_from_image(img)


func _make_emitter(table: ImageTexture, kind: float, count: int,
		lifetime: float, lifetime_rand: float) -> GPUParticles3D:
	var em := GPUParticles3D.new()
	# spray is too fine to throw shadows: as casters, thousands of sprites
	# speckle the falling sheet behind them
	em.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = load("res://addons/flowing_water/render/water_spray.gdshader")
	mat.set_shader_parameter("points_tex", table)
	mat.set_shader_parameter("point_count", TABLE_SIZE)
	mat.set_shader_parameter("kind", kind)
	mat.set_shader_parameter("life_rand", lifetime_rand)
	em.process_material = mat
	em.amount = count
	em.lifetime = lifetime
	em.local_coords = false
	em.draw_pass_1 = _make_draw_mesh(kind)
	if kind > 1.5 and kind < 2.5:
		# falling drops are streaks: the quad's Y axis follows the velocity
		em.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	em.custom_aabb = AABB(Vector3(-2000, -2000, -2000), Vector3(4000, 4000, 4000))
	em.emitting = false
	add_child(em)
	return em


static var _soft_tex: Texture2D

## Ragged puff sprite (generated once by WaterNoise.generate_puff).
static func _soft_circle() -> Texture2D:
	if _soft_tex != null:
		return _soft_tex
	var path := "res://addons/flowing_water/render/water_puff.res"
	if ResourceLoader.exists(path):
		_soft_tex = load(path)
	else:
		_soft_tex = WaterNoise.generate_puff(128)
	return _soft_tex


func _make_draw_mesh(kind: float) -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	if kind > 1.5 and kind < 2.5:
		var dm := ShaderMaterial.new()
		dm.shader = load("res://addons/flowing_water/render/water_droplet.gdshader")
		quad.material = dm
		return quad
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if kind > 0.5:
		# mist and impact spray are clouds of fine drops: lit by the sun
		# (darker in shade) and glowing when the sun is behind them -
		# drops scatter light forward
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.backlight_enabled = true
		m.backlight = Color(0.75, 0.78, 0.8)
		m.roughness = 1.0
		m.metallic_specular = 0.0
		m.emission_enabled = true
		m.emission = Color(0.16, 0.18, 0.2)   # sky light from all around
		# a camera standing in the mist must not look through a veil of
		# sprites stacked on its lens: puffs fade out as they come close
		m.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
		m.distance_fade_min_distance = 0.6
		m.distance_fade_max_distance = 3.0
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	# without this the particle's own scale is dropped and every droplet
	# is drawn as a 1 m quad
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = _soft_circle()
	m.no_depth_test = false
	# soft particles: fade where the sprite meets water, rocks or banks
	m.proximity_fade_enabled = true
	m.proximity_fade_distance = 0.5 if (kind > 0.5 and kind < 1.5) else (0.3 if kind > 2.5 else 0.08)
	m.disable_receive_shadows = kind < 0.5
	quad.material = m
	return quad


func _process(delta: float) -> void:
	_check_accum += delta
	if _check_accum < 0.4:
		return
	_check_accum = 0.0
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	var amount: float = mgr.spray_amount() if mgr != null else 1.0
	var wind: Vector3 = mgr.get_wind(global_position) if mgr != null else Vector3(0.4, 0, 0.3)
	for em: GPUParticles3D in [_spray, _mist, _fall, _impact]:
		if em == null:
			continue
		var near := false
		if em.process_material is ShaderMaterial:
			# near check against the emission table's rough bounds via parent
			near = cam.global_position.distance_to(global_position) < NEAR_DISTANCE * 3.0
			var parent := get_parent()
			if parent != null and parent.has_method("get_water_aabb"):
				var aabb: AABB = parent.get_water_aabb()
				near = aabb.grow(NEAR_DISTANCE).has_point(cam.global_position)
			em.process_material.set_shader_parameter("wind", wind)
		em.emitting = near and amount > 0.01
		em.amount_ratio = amount
