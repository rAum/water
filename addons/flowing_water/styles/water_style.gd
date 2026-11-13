# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
class_name WaterStyle
extends Resource
## Everything about the look of one water body. Swapping a style never needs a
## re-bake: it only drives shader uniforms and picks the shader variant.

enum Variant { REALISTIC, STYLIZED }

## Which compiled shader variant this style uses. Bodies that blend at a
## junction must use the same variant.
@export var shader_variant: Variant = Variant.REALISTIC:
	set(v):
		shader_variant = v
		emit_changed()

@export_group("Colour")
## Light absorbed per metre of water, per channel. Higher = murkier.
@export var absorption: Color = Color(0.25, 0.06, 0.04):
	set(v):
		absorption = v
		emit_changed()
## Colour scattered back out of the water volume.
@export var scatter_color: Color = Color(0.02, 0.10, 0.09):
	set(v):
		scatter_color = v
		emit_changed()
## 1 = perfectly clear water, 0 = strongly tinted. Scales the absorption.
@export_range(0.0, 1.0) var clarity: float = 0.85:
	set(v):
		clarity = v
		emit_changed()

@export_group("Sediment")
## How much silt, mud or rock flour is suspended in the water. 0 = you see
## the bed as deep as the absorption allows; 0.5 = about half a metre of
## visibility (a lowland river); 1 = opaque (a flood). Unlike absorption,
## sediment scatters light back, so turbid water looks like a lit, coloured
## surface. Add `WaterManager.storm_turbidity` at runtime to muddy every
## river after rain.
@export_range(0.0, 1.0) var turbidity: float = 0.0:
	set(v):
		turbidity = v
		emit_changed()
## Colour of the suspended material: ochre/brown mud, grey-green silt,
## pale turquoise glacial flour.
@export var sediment_color: Color = Color(0.36, 0.29, 0.17):
	set(v):
		sediment_color = v
		emit_changed()
## Clouds of silt drifting with the current instead of an even tint.
@export_range(0.0, 1.0) var turbidity_variation: float = 0.35:
	set(v):
		turbidity_variation = v
		emit_changed()

@export_group("Caustics")
## Light patterns on the bed, drawn by the water surface itself from the
## depth buffer - they fall on any material under the water (terrain,
## rocks, a character's legs) with no setup. 0 = off. Sediment hides them
## automatically. (On the Low preset, which has no depth buffer, use
## `water_caustics()` from water_receiver.gdshaderinc in your materials.)
@export_range(0.0, 2.0) var caustics_strength: float = 1.0:
	set(v):
		caustics_strength = v
		emit_changed()
## Size of the pattern: metres per repeat of the light network.
@export_range(0.3, 6.0) var caustics_size: float = 1.4:
	set(v):
		caustics_size = v
		emit_changed()

@export_group("Underwater")
## How quickly things fade with distance when the camera is under water.
## 1 = the same absorption and sediment as seen from above; lower it to see
## further below the surface than the water's colour would allow.
@export_range(0.1, 4.0) var underwater_fog_density: float = 1.0:
	set(v):
		underwater_fog_density = v
		emit_changed()
## Strength of the sun shafts seen from below (Medium/High). Sediment makes
## them visible and, past a point, swallows them: muddy water has none.
@export_range(0.0, 3.0) var underwater_shafts: float = 1.0:
	set(v):
		underwater_shafts = v
		emit_changed()
## Amount of suspended particles drifting past the camera (Medium/High).
## Turbidity adds more on its own; 0 = none.
@export_range(0.0, 3.0) var underwater_particles: float = 1.0:
	set(v):
		underwater_particles = v
		emit_changed()

@export_group("Surface")
@export_range(0.0, 2.0) var detail_at_rest: float = 0.35:
	set(v):
		detail_at_rest = v
		emit_changed()
@export_range(0.0, 2.0) var detail_at_speed: float = 1.0:
	set(v):
		detail_at_speed = v
		emit_changed()
## Metres of standing-wave height at full strength.
@export_range(0.0, 0.3) var standing_wave_height: float = 0.08:
	set(v):
		standing_wave_height = v
		emit_changed()
## Smooth, glassy patches that drift with the current and break up the
## ripples - the boils and slicks of a slow, deep river.
@export_range(0.0, 1.0) var surface_slicks: float = 0.0:
	set(v):
		surface_slicks = v
		emit_changed()
@export_range(0.0, 2.0) var refraction_strength: float = 1.0:
	set(v):
		refraction_strength = v
		emit_changed()

@export_group("Foam")
## Colour of the bubbles themselves: keep it a near-neutral white. The water
## under and between the bubbles tints it (see foam_water_tint), and the scene
## lighting does the rest, so the same foam colour works for every water.
@export var foam_color: Color = Color(0.93, 0.93, 0.91):
	set(v):
		foam_color = v
		emit_changed()
## How much the water body colours its foam: 0 = foam_color as is, 1 = thin
## foam takes the full colour of light that has passed through the water (tea
## brown on peat water, ochre on mud, faint green on a clear stream).
@export_range(0.0, 1.0) var foam_water_tint: float = 0.6:
	set(v):
		foam_water_tint = v
		emit_changed()
@export_range(0.0, 1.6) var foam_amount: float = 1.0:
	set(v):
		foam_amount = v
		emit_changed()
## Softness of the threshold edge between foam and water.
@export_range(0.005, 0.4) var foam_softness: float = 0.12:
	set(v):
		foam_softness = v
		emit_changed()
## Optional replacement foam pattern (alpha channel is used). Empty = built-in.
@export var foam_texture: Texture2D:
	set(v):
		foam_texture = v
		emit_changed()
## Metres covered by one tile of the foam/detail pattern.
@export_range(0.5, 16.0) var foam_tile_size: float = 2.0:
	set(v):
		foam_tile_size = v
		emit_changed()

@export_group("Still water")
## Ponds and lakes (bodies with wind ripples): metres of wave height the wind
## raises at the body's default wind (WaterPond.wind_ripples = 0.4). Moves the
## vertices on Medium/High; 0 = a flat surface.
@export_range(0.0, 0.1) var wind_wave_height: float = 0.015:
	set(v):
		wind_wave_height = v
		emit_changed()
## Strength of the wind wavelets in the surface normal (the glitter and the
## broken reflections of a breezy lake). 0 = glassy.
@export_range(0.0, 2.0) var wind_wave_detail: float = 1.0:
	set(v):
		wind_wave_detail = v
		emit_changed()
## Foam left by small waves lapping along the shore of still water.
@export_range(0.0, 1.0) var shore_foam: float = 0.5:
	set(v):
		shore_foam = v
		emit_changed()
## Foam carried in by a river and drifting out over still water, thinning as
## the current slows.
@export_range(0.0, 1.0) var inflow_foam: float = 0.6:
	set(v):
		inflow_foam = v
		emit_changed()

@export_group("Light")
@export_range(0.0, 1.0) var roughness: float = 0.08:
	set(v):
		roughness = v
		emit_changed()
## Reflectance at normal incidence (Godot's specular: F0 = 0.16 * s^2).
## Water reflects about 2 % head-on, which is 0.35; grazing views reflect
## fully whatever this is. Higher values make shaded water mirror too much sky.
@export_range(0.0, 1.0) var specular: float = 0.36:
	set(v):
		specular = v
		emit_changed()
@export_group("Stylised")
## Number of depth-colour bands. 0 = smooth gradient (realistic).
@export_range(0, 8) var color_bands: int = 0:
	set(v):
		color_bands = v
		emit_changed()
@export var hard_foam_edge: bool = false:
	set(v):
		hard_foam_edge = v
		emit_changed()
## Width in metres of the foam line along shores and around rocks (0 = off).
@export_range(0.0, 2.0) var shoreline_width: float = 0.0:
	set(v):
		shoreline_width = v
		emit_changed()
@export var sharp_highlights: bool = false:
	set(v):
		sharp_highlights = v
		emit_changed()
## Optional gradient texture for depth colour (sampled by depth).
@export var depth_gradient: Texture2D:
	set(v):
		depth_gradient = v
		emit_changed()


## Writes every style parameter into a ShaderMaterial, with an optional prefix
## ("style_b_" for the second style of a junction blend).
func apply_to_material(mat: ShaderMaterial, prefix: String = "style_") -> void:
	mat.set_shader_parameter(prefix + "absorption", Vector3(absorption.r, absorption.g, absorption.b))
	mat.set_shader_parameter(prefix + "scatter_color", Vector3(scatter_color.r, scatter_color.g, scatter_color.b))
	mat.set_shader_parameter(prefix + "sediment_color", Vector3(sediment_color.r, sediment_color.g, sediment_color.b))
	mat.set_shader_parameter(prefix + "turbidity", turbidity)
	mat.set_shader_parameter(prefix + "turbidity_variation", turbidity_variation)
	mat.set_shader_parameter(prefix + "slicks", surface_slicks)
	mat.set_shader_parameter(prefix + "caustics", caustics_strength)
	mat.set_shader_parameter(prefix + "caustics_size", caustics_size)
	mat.set_shader_parameter(prefix + "clarity", clarity)
	mat.set_shader_parameter(prefix + "detail_rest", detail_at_rest)
	mat.set_shader_parameter(prefix + "detail_speed", detail_at_speed)
	mat.set_shader_parameter(prefix + "wave_height", standing_wave_height)
	mat.set_shader_parameter(prefix + "refraction", refraction_strength)
	mat.set_shader_parameter(prefix + "foam_color", Vector3(foam_color.r, foam_color.g, foam_color.b))
	mat.set_shader_parameter(prefix + "foam_amount", foam_amount)
	mat.set_shader_parameter(prefix + "foam_water_tint", foam_water_tint)
	mat.set_shader_parameter(prefix + "wind_wave_height", wind_wave_height)
	mat.set_shader_parameter(prefix + "wind_wave_detail", wind_wave_detail)
	mat.set_shader_parameter(prefix + "shore_foam", shore_foam)
	mat.set_shader_parameter(prefix + "inflow_foam", inflow_foam)
	mat.set_shader_parameter(prefix + "foam_softness", 0.02 if hard_foam_edge else foam_softness)
	mat.set_shader_parameter(prefix + "foam_tile", foam_tile_size)
	mat.set_shader_parameter(prefix + "roughness", roughness)
	mat.set_shader_parameter(prefix + "specular", specular)
	mat.set_shader_parameter(prefix + "color_bands", float(color_bands))
	mat.set_shader_parameter(prefix + "shoreline_width", shoreline_width)
	mat.set_shader_parameter(prefix + "sharp_highlights", 1.0 if sharp_highlights else 0.0)
	if depth_gradient != null:
		mat.set_shader_parameter(prefix + "use_depth_gradient", 1.0)
		mat.set_shader_parameter(prefix + "depth_gradient", depth_gradient)
	else:
		mat.set_shader_parameter(prefix + "use_depth_gradient", 0.0)
	if foam_texture != null:
		mat.set_shader_parameter("foam_texture_override", foam_texture)
