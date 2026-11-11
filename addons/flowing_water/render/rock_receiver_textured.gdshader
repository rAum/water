// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Rock material for textured (UV-mapped, PBR) rocks that also receives the
// water: a dark, glossy wet band at the waterline and a slight algae tint
// below it, through water_receiver.gdshaderinc. Give it your rock's albedo,
// normal and roughness maps. (rock_receiver.gdshader is the fully
// procedural version for untextured meshes.)
shader_type spatial;

#include "water_receiver.gdshaderinc"

uniform sampler2D albedo_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_map : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 albedo = texture(albedo_map, UV).rgb * tint;
	float rough = texture(roughness_map, UV).g;
	float w_depth;
	float h = water_surface_height_depth(v_world_pos, w_depth);
	float above = (h > -1e5) ? v_world_pos.y - h : 10.0;
	albedo *= mix(vec3(1.0), vec3(0.72, 0.80, 0.66), (1.0 - smoothstep(-0.4, 0.0, above)) * step(0.02, w_depth));
	float wet = water_wet_band(v_world_pos, albedo);
	ALBEDO = albedo;
	ROUGHNESS = mix(rough, 0.34, wet);
	SPECULAR = 0.45;
	NORMAL_MAP = texture(normal_map, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength * mix(1.0, 0.6, wet);
}
