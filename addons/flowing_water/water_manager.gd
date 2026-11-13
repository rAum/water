# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
extends Node
## Autoload registered by the plugin as `WaterManager`.
##
## Keeps the registry of water bodies, answers CPU queries (height, flow,
## depth), owns the quality preset, maintains the world water map and the
## ripple simulation, and connects to optional WindField / FogSim /
## WaterSystem autoloads through one adapter.
##
## Queries read the baked CPU arrays; there is never a GPU readback.

signal quality_changed(preset: int)

enum Quality { DECK, LOW, MEDIUM, HIGH }

const ADDON := "res://addons/flowing_water/"
const NOISE_PATH := ADDON + "render/water_noise.res"
const FALL_PATH := ADDON + "render/water_fall.res"

## Quality preset table (Milestone 9).
const PRESETS := {
	Quality.DECK: {
		"shader_suffix": "deck", "vertex_wave_dist": 25.0, "ripple_grid": 128,
		"ripple_steps": 1, "map_size": 192, "caustics": 1.0, "spray": 0.35,
		"underwater_full": false, "underwater_shafts": 0, "underwater_motes": 0,
	},
	Quality.LOW: {
		"shader_suffix": "low", "vertex_wave_dist": 20.0, "ripple_grid": 0,
		"ripple_steps": 0, "map_size": 192, "caustics": 0.0, "spray": 0.2,
		"underwater_full": false, "underwater_shafts": 0, "underwater_motes": 0,
	},
	Quality.MEDIUM: {
		"shader_suffix": "full", "vertex_wave_dist": 40.0, "ripple_grid": 192,
		"ripple_steps": 2, "map_size": 320, "caustics": 1.0, "spray": 0.7,
		"underwater_full": true, "underwater_shafts": 6, "underwater_motes": 2,
	},
	Quality.HIGH: {
		"shader_suffix": "full", "vertex_wave_dist": 60.0, "ripple_grid": 256,
		"ripple_steps": 2, "map_size": 320, "caustics": 1.0, "spray": 1.0,
		"underwater_full": true, "underwater_shafts": 12, "underwater_motes": 4,
	},
}

## How the world water map (what banks, bed and rocks read to look wet, show
## caustics and tint under water; also the ripple simulation's flow) covers
## the scene.
enum MapMode {
	## One map over every water body in the scene, built once from the
	## bakes (again only when a body is re-baked). No edges, nothing to
	## fade, no work while playing. The default.
	WHOLE_SCENE,
	## A square of `map_follow_extent` metres around the camera, rebuilt in
	## the background as it moves; the water's effect on its surroundings
	## fades out before the square's edge. For worlds too large for one map
	## (more than `map_max_size` texels at `map_texel`).
	FOLLOW_CAMERA,
}

var map_mode: MapMode = MapMode.WHOLE_SCENE:
	set(v):
		map_mode = v
		invalidate_map()
## Metres per texel of the whole-scene map (finer = sharper wet bands at
## the waterline, more memory: 8 bytes per texel).
var map_texel := 0.2:
	set(v):
		map_texel = maxf(v, 0.05)
		invalidate_map()
## Largest whole-scene map, texels per side; a scene that needs more uses a
## coarser texel (and above 4x this, the follow-camera map).
var map_max_size := 2048
## Width of the follow-camera map (m).
var map_follow_extent := 64.0:
	set(v):
		map_follow_extent = maxf(v, 16.0)
		invalidate_map()
## Follow-camera map: the water's effect on its surroundings is full within
## x metres of the camera and gone by y. It follows the camera every frame
## and ends well inside what the map is guaranteed to cover (half the
## extent, minus the rebuild distance, minus how far one can travel while a
## rebuild is in flight), so the edge of the square is never seen.
var map_follow_fade := Vector2(14.0, 20.0)
const MAP_REBUILD_DISTANCE := 6.0
## Per-frame budget of texel writes for the incremental map rebuild (about
## a millisecond of CPU; a full rebuild takes a handful of frames).
const MAP_TEXELS_PER_FRAME := 2500

var quality: Quality = Quality.HIGH:
	set(v):
		if quality == v:
			return
		quality = v
		_apply_quality()
		quality_changed.emit(v)

## Extra turbidity (0-1) added to every water style at runtime: raise it
## after rain or during a flood and all rivers turn muddy together.
var storm_turbidity := 0.0:
	set(v):
		storm_turbidity = clampf(v, 0.0, 1.0)
		RenderingServer.global_shader_parameter_set("flowing_water_turbidity", storm_turbidity)

## Colour of the sediment that `storm_turbidity` washes in (runoff mud).
var storm_color := Color(0.33, 0.24, 0.13):
	set(v):
		storm_color = v
		RenderingServer.global_shader_parameter_set("flowing_water_storm_color", Vector3(v.r, v.g, v.b))

## The noise texture every water shader shares (slopes/height/ridged foam).
var noise_texture: Texture2D
## The waterfall "fluid" texture (curtains, strands and fibres of falling
## water), scrolled along falls by the surface shader.
var fall_texture: Texture2D

var _bodies: Array[Node3D] = []
var _junctions: Array[Node3D] = []
var _ripples: RippleSim
var _player_pos := Vector3.ZERO
var _has_focus_pos := false

# world map state
var _map_tex: ImageTexture
var _map_size := 256
var _map_origin := Vector2.ZERO       # world min x/z of the current map
var _map_base := 0.0                  # height encoding base
var _map_active := false
## False after bodies change or a re-bake: the next frame rebuilds the map.
var _map_valid_for_bodies := false

# adapter: optional integrations, resolved once at startup
var wind_field: Node = null
var fog_sim: Node = null
var water_system: Node = null


## Reusable query result; see get_* wrappers below.
class WaterQuery:
	extends RefCounted
	var valid := false
	var height := NAN
	var flow := Vector3.ZERO
	var depth := 0.0
	var body: Node3D = null
	var weight := 1.0


func _enter_tree() -> void:
	_register_shader_globals()
	noise_texture = _load_or_make_noise()
	if ResourceLoader.exists(FALL_PATH):
		fall_texture = load(FALL_PATH)
	else:
		fall_texture = WaterNoise.generate_fall(512)
		if Engine.is_editor_hint():
			ResourceSaver.save(fall_texture, FALL_PATH, ResourceSaver.FLAG_COMPRESS)
	RenderingServer.global_shader_parameter_set("flowing_water_noise", noise_texture)
	RenderingServer.global_shader_parameter_set("flowing_water_map_rect", Vector4(0, 0, 1, 0))
	RenderingServer.global_shader_parameter_set("flowing_water_ripple_rect", Vector4(0, 0, 1, 0))
	RenderingServer.global_shader_parameter_set("flowing_water_caustics", 1.0)
	RenderingServer.global_shader_parameter_set("flowing_water_turbidity", storm_turbidity)
	RenderingServer.global_shader_parameter_set("flowing_water_storm_color",
		Vector3(storm_color.r, storm_color.g, storm_color.b))


func _ready() -> void:
	if not Engine.is_editor_hint():
		if is_steam_deck():
			quality = Quality.DECK
		_resolve_adapters()
	_apply_quality()
	_ripples = RippleSim.new()
	add_child(_ripples)
	var p: Dictionary = PRESETS[quality]
	_ripples.configure(p["ripple_grid"], p["ripple_steps"])
	_precompile_shaders()


## Load every shader variant up front so switching styles, quality or LOD
## never compiles (or hits the disk) during gameplay.
func _precompile_shaders() -> void:
	for f in ["water_full", "water_deck", "water_low", "water_far",
			"water_stylized", "water_stylized_low", "water_stylized_far",
			"water_spray", "rock_receiver"]:
		load(ADDON + "render/" + f + ".gdshader")


func _exit_tree() -> void:
	pass


func _process(delta: float) -> void:
	# the water's own clock (see water_time): wraps like the engine's TIME so
	# float precision never degrades in a long session
	water_time = fmod(water_time + delta, 3600.0)
	RenderingServer.global_shader_parameter_set("flowing_water_time", water_time)
	if Engine.is_editor_hint():
		# in the editor, follow the editor camera so previews work
		# (via the singleton: EditorInterface does not exist in export templates)
		var ei: Object = Engine.get_singleton("EditorInterface")
		var vp: Viewport = ei.get_editor_viewport_3d(0) if ei != null else null
		if vp != null and vp.get_camera_3d() != null:
			_player_pos = vp.get_camera_3d().global_position
			_has_focus_pos = true
	else:
		var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
		if cam != null:
			_player_pos = cam.global_position
			_has_focus_pos = true
	if _has_focus_pos:
		var fade := map_follow_fade if _map_follows else Vector2(1e6, 2e6)
		RenderingServer.global_shader_parameter_set("flowing_water_map_focus",
			Vector4(_player_pos.x, _player_pos.z, fade.x, fade.y))
	_update_world_map()
	if _ripples != null:
		_ripples.focus_position = _player_pos
	if not Engine.is_editor_hint():
		_update_underwater(delta)


# ------------------------------------------------------------------ registry --

func register_body(body: Node3D) -> void:
	if not _bodies.has(body):
		_bodies.append(body)
	invalidate_map()


func unregister_body(body: Node3D) -> void:
	_bodies.erase(body)
	invalidate_map()


func register_junction(j: Node3D) -> void:
	if not _junctions.has(j):
		_junctions.append(j)


func unregister_junction(j: Node3D) -> void:
	_junctions.erase(j)


## Call after anything that changes what the world map should contain (the
## water nodes do this themselves after a bake).
func invalidate_map() -> void:
	_map_valid_for_bodies = false
	_build = null


func get_bodies() -> Array[Node3D]:
	return _bodies


# ------------------------------------------------------------------- queries --

func query(pos: Vector3, out: WaterQuery = null) -> WaterQuery:
	if out == null:
		out = WaterQuery.new()
	out.valid = false
	out.height = NAN
	out.flow = Vector3.ZERO
	out.depth = 0.0
	out.body = null
	var total_w := 0.0
	var height := 0.0
	var flow := Vector3.ZERO
	var depth := 0.0
	var best_w := 0.0
	for body in _bodies:
		if not body.has_method("query_water"):
			continue
		var r: Array = body.query_water(pos)
		if r.is_empty():
			continue
		# r = [height, flow(Vector3), depth, weight]
		var w: float = r[3]
		if w <= 0.0:
			continue
		total_w += w
		height += r[0] * w
		flow += r[1] * w
		depth += r[2] * w
		if w > best_w:
			best_w = w
			out.body = body
	if total_w > 0.0:
		out.valid = true
		out.height = height / total_w
		out.flow = flow / total_w
		out.depth = depth / total_w
	return out


var _scratch_query := WaterQuery.new()

## NAN if there is no water here.
## The clock every water surface animates by (seconds, wraps at an hour).
## The shaders read it as the `flowing_water_time` global instead of TIME,
## so the CPU can reproduce the drawn waves exactly (see drawn_height()).
var water_time := 0.0


## Height of the water surface as it is drawn this frame at a position:
## the baked level plus the standing waves and wind swell the vertex shader
## adds (player ripples excepted: they live on the GPU). NAN if no water.
## Use it where a few centimetres matter, such as whether the camera is
## under the surface; query()/get_height() give the mean level.
func drawn_height(pos: Vector3, q: WaterQuery = null) -> float:
	if q == null:
		q = query(pos, WaterQuery.new())
	if not q.valid:
		return NAN
	if q.body != null and q.body.has_method("drawn_height"):
		var h: float = q.body.drawn_height(pos, water_time)
		if not is_nan(h):
			return h
	return q.height


## Bilinear sample of one channel of the water noise texture at a texture
## UV (repeating), the way the shaders' textureLod(noise_tex, uv, 0) does.
func sample_noise(uv: Vector2, channel: int) -> float:
	if _noise_img == null:
		if noise_texture == null:
			return 0.5
		_noise_img = noise_texture.get_image()
		if _noise_img == null:
			return 0.5
		if _noise_img.is_compressed():
			_noise_img.decompress()
	var w := _noise_img.get_width()
	var h := _noise_img.get_height()
	var x := uv.x * w - 0.5
	var y := uv.y * h - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var c00: float = _noise_img.get_pixel(posmod(x0, w), posmod(y0, h))[channel]
	var c10: float = _noise_img.get_pixel(posmod(x0 + 1, w), posmod(y0, h))[channel]
	var c01: float = _noise_img.get_pixel(posmod(x0, w), posmod(y0 + 1, h))[channel]
	var c11: float = _noise_img.get_pixel(posmod(x0 + 1, w), posmod(y0 + 1, h))[channel]
	return lerpf(lerpf(c00, c10, fx), lerpf(c01, c11, fx), fy)


var _noise_img: Image


func get_height(pos: Vector3) -> float:
	return query(pos, _scratch_query).height


func get_flow(pos: Vector3) -> Vector3:
	return query(pos, _scratch_query).flow


func get_depth(pos: Vector3) -> float:
	return query(pos, _scratch_query).depth


func get_body(pos: Vector3) -> Node:
	return query(pos, _scratch_query).body


# -------------------------------------------------------------------- ripples --

## Disturb the water surface (rings, wakes, splashes).
func add_ripple(pos: Vector3, strength: float, radius: float = 0.4) -> void:
	if _ripples != null:
		_ripples.add_ripple(pos, strength, radius)


# -------------------------------------------------------------------- quality --

static func is_steam_deck() -> bool:
	return OS.get_environment("SteamDeck") == "1"


func preset_value(key: String) -> Variant:
	return PRESETS[quality][key]


func _apply_quality() -> void:
	var p: Dictionary = PRESETS[quality]
	_map_size = p["map_size"]
	RenderingServer.global_shader_parameter_set("flowing_water_caustics", p["caustics"])
	invalidate_map()
	for body in _bodies:
		if body.has_method("apply_quality"):
			body.apply_quality()
	if _ripples != null:
		_ripples.configure(p["ripple_grid"], p["ripple_steps"])


## The shader file for a body, given its style variant and the distance class.
func shader_for(style_variant: int, far: bool) -> Shader:
	var p: Dictionary = PRESETS[quality]
	var suffix: String = p["shader_suffix"]
	var name: String
	if style_variant == WaterStyle.Variant.STYLIZED:
		if far:
			name = "water_stylized_far"
		elif suffix == "low":
			name = "water_stylized_low"
		else:
			name = "water_stylized"
	else:
		if far:
			name = "water_far"
		else:
			name = "water_" + suffix
	return load(ADDON + "render/" + name + ".gdshader")


func vertex_wave_distance() -> float:
	return PRESETS[quality]["vertex_wave_dist"]


func spray_amount() -> float:
	return PRESETS[quality]["spray"]


# ------------------------------------------------------------------- adapters --

## Optional integration with the project's larger systems. If they are
## absent nothing breaks and nothing is logged as an error.
func _resolve_adapters() -> void:
	var root := get_tree().root
	wind_field = root.get_node_or_null("WindField")
	fog_sim = root.get_node_or_null("FogSim")
	water_system = root.get_node_or_null("WaterSystem")


## Wind at a position: from WindField if present, else a gentle constant.
func get_wind(pos: Vector3) -> Vector3:
	if wind_field != null and wind_field.has_method("get_wind"):
		return wind_field.get_wind(pos)
	return Vector3(0.5, 0.0, 0.3)


# ------------------------------------------------------------ world water map --
# A player-centred top-down texture (rg = flow in world XZ m/s encoded
# /16+0.5, b = height above map base * 0.5 + 2.0, a = depth * 0.125) built on
# the CPU from the baked arrays, a few rows per frame, swapped when complete.
# This replaces the SubViewport render from the plan: the CPU arrays are
# authoritative, the result is exact half-float data on every renderer, and
# there is no render-layer or colour-space bookkeeping.

## One map rebuild in progress: bodies splat their baked grids into `buf`
## (4 floats per texel) a bounded number of texels per frame.
class MapBuild:
	extends RefCounted
	var buf: PackedFloat32Array
	var n := 0
	var ox := 0.0          # world x of the map's min corner
	var oz := 0.0
	var texel := 0.25
	var base := 0.0

	## Writes water at a world position. `w` < 1 blends with what is there
	## (junction fades).
	func put_water(x: float, z: float, fx: float, fz: float, height: float, depth: float, w: float) -> void:
		var i := int((x - ox) / texel)
		var j := int((z - oz) / texel)
		if i < 0 or j < 0 or i >= n or j >= n:
			return
		var o := (j * n + i) * 4
		var r := fx / 16.0 + 0.5
		var g := fz / 16.0 + 0.5
		var b := (height - base) * 0.5 + 2.0
		var a := depth * 0.125
		if w < 0.999 and buf[o + 3] > 0.0:
			buf[o] = lerpf(buf[o], r, w)
			buf[o + 1] = lerpf(buf[o + 1], g, w)
			buf[o + 2] = lerpf(buf[o + 2], b, w)
			buf[o + 3] = lerpf(buf[o + 3], a, w)
		elif w > 0.01:
			buf[o] = r
			buf[o + 1] = g
			buf[o + 2] = b
			buf[o + 3] = a

	## Writes only the surface height on dry land beside the water (for wet
	## banks); never overwrites water, keeps the higher level.
	func put_bank(x: float, z: float, height: float) -> void:
		var i := int((x - ox) / texel)
		var j := int((z - oz) / texel)
		if i < 0 or j < 0 or i >= n or j >= n:
			return
		var o := (j * n + i) * 4
		if buf[o + 3] > 0.0:
			return
		var b := (height - base) * 0.5 + 2.0
		if b > buf[o + 2]:
			buf[o + 2] = b


var _build: MapBuild
var _build_bodies: Array = []
var _build_idx := 0
var _build_cursor := 0


func _set_map_inactive() -> void:
	if _map_active:
		_map_active = false
		RenderingServer.global_shader_parameter_set("flowing_water_map_rect", Vector4(0, 0, 1, 0))


func _update_world_map() -> void:
	if not _has_focus_pos or _bodies.is_empty():
		_set_map_inactive()
		return
	if _build == null:
		var whole := _whole_scene_window()
		_map_follows = whole.size.x <= 0.0
		var extent := whole.size.x
		var n := 0
		var texel := 0.0
		var want_origin := Vector2(whole.position.x, whole.position.z)
		if _map_follows:
			extent = map_follow_extent
			n = _map_size
			texel = extent / float(n)
			want_origin = Vector2(
				snappedf(_player_pos.x - extent * 0.5, texel),
				snappedf(_player_pos.z - extent * 0.5, texel))
			if _map_valid_for_bodies and _map_active and is_equal_approx(_map_extent, extent) \
					and _map_origin.distance_to(want_origin) < MAP_REBUILD_DISTANCE:
				return
		else:
			# built once; again only when a body changes (re-bake, move)
			if _map_valid_for_bodies and _map_active:
				return
			n = int(ceilf(extent / map_texel))
			texel = map_texel
			if n > map_max_size:
				n = map_max_size
				texel = extent / float(n)
		var window := AABB(Vector3(want_origin.x, -1e5, want_origin.y), Vector3(extent, 2e5, extent))
		_build_bodies.clear()
		var lowest := INF
		for body in _bodies:
			if not (body.has_method("splat_water_map") and body.has_method("get_water_aabb")):
				continue
			var aabb: AABB = body.get_water_aabb()
			if window.intersects(aabb.grow(3.0)):
				_build_bodies.append(body)
				lowest = minf(lowest, aabb.position.y)
		if _build_bodies.is_empty():
			_set_map_inactive()
			return
		# ponds first: rivers blend over them in junction zones
		_build_bodies.sort_custom(func(a, b): return a is WaterPond and not (b is WaterPond))
		_build = MapBuild.new()
		_build.n = n
		_build_extent = extent
		_build.ox = want_origin.x
		_build.oz = want_origin.y
		_build.texel = texel
		# The height channel is (height - base) * 0.5 + 2 and anything at or
		# below 0 reads as "no water", so the base must lie under every
		# water surface in the window. It used to be the camera height:
		# after walking down a waterfall the map built from the top could
		# not hold the river 4 m below, the bed below rendered dry (bright)
		# and turned wet (dark) as a whole square at the next rebuild.
		_build.base = lowest - 1.0
		_build.buf = PackedFloat32Array()
		_build.buf.resize(n * n * 4)
		# resize() zero-fills: flow must read as "none" (0.5), height/depth 0
		var k := 0
		var total := n * n * 4
		while k < total:
			_build.buf[k] = 0.5
			_build.buf[k + 1] = 0.5
			k += 4
		_build_idx = 0
		_build_cursor = 0
		return
	# continue the build within this frame's budget (the whole-scene map is
	# built in one go: it happens at load and after a re-bake, both of which
	# already take a moment, and a half-built map would show)
	var budget := MAP_TEXELS_PER_FRAME if _map_follows else 1 << 30
	while budget > 0 and _build_idx < _build_bodies.size():
		var body = _build_bodies[_build_idx]
		if not is_instance_valid(body):
			_build_idx += 1
			_build_cursor = 0
			continue
		var r: Vector2i = body.splat_water_map(_build, _build_cursor, budget)
		budget -= r.y
		if r.x < 0:
			_build_idx += 1
			_build_cursor = 0
		else:
			_build_cursor = r.x
			if r.y <= 0:
				break
	if _build_idx >= _build_bodies.size():
		var n := _build.n
		var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBAF, _build.buf.to_byte_array())
		img.convert(Image.FORMAT_RGBAH)
		if _map_tex == null or _map_tex.get_width() != n:
			_map_tex = ImageTexture.create_from_image(img)
		else:
			_map_tex.update(img)
		_map_origin = Vector2(_build.ox, _build.oz)
		_map_extent = _build_extent
		_map_base = _build.base
		_map_active = true
		_map_valid_for_bodies = true
		_build = null
		RenderingServer.global_shader_parameter_set("flowing_water_map", _map_tex)
		RenderingServer.global_shader_parameter_set("flowing_water_map_rect",
			Vector4(_map_origin.x, _map_origin.y, _map_extent, 1.0))
		RenderingServer.global_shader_parameter_set("flowing_water_map_base", _map_base)


## Flow/height/depth lookup for the ripple sim and others needing map data.
func map_texture() -> ImageTexture:
	return _map_tex


func map_rect() -> Vector4:
	return Vector4(_map_origin.x, _map_origin.y, _map_extent, 1.0 if _map_active else 0.0)


var _map_extent := 64.0
var _build_extent := 64.0
var _map_follows := false


## The square the whole-scene map covers (every body's water, plus a margin
## for wet banks), or an empty AABB when the follow-camera map is used.
func _whole_scene_window() -> AABB:
	if map_mode != MapMode.WHOLE_SCENE:
		return AABB()
	var box := AABB()
	var first := true
	for body in _bodies:
		if not body.has_method("get_water_aabb"):
			continue
		var a: AABB = body.get_water_aabb()
		box = a if first else box.merge(a)
		first = false
	if first:
		return AABB()
	box = box.grow(4.0)
	var side := maxf(box.size.x, box.size.z)
	if side / map_texel > map_max_size * 4:
		return AABB()    # too large for one map: follow the camera
	return AABB(Vector3(box.position.x, 0.0, box.position.z), Vector3(side, 0.0, side))



func map_base() -> float:
	return _map_base


# ----------------------------------------------------------------- underwater --
# When the camera is in a water body the view gets that body's style from
# below: absorption fog, caustics on everything, light shafts, drifting
# particles, a waterline when half in (render/underwater.glsl). Per-style
# controls are in WaterStyle's "Underwater" group; these are the global ones.

## Master switch for the underwater view. Off = the camera sees through
## water as if it were air (the surface is still drawn from below).
var underwater_enabled := true:
	set(v):
		underwater_enabled = v
		if not v:
			_underwater_off()

## Wavy lens distortion and distance blur of the underwater image
## (Medium/High only). 0 = a perfectly still, sharp image; 1 = default.
var underwater_distortion := 1.0

## Multiplies every style's `caustics_strength` in the underwater view.
var underwater_caustics := 1.0

## Darkening of the corners of the underwater image, 0 = none.
var underwater_vignette := 0.22

## The sun for underwater caustics and light shafts. Leave empty to use the
## first visible DirectionalLight3D in the scene.
var sun_light: DirectionalLight3D

## The camera counts as "in the water" from this far above the surface, so
## the waterline can cross the screen before the eye itself goes under.
const UNDERWATER_MARGIN := 0.08
## The underwater pass runs while the eye is within this much of the drawn
## surface (above it) and decides pixel by pixel; covers the player ripples
## (at most 0.12 m) and the lens's near plane.
const UNDERWATER_REACH := 0.3

var _underwater_effect: UnderwaterEffect
var _underwater_was_active := false
var _underwater_time := 0.0
var _underwater_drift := Vector2.ZERO
var _sun_cache: DirectionalLight3D
var _sun_search_in := 0.0
var _default_style: WaterStyle
var _env_fog_backup := {}
var _env_fog_env: Environment


## True while the camera's eye is under the water surface as drawn.
func is_camera_underwater() -> bool:
	return _camera_under


var _camera_under := false


func _underwater_off() -> void:
	if _underwater_effect != null:
		_underwater_effect.active = false
	_underwater_was_active = false
	_camera_under = false
	_set_env_fog(null, false)


func _update_underwater(delta: float) -> void:
	_underwater_time = fmod(_underwater_time + delta, 3600.0)
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null or not underwater_enabled:
		_underwater_off()
		return
	var pos := cam.global_position
	var q := query(pos, _scratch_query)
	# The surface as drawn (waves included), not the baked mean level: the
	# two differ by a standing wave's height, and with the eye between them
	# the view was neither under water nor above it (the surface seen from
	# below, the sky through it, no fog).
	var height := drawn_height(pos, q)
	var flow := q.flow
	var under: bool = q.valid and pos.y < height + UNDERWATER_MARGIN
	# The pass runs from a little higher up: it finds the waterline pixel by
	# pixel (player ripples included), and a pass over a dry view only
	# returns early. Nothing is left to one height test at the eye.
	var near: bool = q.valid and pos.y < height + UNDERWATER_REACH
	_camera_under = under
	var style: WaterStyle = null
	if under and q.body != null and "style" in q.body:
		style = q.body.style
	if RenderingServer.get_rendering_device() == null:
		# Compatibility renderer: no compute pass, environment fog instead
		_set_env_fog(style, under and pos.y < height)
		_underwater_was_active = under
		return
	if _underwater_effect == null:
		_underwater_effect = UnderwaterEffect.new()
		_underwater_effect.set_noise_texture(noise_texture)
	if cam.compositor == null:
		cam.compositor = Compositor.new()
	if not cam.compositor.compositor_effects.has(_underwater_effect):
		var fx := cam.compositor.compositor_effects
		fx.append(_underwater_effect)
		cam.compositor.compositor_effects = fx
	if near and style == null and q.body != null and "style" in q.body:
		style = q.body.style
	_underwater_effect.active = near
	if near:
		_feed_underwater(pos, height, flow, style, delta)
	_underwater_was_active = near


## Turns the style of the water the camera is in into the effect's numbers.
func _feed_underwater(pos: Vector3, height: float, flow: Vector3, style: WaterStyle, delta: float) -> void:
	var fx := _underwater_effect
	var preset: Dictionary = PRESETS[quality]
	if style == null:
		if _default_style == null:
			_default_style = WaterStyle.new()
		style = _default_style

	# --- the water: the same Beer-Lambert model as the surface shader ------
	var turb := clampf(style.turbidity + storm_turbidity, 0.0, 1.0)
	var sed := (turb * turb * 7.0 + turb * 0.7) * style.underwater_fog_density
	var sed_color := style.sediment_color.lerp(storm_color,
		storm_turbidity / maxf(style.turbidity + storm_turbidity, 0.001))
	var absorb := Vector3(style.absorption.r, style.absorption.g, style.absorption.b) \
		* lerpf(4.0, 1.0, style.clarity) * style.underwater_fog_density
	var extinction := absorb + Vector3.ONE * sed
	# daylight on its way down is scattered as well as absorbed, and scattered
	# light still travels down: it fades more slowly than a single ray
	var downwelling := absorb * 0.8 + Vector3.ONE * sed * 0.12
	# what the fog looks like: the water's own colour, or the silt in it
	var mean_abs := (absorb.x + absorb.y + absorb.z) / 3.0
	# (silt in a thick medium never shows its full colour: light is absorbed
	# on the way in and out)
	var sed_share := pow(sed / maxf(sed + mean_abs, 0.001), 1.5)
	var water_color := style.scatter_color.lerp(sed_color * 0.6, sed_share)

	# --- the light ---------------------------------------------------------------
	var sun := _find_sun(delta)
	var to_sun := Vector3.UP
	var sun_color := Vector3.ZERO
	if sun != null:
		to_sun = sun.global_basis.z.normalized()
		var c := sun.light_color * sun.light_energy
		sun_color = Vector3(c.r, c.g, c.b) * smoothstep(-0.02, 0.1, to_sun.y)
	# Snell: the sun stands higher in the sky seen from under water
	var flat := Vector2(to_sun.x, to_sun.z) / 1.333
	var refracted := Vector3(flat.x, sqrt(maxf(1.0 - flat.length_squared(), 0.0)), flat.y)
	var daylight := sun_color * maxf(to_sun.y, 0.0) + Vector3(0.22, 0.26, 0.3)
	var fog := Vector3(water_color.r, water_color.g, water_color.b) * daylight

	# --- the surface above the camera: a plane with the river's slope -----------
	var grad := Vector2.ZERO
	# (both ends as drawn: the height here includes the wave under the eye)
	var hx := drawn_height(pos + Vector3(1.0, 0.0, 0.0))
	var hz := drawn_height(pos + Vector3(0.0, 0.0, 1.0))
	if not is_nan(hx):
		grad.x = clampf(hx - height, -0.15, 0.15)
	if not is_nan(hz):
		grad.y = clampf(hz - height, -0.15, 0.15)

	# crossing from one body into another fades, entering the water does not
	var k := 1.0 - exp(-delta * 5.0) if _underwater_was_active else 1.0
	fx.extinction = fx.extinction.lerp(extinction, k)
	fx.downwelling = fx.downwelling.lerp(downwelling, k)
	fx.fog_color = fx.fog_color.lerp(fog, k)
	fx.sediment = lerpf(fx.sediment, sed, k)
	fx.surface_gradient = fx.surface_gradient.lerp(grad, k)
	fx.surface_height = height
	fx.sun_direction = refracted
	fx.sun_color = sun_color
	fx.caustics_strength = style.caustics_strength * underwater_caustics
	fx.caustics_size = style.caustics_size
	fx.caustics_taps = 2 if preset["underwater_full"] else 1
	fx.shaft_strength = style.underwater_shafts
	fx.shaft_steps = preset["underwater_shafts"]
	fx.mote_density = clampf(style.underwater_particles * (0.1 + turb * 1.2), 0.0, 0.9)
	fx.mote_shells = preset["underwater_motes"]
	fx.distortion = underwater_distortion
	fx.vignette = underwater_vignette
	fx.full = preset["underwater_full"]
	# the light network and the particles ride on the current
	_underwater_drift -= Vector2(flow.x, flow.z) * delta * 0.5
	fx.drift = _underwater_drift
	fx.time = _underwater_time
	fx.ripple_rd = _ripples.output_rd_texture() if _ripples != null else RID()
	fx.ripple_rect = _ripples.world_rect() if _ripples != null else Vector4(0, 0, 1, 0)


func _find_sun(delta: float) -> DirectionalLight3D:
	if sun_light != null and is_instance_valid(sun_light):
		return sun_light
	if _sun_cache != null and is_instance_valid(_sun_cache) and _sun_cache.is_visible_in_tree():
		return _sun_cache
	_sun_cache = null
	_sun_search_in -= delta
	if _sun_search_in <= 0.0:
		_sun_search_in = 1.0
		for n in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
			if (n as DirectionalLight3D).is_visible_in_tree():
				_sun_cache = n
				break
	return _sun_cache


func _set_env_fog(style: WaterStyle, on: bool) -> void:
	var world := get_viewport().find_world_3d() if get_viewport() != null else null
	if world == null or world.environment == null:
		return
	var env := world.environment
	if on:
		if _env_fog_backup.is_empty() or _env_fog_env != env:
			_env_fog_env = env
			_env_fog_backup = {
				"enabled": env.fog_enabled, "color": env.fog_light_color,
				"density": env.fog_density, "sky": env.fog_sky_affect,
			}
		var scatter := style.scatter_color if style != null else Color(0.02, 0.1, 0.09)
		var clarity := style.clarity if style != null else 0.85
		var density := 1.0
		if style != null:
			var turb := clampf(style.turbidity + storm_turbidity, 0.0, 1.0)
			scatter = scatter.lerp(style.sediment_color, clampf(turb * 1.5, 0.0, 1.0))
			clarity = clarity * (1.0 - turb)
			density = style.underwater_fog_density
		env.fog_enabled = true
		env.fog_light_color = scatter
		env.fog_density = lerpf(0.35, 0.05, clarity) * density
		env.fog_sky_affect = 1.0
	elif not _env_fog_backup.is_empty() and _env_fog_env == env:
		env.fog_enabled = _env_fog_backup["enabled"]
		env.fog_light_color = _env_fog_backup["color"]
		env.fog_density = _env_fog_backup["density"]
		env.fog_sky_affect = _env_fog_backup["sky"]
		_env_fog_backup.clear()


# -------------------------------------------------------------- shader globals --

const SHADER_GLOBALS := {
	"flowing_water_noise": ["sampler2D", ""],
	"flowing_water_map": ["sampler2D", ""],
	"flowing_water_map_rect": ["vec4", Vector4(0, 0, 1, 0)],
	"flowing_water_map_base": ["float", 0.0],
	"flowing_water_map_focus": ["vec4", Vector4(0, 0, 1e6, 2e6)],
	"flowing_water_time": ["float", 0.0],
	"flowing_water_ripple": ["sampler2D", ""],
	"flowing_water_ripple_rect": ["vec4", Vector4(0, 0, 1, 0)],
	"flowing_water_caustics": ["float", 1.0],
	"flowing_water_turbidity": ["float", 0.0],
	"flowing_water_storm_color": ["vec3", Vector3(0.33, 0.24, 0.13)],
}


static func _register_shader_globals() -> void:
	for name in SHADER_GLOBALS:
		if ProjectSettings.has_setting("shader_globals/" + name):
			continue
		var existing := RenderingServer.global_shader_parameter_get_list()
		if name in existing:
			continue
		var type_str: String = SHADER_GLOBALS[name][0]
		var rs_type := RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D
		if type_str == "vec4":
			rs_type = RenderingServer.GLOBAL_VAR_TYPE_VEC4
		elif type_str == "float":
			rs_type = RenderingServer.GLOBAL_VAR_TYPE_FLOAT
		elif type_str == "vec3":
			rs_type = RenderingServer.GLOBAL_VAR_TYPE_VEC3
		RenderingServer.global_shader_parameter_add(name, rs_type, SHADER_GLOBALS[name][1])


# ---------------------------------------------------------------- noise texture --

func _load_or_make_noise() -> Texture2D:
	if ResourceLoader.exists(NOISE_PATH):
		var tex: Texture2D = load(NOISE_PATH)
		if tex != null:
			return tex
	var tex := WaterNoise.generate(256)
	if Engine.is_editor_hint():
		ResourceSaver.save(tex, NOISE_PATH)
	return tex
