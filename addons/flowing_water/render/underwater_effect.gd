# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
class_name UnderwaterEffect
extends CompositorEffect
## The underwater view (underwater.glsl): absorption fog, caustics on
## everything below the surface, light shafts, suspended particles, a slight
## lens distortion and a waterline with a meniscus when the camera is half
## in the water. WaterManager attaches this to the camera's compositor and
## feeds it the style of the body the camera is in, every frame.
##
## Needs a RenderingDevice renderer with a half-float colour buffer
## (Forward+); elsewhere the manager falls back to environment fog.

## Light lost per metre along a view ray, per channel (water + sediment).
var extinction := Vector3(0.25, 0.06, 0.04)
## The sediment's share of `extinction` (per metre).
var sediment := 0.0
## Daylight lost per metre of depth below the surface, per channel.
var downwelling := Vector3(0.2, 0.05, 0.03)
## Colour of the light scattered toward the eye, just under the surface.
var fog_color := Vector3(0.02, 0.10, 0.09)
## World height of the water surface at the camera, and its slope there.
var surface_height := 0.0
var surface_gradient := Vector2.ZERO
## Direction toward the sun, already refracted into the water.
var sun_direction := Vector3(0.0, 1.0, 0.0)
## Sun colour times energy (zero at night: no caustics, no shafts).
var sun_color := Vector3.ONE
var caustics_strength := 1.0
var caustics_size := 1.4
## 1 = one noise sample (Deck/Low), 2 = the sharp two-sample network.
var caustics_taps := 2
## How far the light network has drifted with the current (metres).
var drift := Vector2.ZERO
var shaft_strength := 1.0
## Ray-march steps for the shafts; 0 = off.
var shaft_steps := 12
## Share of particle cells that hold a mote, 0..1.
var mote_density := 0.3
## Distance shells of particles; 0 = off.
var mote_shells := 4
var distortion := 1.0
var vignette := 0.22
## True adds the lens (distortion + blur), which costs a colour-buffer copy.
var full := true
var time := 0.0
## The player ripple simulation (RD texture + its world rect), so the
## waterline follows the ripples that displace the surface mesh.
var ripple_rd := RID()
var ripple_rect := Vector4(0, 0, 1, 0)
## Set false by the manager when the camera is above every surface.
var active := false

const COPY_SOURCE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) restrict readonly uniform image2D src;
layout(rgba16f, set = 0, binding = 1) restrict writeonly uniform image2D dst;
void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 s = imageSize(src);
	if (id.x >= s.x || id.y >= s.y) {
		return;
	}
	imageStore(dst, id, imageLoad(src, id));
}
"""
const UBO_FLOATS := 72

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _copy_shader := RID()
var _copy_pipeline := RID()
var _sampler := RID()
var _nearest_sampler := RID()
var _noise_sampler := RID()
var _ubo := RID()
var _scratch := RID()
var _scratch_size := Vector2i.ZERO
var _noise_rid := RID()
var _frame := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		enabled = false
		return
	RenderingServer.call_on_render_thread(_init_compute)


## The shared water noise (WaterManager.noise_texture); its alpha channel
## is the light network used for caustics and shafts.
func set_noise_texture(tex: Texture2D) -> void:
	_noise_rid = tex.get_rid() if tex != null else RID()


func _init_compute() -> void:
	var shader_file: RDShaderFile = load("res://addons/flowing_water/render/underwater.glsl")
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_warning("FlowingWater: underwater shader failed to compile: %s" % spirv.compile_error_compute)
		enabled = false
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var copy_src := RDShaderSource.new()
	copy_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	copy_src.source_compute = COPY_SOURCE
	var copy_spirv := _rd.shader_compile_spirv_from_source(copy_src)
	if copy_spirv.compile_error_compute == "":
		_copy_shader = _rd.shader_create_from_spirv(copy_spirv)
		_copy_pipeline = _rd.compute_pipeline_create(_copy_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var ns := RDSamplerState.new()
	ns.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ns.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ns.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ns.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_nearest_sampler = _rd.sampler_create(ns)
	var rs := RDSamplerState.new()
	rs.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	rs.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	rs.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	rs.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	rs.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_noise_sampler = _rd.sampler_create(rs)
	var zero := PackedByteArray()
	zero.resize(UBO_FLOATS * 4)
	_ubo = _rd.uniform_buffer_create(zero.size(), zero)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		for rid in [_pipeline, _shader, _copy_pipeline, _copy_shader, _sampler,
				_nearest_sampler, _noise_sampler, _ubo, _scratch]:
			if rid.is_valid():
				_rd.free_rid(rid)


## A texture the size of the colour buffer, for the lens to read from.
func _scratch_for(size: Vector2i) -> RID:
	if _scratch.is_valid() and _scratch_size == size:
		return _scratch
	if _scratch.is_valid():
		_rd.free_rid(_scratch)
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.width = size.x
	tf.height = size.y
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_scratch = _rd.texture_create(tf, RDTextureView.new())
	_scratch_size = size
	return _scratch


func _image_uniform(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u


func _sampler_uniform(binding: int, sampler: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex)
	return u


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	if not active or _rd == null or not _pipeline.is_valid() or not _noise_rid.is_valid():
		return
	var buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	if buffers == null:
		return
	var scene_data: RenderSceneDataRD = render_data.get_render_scene_data()
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var noise_rd := RenderingServer.texture_get_rd_texture(_noise_rid)
	if not noise_rd.is_valid():
		return
	_frame = (_frame + 1) % 64
	var use_lens := full and _copy_pipeline.is_valid()
	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		if not color.is_valid() or not depth.is_valid():
			continue
		if _rd.texture_get_format(color).format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
			continue
		var proj := scene_data.get_view_projection(view)
		var inv_proj := proj.inverse()
		var cam := scene_data.get_cam_transform()
		# (reads back negative with the reversed-depth projection)
		var near := absf(scene_data.get_cam_projection().get_z_near())

		var f := PackedFloat32Array()
		for col in 4:
			for row in 4:
				f.append(inv_proj[col][row])
		var basis := cam.basis
		for col in 3:
			f.append_array([basis[col].x, basis[col].y, basis[col].z, 0.0])
		f.append_array([cam.origin.x, cam.origin.y, cam.origin.z, 1.0])
		f.append_array([extinction.x, extinction.y, extinction.z, sediment])
		f.append_array([downwelling.x, downwelling.y, downwelling.z, surface_height])
		f.append_array([fog_color.x, fog_color.y, fog_color.z, time])
		f.append_array([sun_direction.x, sun_direction.y, sun_direction.z, shaft_strength])
		f.append_array([sun_color.x, sun_color.y, sun_color.z, mote_density])
		f.append_array([surface_gradient.x, surface_gradient.y, drift.x, drift.y])
		f.append_array([caustics_strength, 1.0 / maxf(caustics_size, 0.1), float(caustics_taps),
			distortion if use_lens else 0.0])
		f.append_array([float(shaft_steps), float(mote_shells), 1.0 if use_lens else 0.0, near])
		f.append_array([float(size.x), float(size.y), float(_frame), vignette])
		var ripple_tex := noise_rd
		var rr := Vector4(0, 0, 1, 0)
		if ripple_rect.w > 0.5 and ripple_rd.is_valid() and _rd.texture_is_valid(ripple_rd):
			ripple_tex = ripple_rd
			rr = ripple_rect
		f.append_array([rr.x, rr.y, rr.z, rr.w])
		var bytes := f.to_byte_array()
		_rd.buffer_update(_ubo, 0, bytes.size(), bytes)

		# the lens reads neighbouring pixels: give it a copy to read from
		var src := depth
		if use_lens:
			src = _scratch_for(size)
			var cset := UniformSetCacheRD.get_cache(_copy_shader, 0,
				[_image_uniform(0, color), _image_uniform(1, src)])
			var ccl := _rd.compute_list_begin()
			_rd.compute_list_bind_compute_pipeline(ccl, _copy_pipeline)
			_rd.compute_list_bind_uniform_set(ccl, cset, 0)
			_rd.compute_list_dispatch(ccl, groups_x, groups_y, 1)
			_rd.compute_list_end()

		var u_ubo := RDUniform.new()
		u_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u_ubo.binding = 4
		u_ubo.add_id(_ubo)
		var uset := UniformSetCacheRD.get_cache(_shader, 0, [
			_image_uniform(0, color),
			_sampler_uniform(1, _nearest_sampler, depth),
			_sampler_uniform(2, _sampler, src),
			_sampler_uniform(3, _noise_sampler, noise_rd),
			_sampler_uniform(5, _sampler, ripple_tex),
			u_ubo])
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
		_rd.compute_list_end()
