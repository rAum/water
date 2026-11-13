// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Shared helpers and uniforms for all flowing-water shaders.
// The baked textures store real units (see water_data.gd):
//   flow_tex: r = speed across (m/s), g = speed along, b = foam, a = depth (m)
//   aux_tex:  r = surface offset (m), g = aeration, b = wake, a = slope

// --- baked data -------------------------------------------------------------
uniform sampler2D flow_tex : filter_linear, repeat_disable;
uniform sampler2D aux_tex : filter_linear, repeat_disable;
// Tileable pattern: rg = slopes, b = height, a = ridged foam pattern.
// anisotropic: the surface is almost always seen at a grazing angle
uniform sampler2D noise_tex : filter_linear_mipmap_anisotropic, repeat_enable;

// Waterfall fluid texture: r = slope across, g = curtains, b = density,
// a = fibres. Long along the fall, narrow across it.
uniform sampler2D fall_tex : filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;

// Debug view: 0 final, 1 flow speed, 2 foam mask, 3 depth.
uniform int debug_view = 0;

// --- style (set from WaterStyle.apply_to_material) ---------------------------
uniform vec3 style_absorption = vec3(0.25, 0.06, 0.04);
uniform vec3 style_scatter_color = vec3(0.02, 0.10, 0.09);
uniform vec3 style_sediment_color = vec3(0.36, 0.29, 0.17);
uniform float style_turbidity = 0.0;
uniform float style_turbidity_variation = 0.35;
uniform float style_slicks = 0.0;
uniform float style_caustics = 1.0;
uniform float style_caustics_size = 1.4;
uniform float style_clarity = 0.85;
uniform float style_detail_rest = 0.35;
uniform float style_detail_speed = 1.0;
uniform float style_wave_height = 0.08;
uniform float style_refraction = 1.0;
uniform vec3 style_foam_color = vec3(0.93, 0.93, 0.91);
uniform float style_foam_amount = 1.0;
uniform float style_foam_water_tint = 0.6;
uniform float style_foam_softness = 0.12;
uniform float style_foam_tile = 2.0;
uniform float style_roughness = 0.08;
uniform float style_specular = 0.36;
uniform float style_color_bands = 0.0;
uniform float style_shoreline_width = 0.0;
uniform float style_sharp_highlights = 0.0;
uniform float style_use_depth_gradient = 0.0;
// still water (ponds, lakes): wind wavelets, shore lapping, inflow foam
uniform float style_wind_wave_height = 0.015;
uniform float style_wind_wave_detail = 1.0;
uniform float style_shore_foam = 0.5;
uniform float style_inflow_foam = 0.6;
uniform sampler2D style_depth_gradient : filter_linear, repeat_disable, hint_default_black;

// Second style + blend, used only in junction blend zones. The blend factor
// runs 0 -> 1 over [blend_start_m, blend_start_m + blend_len_m] of the
// downstream metric; blend_len_m == 0 disables it.
uniform float blend_start_m = 0.0;
uniform float blend_len_m = 0.0;
uniform vec3 style_b_absorption = vec3(0.25, 0.06, 0.04);
uniform vec3 style_b_scatter_color = vec3(0.02, 0.10, 0.09);
uniform vec3 style_b_sediment_color = vec3(0.36, 0.29, 0.17);
uniform float style_b_turbidity = 0.0;
uniform float style_b_turbidity_variation = 0.35;
uniform float style_b_slicks = 0.0;
uniform float style_b_caustics = 1.0;
uniform float style_b_caustics_size = 1.4;
uniform float style_b_clarity = 0.85;
uniform float style_b_detail_rest = 0.35;
uniform float style_b_detail_speed = 1.0;
uniform float style_b_wave_height = 0.08;
uniform float style_b_refraction = 1.0;
uniform vec3 style_b_foam_color = vec3(0.93, 0.93, 0.91);
uniform float style_b_foam_amount = 1.0;
uniform float style_b_foam_water_tint = 0.6;
uniform float style_b_foam_softness = 0.12;
uniform float style_b_foam_tile = 2.0;
uniform float style_b_roughness = 0.08;
uniform float style_b_specular = 0.36;
uniform float style_b_color_bands = 0.0;
uniform float style_b_shoreline_width = 0.0;
uniform float style_b_sharp_highlights = 0.0;
uniform float style_b_wind_wave_height = 0.015;
uniform float style_b_wind_wave_detail = 1.0;
uniform float style_b_shore_foam = 0.5;
uniform float style_b_inflow_foam = 0.6;

// --- body parameters ----------------------------------------------------------
// Wind ripples for still water (ponds); strength set by the pond / WindField.
uniform float wind_ripple_strength = 0.0;
uniform vec2 wind_dir = vec2(0.6, 0.8);
// Vertex waves fade out beyond this distance (quality preset).
uniform float vertex_wave_max_dist = 40.0;
// Lift applied in junction blend zones to avoid z-fighting (metres).
uniform float blend_lift = 0.0;
// Fade the whole surface out toward the end of the downstream metric
// (junction extension ribbons): 0 = never.
uniform float fade_out_start_m = 0.0;
uniform float fade_out_len_m = 0.0;
// Fade the surface in over the first metres of the downstream metric
// (rivers leaving a pond): 0 = off.
uniform float fade_in_len_m = 0.0;

// --- world ripple simulation (player interaction), published by WaterManager --
global uniform sampler2D flowing_water_ripple;
// xy = world origin of the ripple grid (min x, min z), z = world size,
// w = texels per side (0 = off)
global uniform vec4 flowing_water_ripple_rect;
// extra turbidity added to every style at runtime (rain, floods)
global uniform float flowing_water_turbidity;
global uniform vec3 flowing_water_storm_color;

// Bodies standing in a fall (WaterFallHits): a ring buffer across the
// ribbon (u) by time of flight; a cell written where a body meets the sheet
// rides down with the water and cuts a gap below the body.
uniform sampler2D fall_hit_tex : filter_linear, repeat_enable, hint_default_black;
uniform float fall_hit_on = 0.0;
uniform float fall_hit_head = 0.0;
uniform float fall_hit_rows = 64.0;
uniform float fall_hit_dt = 0.025;
uniform vec2 fall_hit_s = vec2(-1.0);

// fall texture units per second of the water's flight
#define FALL_TEX_RATE 0.6

// --- varyings -----------------------------------------------------------------
varying vec2 v_metric;      // metres: x across (river) / world x (pond), y downstream / world z
varying vec2 v_wave_slope;  // standing-wave slope contribution
varying vec3 v_world;       // world position of the displaced vertex
varying vec3 v_tan;         // world downstream tangent (includes slope)
varying vec3 v_side;        // world across direction (horizontal)
varying vec3 v_norm0;       // base surface normal
varying float v_fade;       // junction extension fade (1 = solid water)
varying float v_fall_t;     // 0 at a waterfall's lip .. 1 at its foot (0 off falls)
varying vec3 v_flight;
varying float v_plunge;
varying float v_wander;    // falls: sideways wander of a column (metres)    // 1 where a fall lands in the pool, fading downstream (CUSTOM0.w)     // falls: seconds since the lip, speed (m/s), metres fallen (CUSTOM0)
varying float v_shell;      // 1 = upper surface, 0 = lower surface of a falling sheet

const float WPI = 3.14159265;

// A negative blend_len_m reverses the blend (pond -> river junctions:
// style B at the start of the metric, fading out downstream).
float water_blend_w(float along_m) {
	return abs(blend_len_m) > 0.001 ? clamp((along_m - blend_start_m) / blend_len_m, 0.0, 1.0) : 0.0;
}

// Standing-wave height: sampled in metres, drifting at a slow constant speed,
// never with the flow, so humps stay over their rocks.
float wave_h(vec2 m, float t) {
	return textureLod(noise_tex, vec2(m.x * 0.22, m.y * 0.16 - t * 0.02), 0.0).b - 0.5;
}

// Three flow phases, weighted so they always sum to the same total:
// no pulsing, no popping. Never read one phase on its own.
vec4 flow_phases(vec2 uvm, vec2 flow, float scale, float period, float jit, float t) {
	vec4 acc = vec4(0.0);
	for (int k = 0; k < 3; k++) {
		float fk = float(k);
		float ph = fract(t / period + fk / 3.0 + jit);
		vec2 off = flow * (ph - 0.5) * period;
		float w = sin(WPI * ph);
		w *= w;
		acc += w * texture(noise_tex, (uvm - off) * scale + vec2(0.37, 0.11) * fk);
	}
	return acc / 1.5;
}

// Wind-driven wavelets on still water. Returns vec3(height, d/dx, d/dz) in
// world metres for a world (x, z) position. Short gravity waves travel at
// their own speed (deep-water dispersion), spread around the wind direction,
// with a warped phase so no wave train reads as a regular sine. `count`
// picks how many trains are summed (the swell first, then shorter ones):
// vertices take only the swell, which the pond mesh can resolve.
// Unscaled the trains have a wind-sea steepness (~0.1, swell about 0.1 m
// high); callers scale height and slope separately (WIND_WAVE_REF_H).
const float WIND_WAVE_REF_H = 0.096;
vec3 wind_waves(vec2 p, float t, vec2 wdir, int count) {
	vec2 d0 = normalize(wdir + vec2(1e-4, 0.0));
	// phase warp: slow, large-scale, so trains bend and break up
	vec2 warp = textureLod(noise_tex, p * 0.045 + t * d0 * 0.004, 0.0).rg - 0.5;
	vec3 acc = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= count) {
			break;
		}
		float fi = float(i);
		// wavelength (m), angle off the wind, steepness (amplitude * k)
		float lambda = 5.5 * pow(0.47, fi);
		float ang = (fi - 1.4) * 0.42;
		float steep = 0.11 - fi * 0.012;
		vec2 dir = vec2(d0.x * cos(ang) - d0.y * sin(ang), d0.x * sin(ang) + d0.y * cos(ang));
		float k = 2.0 * WPI / lambda;
		float omega = sqrt(9.81 * k);
		float a = steep / k;
		float ph = dot(dir, p) * k - omega * t + warp.x * (6.0 + fi * 3.0) + warp.y * 4.0 * fi;
		acc += vec3(a * sin(ph), a * k * cos(ph) * dir);
	}
	return acc;
}

vec3 speed_ramp(float t) {
	vec3 c = mix(vec3(0.05, 0.10, 0.35), vec3(0.05, 0.55, 0.60), smoothstep(0.0, 0.35, t));
	c = mix(c, vec3(0.95, 0.85, 0.25), smoothstep(0.35, 0.7, t));
	return mix(c, vec3(1.0, 0.98, 0.95), smoothstep(0.7, 1.0, t));
}

// Ripple height + slope from the player-centred simulation; returns
// vec3(height, slope_x, slope_z) in world axes, zero outside the grid.
// flowing_water_ripple_rect: xy = world origin, z = world size, w = texels
// per side (0 = simulation off).
vec3 ripple_sample(vec2 world_xz) {
	if (flowing_water_ripple_rect.w < 0.5) {
		return vec3(0.0);
	}
	vec2 uv = (world_xz - flowing_water_ripple_rect.xy) / flowing_water_ripple_rect.z;
	if (uv.x <= 0.01 || uv.y <= 0.01 || uv.x >= 0.99 || uv.y >= 0.99) {
		return vec3(0.0);
	}
	float e = 1.0 / flowing_water_ripple_rect.w;
	float texel_m = flowing_water_ripple_rect.z * e;
	float h = textureLod(flowing_water_ripple, uv, 0.0).r;
	float hx = textureLod(flowing_water_ripple, uv + vec2(e, 0.0), 0.0).r;
	float hz = textureLod(flowing_water_ripple, uv + vec2(0.0, e), 0.0).r;
	// fade toward the grid border so the hand-off is invisible
	float border = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float fade = smoothstep(0.01, 0.1, border);
	return vec3(h, (hx - h) / texel_m, (hz - h) / texel_m) * fade;
}
