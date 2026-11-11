# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
class_name RippleSim
extends Node
## Player-centred ripple simulation: a wave equation stepped by a compute
## shader on the main RenderingDevice, ping-ponged between two RG16F textures
## and published to shaders as the `flowing_water_ripple` global.
##
## On the Compatibility renderer there is no RenderingDevice; ripples are
## switched off with one clear warning (see README, "Renderer support").

const GRID_WORLD_SIZE := 24.0
const FIXED_DT := 1.0 / 60.0
const SLEEP_AFTER := 4.0
const MAX_INJECTIONS := 32

var focus_position := Vector3.ZERO

var _n := 0
var _steps_per_frame := 1
var _supported := true
var _warned := false

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex: Array[RID] = []
var _sampler: RID
var _inj_buffer: RID
var _current := 0
var _origin := Vector2.ZERO
var _initialized_rd := false
var _output_tex: Texture2DRD

var _accum := 0.0
var _awake_time := 0.0
var _pending_inj: Array[Vector4] = []
var _active := false


func _ready() -> void:
	set_process(true)
	RenderingServer.global_shader_parameter_set("flowing_water_ripple", _placeholder_tex())


func configure(grid: int, steps: int) -> void:
	_steps_per_frame = steps
	if grid == _n:
		return
	_release()
	_n = grid
	if _n <= 0:
		_publish_inactive()
		return
	if RenderingServer.get_rendering_device() == null:
		_supported = false
		# (a headless run has no renderer at all: nothing to warn about)
		if not _warned and DisplayServer.get_name() != "headless":
			_warned = true
			push_warning("FlowingWater: the Compatibility renderer has no compute shaders; player ripples are disabled. Use Forward+ or Mobile for ripples.")
		_publish_inactive()
		return
	RenderingServer.call_on_render_thread(_init_rd)


func add_ripple(pos: Vector3, strength: float, radius: float = 0.4) -> void:
	if _n <= 0 or not _supported:
		return
	if _pending_inj.size() < MAX_INJECTIONS:
		_pending_inj.append(Vector4(pos.x, pos.z, radius, strength))
	_awake_time = SLEEP_AFTER


func _process(delta: float) -> void:
	if _n <= 0 or not _supported or not _initialized_rd:
		return
	var mgr := _manager()
	if mgr == null:
		return
	var rect: Vector4 = mgr.map_rect()
	if rect.w < 0.5:
		_publish_inactive()
		return
	_awake_time -= delta
	if _awake_time <= 0.0 and _pending_inj.is_empty():
		if _active:
			_active = false
			_publish_inactive()
		return
	_active = true
	# fixed timestep; the frame delta is clamped so a hitch never blows it up
	_accum += minf(delta, 0.1)
	var steps := 0
	while _accum >= FIXED_DT and steps < _steps_per_frame:
		_accum -= FIXED_DT
		steps += 1
	if _accum >= FIXED_DT:
		_accum = fmod(_accum, FIXED_DT)
	if steps == 0:
		return
	var texel := GRID_WORLD_SIZE / float(_n)
	var new_origin := Vector2(
		snappedf(focus_position.x - GRID_WORLD_SIZE * 0.5, texel),
		snappedf(focus_position.z - GRID_WORLD_SIZE * 0.5, texel))
	var inj := _pending_inj.duplicate()
	_pending_inj.clear()
	var map_tex: ImageTexture = mgr.map_texture()
	if map_tex == null:
		return
	RenderingServer.call_on_render_thread(
		_render_steps.bind(steps, new_origin, inj, rect, map_tex.get_rid()))
	_origin = new_origin
	RenderingServer.global_shader_parameter_set("flowing_water_ripple_rect",
		Vector4(new_origin.x, new_origin.y, GRID_WORLD_SIZE, float(_n)))


## The RenderingDevice texture holding the current ripple heights (r), or
## an invalid RID while the simulation is asleep or unsupported.
func output_rd_texture() -> RID:
	if not _active or not _initialized_rd or _tex.size() < 2:
		return RID()
	return _tex[_current]


## World rect of the ripple grid: xy = origin (min x, min z), z = size,
## w = texels per side (0 = off). Same as the `flowing_water_ripple_rect` global.
func world_rect() -> Vector4:
	if not _active or not _initialized_rd:
		return Vector4(0, 0, 1, 0)
	return Vector4(_origin.x, _origin.y, GRID_WORLD_SIZE, float(_n))


func _publish_inactive() -> void:
	RenderingServer.global_shader_parameter_set("flowing_water_ripple_rect", Vector4(0, 0, 1, 0))


func _manager() -> Node:
	return get_parent()


# --------------------------------------------------------- render thread side --

func _init_rd() -> void:
	_rd = RenderingServer.get_rendering_device()
	var shader_file: RDShaderFile = load("res://addons/flowing_water/render/ripples.glsl")
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_warning("FlowingWater: ripple shader failed to compile: %s" % spirv.compile_error_compute)
		_supported = false
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var fmt := RDTextureFormat.new()
	fmt.width = _n
	fmt.height = _n
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_tex.clear()
	var zero := PackedByteArray()
	zero.resize(_n * _n * 4)
	for i in 2:
		_tex.append(_rd.texture_create(fmt, RDTextureView.new(), [zero]))
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var inj_bytes := PackedByteArray()
	inj_bytes.resize(MAX_INJECTIONS * 16)
	_inj_buffer = _rd.storage_buffer_create(inj_bytes.size(), inj_bytes)
	_output_tex = Texture2DRD.new()
	_output_tex.texture_rd_rid = _tex[0]
	RenderingServer.global_shader_parameter_set("flowing_water_ripple", _output_tex)
	_initialized_rd = true


func _render_steps(steps: int, new_origin: Vector2, inj: Array[Vector4],
		map_rect: Vector4, map_tex_rid: RID) -> void:
	if not _initialized_rd:
		return
	var map_rd_tex := RenderingServer.texture_get_rd_texture(map_tex_rid)
	if not map_rd_tex.is_valid():
		return
	# upload injections (applied only on the first step this frame)
	var inj_f := PackedFloat32Array()
	inj_f.resize(MAX_INJECTIONS * 4)
	for i in inj.size():
		inj_f[i * 4] = inj[i].x
		inj_f[i * 4 + 1] = inj[i].y
		inj_f[i * 4 + 2] = inj[i].z
		inj_f[i * 4 + 3] = inj[i].w
	_rd.buffer_update(_inj_buffer, 0, MAX_INJECTIONS * 16, inj_f.to_byte_array())

	var texel := GRID_WORLD_SIZE / float(_n)
	var origin_old := _origin
	var groups := (_n + 7) / 8
	for s in steps:
		var src := _tex[_current]
		var dst := _tex[1 - _current]
		var uniforms: Array[RDUniform] = []
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u0.binding = 0
		u0.add_id(_sampler)
		u0.add_id(src)
		uniforms.append(u0)
		var u1 := RDUniform.new()
		u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u1.binding = 1
		u1.add_id(dst)
		uniforms.append(u1)
		var u2 := RDUniform.new()
		u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u2.binding = 2
		u2.add_id(_sampler)
		u2.add_id(map_rd_tex)
		uniforms.append(u2)
		var u3 := RDUniform.new()
		u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u3.binding = 3
		u3.add_id(_inj_buffer)
		uniforms.append(u3)
		var uset := _rd.uniform_set_create(uniforms, _shader, 0)

		var push := PackedFloat32Array([
			origin_old.x, origin_old.y, new_origin.x, new_origin.y,
			map_rect.x, map_rect.y, map_rect.z, map_rect.w,
			GRID_WORLD_SIZE, texel, FIXED_DT, 0.9975,
		]).to_byte_array()
		push.append_array(PackedInt32Array([_n, inj.size() if s == 0 else 0]).to_byte_array())
		push.append_array(PackedFloat32Array([0.0, 0.0]).to_byte_array())

		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, push, push.size())
		_rd.compute_list_dispatch(cl, groups, groups, 1)
		_rd.compute_list_end()
		_current = 1 - _current
		origin_old = new_origin
	_output_tex.texture_rd_rid = _tex[_current]


static var _placeholder: ImageTexture

static func _placeholder_tex() -> ImageTexture:
	if _placeholder == null:
		var img := Image.create_empty(4, 4, false, Image.FORMAT_RF)
		_placeholder = ImageTexture.create_from_image(img)
	return _placeholder


func _release() -> void:
	# unhook the global before freeing the RD textures, so no material is
	# left sampling a dead RID
	RenderingServer.global_shader_parameter_set("flowing_water_ripple", _placeholder_tex())
	_publish_inactive()
	if _output_tex != null:
		_output_tex.texture_rd_rid = RID()
	if _initialized_rd:
		RenderingServer.call_on_render_thread(_release_rd)
	_initialized_rd = false


func _release_rd() -> void:
	if _rd == null:
		return
	for t in _tex:
		if t.is_valid():
			_rd.free_rid(t)
	_tex.clear()
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
	if _inj_buffer.is_valid():
		_rd.free_rid(_inj_buffer)
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_sampler = RID()
	_inj_buffer = RID()
	_pipeline = RID()
	_shader = RID()


func _exit_tree() -> void:
	_release()
