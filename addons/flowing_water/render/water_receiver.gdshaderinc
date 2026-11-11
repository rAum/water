// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Include this from your terrain and rock shaders to receive the water:
// caustics below the surface and a dark, glossy wet band up to 0.3 m above
// it. Reads the world water map that WaterManager publishes around the
// player (rg = flow encoded /16+0.5, b = (height-base)*0.5+2 on and beside
// the water, a = depth/8, 0 on land).
//
// Usage in a spatial shader's fragment():
//
//     #include "res://addons/flowing_water/render/water_receiver.gdshaderinc"
//     void fragment() {
//         vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
//         vec3 albedo = ...;
//         float wet = water_wet_band(world, albedo);     // darkens albedo
//         ROUGHNESS = mix(base_roughness, 0.08, wet);     // glossy when wet
//         vec3 n_world = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
//         ALBEDO = albedo;
//         EMISSION += albedo * water_caustics(world, n_world, TIME);
//     }

global uniform sampler2D flowing_water_map;
global uniform vec4 flowing_water_map_rect;   // xy origin, z size, w active
global uniform float flowing_water_map_base;
global uniform sampler2D flowing_water_noise : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform float flowing_water_caustics;

// Water surface height at a world position (on the water and on the banks
// right beside it); returns -1e6 when there is no water nearby.
// `depth` receives the water depth there (0 on land).
float water_surface_height_depth(vec3 world_pos, out float depth) {
	depth = 0.0;
	if (flowing_water_map_rect.w < 0.5) {
		return -1e6;
	}
	vec2 uv = (world_pos.xz - flowing_water_map_rect.xy) / flowing_water_map_rect.z;
	if (uv.x <= 0.0 || uv.y <= 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
		return -1e6;
	}
	vec4 m = texture(flowing_water_map, uv);
	// b holds the surface height on the water AND on the banks beside it
	// (so the wet band reaches onto land); 0 means no water nearby
	if (m.b <= 0.01) {
		return -1e6;
	}
	depth = m.a * 8.0;
	return (m.b - 2.0) * 2.0 + flowing_water_map_base;
}

float water_surface_height(vec3 world_pos) {
	float depth;
	return water_surface_height_depth(world_pos, depth);
}

// Darkens the albedo in the wet band (up to 0.3 m above the waterline) and
// under water; returns the wetness (use it to lower your roughness).
float water_wet_band(vec3 world_pos, inout vec3 albedo) {
	float depth;
	float h = water_surface_height_depth(world_pos, depth);
	if (h < -1e5) {
		return 0.0;
	}
	float above = world_pos.y - h;
	float wet = 1.0 - smoothstep(0.0, 0.3, above);
	// land that merely lies lower than nearby water (the foot of a
	// waterfall's cliff) is not wet: only a splash zone around the level
	if (depth <= 0.02) {
		wet *= smoothstep(-0.5, -0.1, above);
	}
	albedo *= mix(1.0, 0.5, wet);
	return wet;
}

// Additive caustics factor below the surface. Multiply by your albedo and
// add to EMISSION (or to your light response).
vec3 water_caustics(vec3 world_pos, vec3 normal_world, float t) {
	if (flowing_water_caustics <= 0.001) {
		return vec3(0.0);
	}
	float depth;
	float h = water_surface_height_depth(world_pos, depth);
	if (h < -1e5 || depth <= 0.02) {
		return vec3(0.0);
	}
	float above = world_pos.y - h;
	float under = 1.0 - smoothstep(-0.05, 0.0, above);
	if (under <= 0.001) {
		return vec3(0.0);
	}
	float c1 = texture(flowing_water_noise, world_pos.xz * 0.7 + t * vec2(0.03, 0.20)).a;
	float c2 = texture(flowing_water_noise, world_pos.xz * 0.9 - t * vec2(0.05, -0.13)).a;
	float caus = pow(clamp(min(c1, c2) * 1.7, 0.0, 1.0), 4.0) * 2.2 * under * exp(above * 0.8);
	caus *= max(normal_world.y, 0.0) * flowing_water_caustics;
	return vec3(1.0, 0.95, 0.85) * caus;
}
