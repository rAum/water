// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Example terrain: meadow, forest soil, pebble bars (or silt banks) and rock
// faces from Poly Haven PBR textures, blended by a baked vertex mask and
// the slope. COLOR.r = bar weight near water, COLOR.g = 1 for silt banks
// instead of pebbles, COLOR.b = forest-floor weight away from the water.
// It receives the water through water_receiver.gdshaderinc - the same
// include you add to your own terrain shaders for wet banks.
shader_type spatial;

#include "res://addons/flowing_water/render/water_receiver.gdshaderinc"

uniform sampler2D meadow_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bar_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bar_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bar_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D silt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D silt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 v_wp;
varying vec3 v_wn;
varying vec3 v_mask;

void vertex() {
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_mask = COLOR.rgb;
}

// Two scales of the same texture, mixed by slow noise: hides the repeat.
vec3 untiled(sampler2D tex, vec2 uv, float big, float mixer) {
	vec3 a = texture(tex, uv).rgb;
	vec3 b = texture(tex, uv * big + vec2(0.37, 0.61)).rgb;
	return mix(a, b, mixer);
}

void fragment() {
	vec4 nz_l = texture(flowing_water_noise, v_wp.xz * 0.021);
	vec4 nz_m = texture(flowing_water_noise, v_wp.xz * 0.17);
	float mixer = smoothstep(0.35, 0.65, nz_l.b);

	// --- layers -----------------------------------------------------------------
	vec2 uv_meadow = v_wp.xz / 2.6;
	vec2 uv_soil = v_wp.xz / 2.4;
	vec2 uv_bar = v_wp.xz / 1.7;
	vec3 meadow = untiled(meadow_albedo, uv_meadow, 0.31, mixer * 0.6);
	// meadows are not one green: slow patches of lusher and drier grass
	meadow *= mix(vec3(0.82, 0.95, 0.72), vec3(1.08, 1.0, 0.86), nz_m.b);
	vec3 soil = texture(soil_albedo, uv_soil).rgb;
	vec3 pebbles = untiled(bar_albedo, uv_bar, 0.37, mixer * 0.5);
	vec3 silt = texture(silt_albedo, v_wp.xz / 2.2).rgb * vec3(0.78, 0.74, 0.66);
	vec3 bar = mix(pebbles, silt, v_mask.g);

	// rock faces: projected from the side so they do not stretch
	float steep = 1.0 - smoothstep(0.55, 0.78, v_wn.y + (nz_m.b - 0.5) * 0.12);
	vec3 side_w = abs(v_wn);
	vec2 uv_rock = (side_w.x > side_w.z ? v_wp.zy : v_wp.xy) / 3.2;
	vec3 rock = texture(rock_albedo, uv_rock).rgb;

	float bar_w = smoothstep(0.35, 0.6, v_mask.r + (nz_m.b - 0.5) * 0.4);
	float forest_w = smoothstep(0.3, 0.7, v_mask.b + (nz_l.b - 0.5) * 0.6) * (1.0 - bar_w);

	vec3 albedo = mix(meadow, soil, forest_w);
	// a strip of bare soil between the grass and the bar
	albedo = mix(albedo, soil * 0.9, smoothstep(0.12, 0.35, v_mask.r) * (1.0 - bar_w) * 0.8);
	albedo = mix(albedo, bar, bar_w);
	albedo = mix(albedo, rock, steep);

	// --- normals and roughness ---------------------------------------------------
	vec3 nm = texture(meadow_normal, uv_meadow).rgb;
	nm = mix(nm, texture(soil_normal, uv_soil).rgb, forest_w);
	nm = mix(nm, mix(texture(bar_normal, uv_bar).rgb, texture(silt_normal, v_wp.xz / 2.2).rgb, v_mask.g), bar_w);
	vec2 nxy = (nm.xy * 2.0 - 1.0) * 1.2;
	vec3 n = normalize(v_wn + vec3(nxy.x, 0.0, -nxy.y) * (1.0 - steep));
	vec2 rxy = texture(rock_normal, uv_rock).rg * 2.0 - 1.0;
	// side projection: perturb along the face's own axes
	vec3 face_t = normalize(cross(vec3(0.0, 1.0, 0.0), v_wn) + vec3(1e-4, 0.0, 0.0));
	vec3 face_b = cross(v_wn, face_t);
	n = normalize(n + (face_t * rxy.x + face_b * rxy.y) * steep * 1.1);

	float rough = texture(meadow_rough, uv_meadow).g;
	rough = mix(rough, 0.95, forest_w);
	rough = mix(rough, mix(texture(bar_rough, uv_bar).g, 0.9, v_mask.g), bar_w);
	rough = mix(rough, texture(rock_rough, uv_rock).g, steep);

	// --- water: algae tint below the surface, wet band at the waterline ----------
	float w_depth;
	float h = water_surface_height_depth(v_wp, w_depth);
	float above = (h > -1e5) ? v_wp.y - h : 3.0;
	albedo *= mix(vec3(1.0), vec3(0.72, 0.80, 0.66), (1.0 - smoothstep(-0.4, 0.0, above)) * step(0.02, w_depth));
	float wet = water_wet_band(v_wp, albedo);

	ALBEDO = albedo;
	ROUGHNESS = mix(rough, 0.38, wet);
	SPECULAR = 0.4;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
