// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Ready-made material for rocks and boulders: procedural stone with normal
// detail and moss, receiving the water (wet band + caustics) through
// water_receiver.gdshaderinc. Use it as-is, or copy the three receiver calls
// into your own shaders.
shader_type spatial;

#include "water_receiver.gdshaderinc"

uniform vec3 rock_dark : source_color = vec3(0.15, 0.15, 0.16);
uniform vec3 rock_light : source_color = vec3(0.47, 0.45, 0.42);
uniform vec3 moss_color : source_color = vec3(0.13, 0.20, 0.06);
uniform float moss_amount : hint_range(0.0, 1.0) = 0.6;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.82;
// The water surface already draws caustics on everything beneath it. Turn
// this on only if you run the Low preset (no depth buffer) and want them.
uniform bool material_caustics = false;

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying vec3 v_local_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_local_pos = VERTEX;
}

void fragment() {
	// triplanar-lite: blend a top and a side projection by the normal
	float top = smoothstep(0.35, 0.75, abs(v_world_normal.y));
	vec2 uv_top = v_world_pos.xz;
	vec2 uv_side = vec2(v_world_pos.x + v_world_pos.z, v_world_pos.y);
	vec4 n1 = mix(texture(flowing_water_noise, uv_side * 0.55), texture(flowing_water_noise, uv_top * 0.55), top);
	vec4 n2 = mix(texture(flowing_water_noise, uv_side * 2.4), texture(flowing_water_noise, uv_top * 2.4), top);
	float cracks = smoothstep(0.72, 0.98, n1.a);
	vec3 albedo = mix(rock_dark, rock_light, n1.b * 0.65 + n2.b * 0.35);
	albedo *= 1.0 - 0.45 * cracks;

	float w_depth;
	float h = water_surface_height_depth(v_world_pos, w_depth);
	float above = (h > -1e5) ? v_world_pos.y - h : 10.0;
	// moss above the splash zone, on up-facing faces
	float mossy = smoothstep(0.2, 0.5, above) * smoothstep(0.5, 0.85, v_world_normal.y + (n1.b - 0.5) * 0.5) * moss_amount;
	albedo = mix(albedo, moss_color * (0.7 + 0.6 * n2.b), mossy);
	albedo *= mix(vec3(1.0), vec3(0.72, 0.80, 0.66), (1.0 - smoothstep(-0.4, 0.0, above)) * step(0.02, w_depth));
	float wet = water_wet_band(v_world_pos, albedo);

	vec2 sl = (n1.rg - 0.5) * 1.1 + (n2.rg - 0.5) * 0.8;
	vec3 n = normalize(v_world_normal + (vec3(sl.x, 0.0, sl.y) * top + vec3(sl.x, sl.y, -sl.x) * (1.0 - top)) * mix(0.5, 0.25, wet));

	ALBEDO = albedo;
	AO = 1.0 - 0.4 * cracks;
	ROUGHNESS = mix(mix(base_roughness, 0.95, mossy), 0.36, wet);
	SPECULAR = mix(0.4, 0.3, wet);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	if (material_caustics) {
		EMISSION = albedo * water_caustics(v_world_pos, v_world_normal, TIME);
	}
}
