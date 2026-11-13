// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// The one surface shader body for every water body: rivers, streams,
// waterfalls and ponds. Variant .gdshader files #define the feature set and
// include this file, so each quality level compiles only what it uses:
//
//   DETAIL_LAYERS 1|2      detail/foam noise layers (3 texture reads each)
//   USE_SCREEN_TEXTURE     transmitted scene colour (refraction target)
//   REFRACTION_FULL        screen-UV offset + depth check against smearing
//   REFRACTION_SIMPLE      screen-UV offset, no depth check
//   USE_DEPTH_BUFFER       water thickness from the depth buffer
//   STYLIZED               banded colour, hard foam, shoreline lines
//   VERTEX_WAVES           standing waves + ripples displace vertices
//   SSR                    screen-space reflections of banks, rocks, trees
//
// Mesh contract (built by water_river.gd / water_pond.gd):
//   UV      = baked-grid uv for flow_tex / aux_tex
//   UV2     = metres: (across, downstream) for rivers, world (x, z) for ponds
//   NORMAL  = base surface normal, TANGENT = downstream direction
//   COLOR.r = junction fade (1 = solid), COLOR.g = blend-lift mask,
//   COLOR.b = waterfall progress (0 lip .. 1 foot),
//   COLOR.a = 1 on the upper surface, 0 on the lower surface of a fall
//   CUSTOM0 = falls only: (seconds since the lip, speed m/s, metres fallen,
//             plunge: 1 where the fall lands, fading downstream)

#include "water_common.gdshaderinc"

// Every animation of the surface runs on the manager's clock, not on the
// engine's TIME: the CPU then knows exactly which wave is under the camera
// (WaterRiver/WaterPond.drawn_height), and the underwater view switches on
// at the surface as drawn, waves and all, not at the baked mean level.
global uniform float flowing_water_time;
#define TIME flowing_water_time

#ifdef USE_SCREEN_TEXTURE
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
#endif
#ifdef USE_DEPTH_BUFFER
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
#endif

#ifdef SSR
// Screen-space reflection: march the reflected ray through the depth buffer
// and return the scene colour it hits (a = hit strength). Cheap and short:
// it mirrors banks, rocks and trees in calm water; the sky comes from the
// engine's own reflection.
vec4 water_ssr(vec3 view_pos, vec3 view_normal, vec3 geo_normal, mat4 proj, mat4 inv_proj) {
	vec3 dir = reflect(normalize(view_pos), view_normal);
	// seen at a grazing angle, a rippled normal can send the reflected ray
	// under the water, where it would find the bed: light cannot go there
	float up = dot(dir, geo_normal);
	if (up < 0.03) {
		dir = normalize(dir + geo_normal * (0.03 - up));
	}
	if (dir.z > -0.02 && dir.y < 0.0) {
		return vec4(0.0);
	}
	float step_len = 0.35;
	vec3 p = view_pos + dir * 0.15;
	int shortened = 0;
	int refines = 0;
	for (int i = 0; i < 23; i++) {
		vec3 prev = p;
		vec3 q = p + dir * step_len;
		vec4 clip = proj * vec4(q, 1.0);
		vec2 uv = clip.xy / max(clip.w, 1e-5) * 0.5 + 0.5;
		if (clip.w <= 0.0 || uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
			// The steps grow fast: one can leap from below a far bank or
			// rock straight off the screen and skip it. Then the pixel next
			// to one that hit the bank showed the sky, and the mirror image
			// ended in a hard edge that slid across the water as the camera
			// moved. Shorten the step and follow the ray up to the edge.
			if (shortened < 5) {
				shortened++;
				step_len *= 0.5;
				continue;
			}
			break;
		}
		p = q;
		step_len *= 1.32;
		float raw = texture(depth_tex, uv).x;
		vec4 sp = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
		float scene_z = -sp.z / sp.w;
		float ray_z = -p.z;
		if (ray_z > scene_z && refines < 3) {
			refines++;
			// the steps are long: close in on the crossing, or a ray that
			// skims the surface lands a step late and smears its image
			// into streaks
			vec3 lo = prev;
			vec3 hi = p;
			for (int r = 0; r < 5; r++) {
				vec3 mid = (lo + hi) * 0.5;
				vec4 mc = proj * vec4(mid, 1.0);
				vec2 muv = mc.xy / mc.w * 0.5 + 0.5;
				vec4 ms = inv_proj * vec4(muv * 2.0 - 1.0, texture(depth_tex, muv).x, 1.0);
				if (-mid.z > -ms.z / ms.w) {
					hi = mid;
				} else {
					lo = mid;
				}
			}
			vec4 hc = proj * vec4(hi, 1.0);
			uv = hc.xy / hc.w * 0.5 + 0.5;
			// A ray that really meets a surface ends just behind it once
			// refined; one that passes behind a rock or bank stays far
			// behind it (the depth jumps at the silhouette). Those used to
			// count as hits (the tolerance grew with the step, to metres)
			// and painted grey blobs of the rock where the sky belongs.
			vec4 hs = inv_proj * vec4(uv * 2.0 - 1.0, texture(depth_tex, uv).x, 1.0);
			float behind = -hi.z - (-hs.z / hs.w);
			float tol = length(hi - lo) * 2.0 + 0.15 + 0.01 * -hi.z;
			float solid = 1.0 - smoothstep(tol, tol * 2.0, behind);
			if (solid > 0.0) {
				vec2 e = smoothstep(vec2(0.0), vec2(0.08), uv) * (1.0 - smoothstep(vec2(0.92), vec2(1.0), uv));
				return vec4(textureLod(screen_tex, uv, 0.0).rgb, e.x * e.y * solid);
			}
		}
	}
	return vec4(0.0);
}

// The mirror seen from under water (total internal reflection): the same
// march with short, fine steps and a refinement, because the bed is close
// and its image fills the view. Slightly blurred: the surface is never flat.
vec4 water_mirror_below(vec3 view_pos, vec3 view_normal, mat4 proj, mat4 inv_proj, float jitter) {
	vec3 dir = reflect(normalize(view_pos), view_normal);
	float step_len = 0.12;
	vec3 p = view_pos + dir * (0.04 + step_len * jitter);
	for (int i = 0; i < 20; i++) {
		vec3 prev = p;
		p += dir * step_len;
		vec4 clip = proj * vec4(p, 1.0);
		if (clip.w <= 0.0) {
			break;
		}
		vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
			break;
		}
		vec4 sp = inv_proj * vec4(uv * 2.0 - 1.0, texture(depth_tex, uv).x, 1.0);
		float scene_z = -sp.z / sp.w;
		if (-p.z > scene_z) {
			if (-p.z > scene_z + step_len * 2.0 + 0.3) {
				return vec4(0.0);    // passed behind something: no image
			}
			vec3 a = prev;
			vec3 b = p;
			for (int k = 0; k < 4; k++) {
				vec3 m = (a + b) * 0.5;
				vec4 mc = proj * vec4(m, 1.0);
				vec2 muv = mc.xy / mc.w * 0.5 + 0.5;
				vec4 ms = inv_proj * vec4(muv * 2.0 - 1.0, texture(depth_tex, muv).x, 1.0);
				if (-m.z > -ms.z / ms.w) {
					b = m;
				} else {
					a = m;
				}
			}
			vec4 bc = proj * vec4(b, 1.0);
			vec2 buv = bc.xy / bc.w * 0.5 + 0.5;
			vec2 e = smoothstep(vec2(0.0), vec2(0.06), buv) * (1.0 - smoothstep(vec2(0.94), vec2(1.0), buv));
			return vec4(textureLod(screen_tex, buv, 1.5).rgb, e.x * e.y);
		}
		step_len *= 1.2;
	}
	return vec4(0.0);
}
#endif

void vertex() {
	v_metric = UV2;
	v_fade = COLOR.r;
	v_fall_t = COLOR.b;
	v_shell = COLOR.a;
	v_flight = CUSTOM0.xyz;
	v_plunge = CUSTOM0.w;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_tan = normalize((MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz);
	v_norm0 = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_side = normalize(cross(v_tan, v_norm0));

	vec4 fl = textureLod(flow_tex, UV, 0.0);
	vec4 ax = textureLod(aux_tex, UV, 0.0);
	float speed = length(fl.rg);
	float depth = fl.a;
	float fall = smoothstep(0.3, 0.7, ax.a);
	float shore = smoothstep(0.02, 0.2, depth);
	float blend_w = water_blend_w(v_metric.y);
	float wave_amp_style = mix(style_wave_height, style_b_wave_height, blend_w);

	v_wave_slope = vec2(0.0);
	float dist = length(wp - (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	float dist_fade = 1.0 - smoothstep(vertex_wave_max_dist * 0.6, vertex_wave_max_dist, dist);
#ifdef VERTEX_WAVES
	// Standing waves: big shapes that stay over their rocks. They drift at a
	// slow constant speed, not with the flow.
	float amp = wave_amp_style * (0.3 + 1.2 * fl.b) * clamp(speed / 2.0, 0.0, 1.3) * (1.0 - fall) * shore;
	amp *= (0.85 + 0.15 * sin(TIME * 1.7 + v_metric.y * 2.0)) * dist_fade;
	float h0 = wave_h(v_metric, TIME);
	float e = 0.15;
	v_wave_slope = vec2(
		wave_h(v_metric + vec2(e, 0.0), TIME) - h0,
		wave_h(v_metric + vec2(0.0, e), TIME) - h0) / e * 2.0 * amp;
	// (COLOR.g: a river over a pond junction rides at the pond's level, so
	// its own offset and waves give way there - see water_junction.gd)
	float lift = (ax.r * (1.0 - fall) + h0 * 2.0 * amp + 0.02 * fl.b) * shore * (1.0 - COLOR.g);
	// player ripples displace vertices near the camera (a ripple never
	// opens the water down to the bed: at most a third of the depth)
	vec3 rip = ripple_sample(wp.xz);
	lift += clamp(rip.x, -depth * 0.33, depth * 0.33) * shore * dist_fade;
	// still water: the wind's swell rocks the surface (only the longest
	// train - the pond mesh is about a metre between vertices)
	if (wind_ripple_strength > 0.001) {
		float ww_h = mix(style_wind_wave_height, style_b_wind_wave_height, blend_w);
		float calm = 1.0 - clamp(speed / 0.6, 0.0, 1.0);
		float wh = wind_waves(wp.xz, TIME, wind_dir, 1).x / WIND_WAVE_REF_H;
		lift += wh * ww_h * (wind_ripple_strength / 0.4) * calm * shore * dist_fade
			* smoothstep(0.1, 0.5, depth);
	}
#else
	float lift = ax.r * (1.0 - fall) * shore * (1.0 - COLOR.g);
#endif
	// a falling sheet is never still: it billows, more the further it has
	// fallen, and its two surfaces move independently so its thickness varies
	if (COLOR.b > 0.001) {
		float ft_v = (CUSTOM0.x - TIME) * FALL_TEX_RATE;
		float wob = textureLod(fall_tex, vec2(UV2.x * 0.21 + (1.0 - COLOR.a) * 0.41, ft_v * 0.3), 0.0).g - 0.5;
		lift += wob * 0.2 * pow(COLOR.b, 1.3);
	}
	// columns of a falling sheet wander apart the longer they fly (low
	// frequency: read once per vertex, not per pixel)
	v_wander = 0.0;
	if (CUSTOM0.x > 0.0) {
		float ft_w = (CUSTOM0.x - TIME * (1.0 - 0.08 * (1.0 - COLOR.a))) * FALL_TEX_RATE;
		float drift = textureLod(fall_tex, vec2(UV2.x * 0.07 + 0.31, ft_w * 0.21), 0.0).g - 0.5;
		v_wander = drift * 1.1 * CUSTOM0.x * CUSTOM0.x;
	}
	// the pool heaves where a fall lands in it
	if (CUSTOM0.w > 0.001 && COLOR.b < 0.001) {
		float hv = textureLod(fall_tex, UV2 * vec2(0.23, 0.19) + vec2(0.0, -TIME * 0.13), 0.0).g - 0.5;
		lift += hv * 0.08 * CUSTOM0.w;
	}
	// world-space displacement back to object space: water nodes are rigid
	// (never non-uniformly scaled), so the inverse rotation is the transpose
	// (the lower surface of a falling sheet carries the opposite normal but
	// must move the same way as the upper one, or it would rise through it
	// wherever the surface is drawn down)
	vec3 disp = v_norm0 * (COLOR.a > 0.5 ? lift : -lift) + vec3(0.0, blend_lift * COLOR.g, 0.0);
	v_world = wp + disp;
	VERTEX += transpose(mat3(MODEL_MATRIX)) * disp;
}

void fragment() {
	vec4 fl = texture(flow_tex, UV);
	vec4 ax = texture(aux_tex, UV);
	vec2 flow = fl.rg;
	float speed = length(flow);
	float mask = fl.b;
	float baked_depth = fl.a;
	float aer = ax.g;
	float fall = smoothstep(0.3, 0.7, ax.a);

	float blend_w = water_blend_w(v_metric.y);
	vec3 s_absorption = mix(style_absorption, style_b_absorption, blend_w);
	vec3 s_scatter = mix(style_scatter_color, style_b_scatter_color, blend_w);
	vec3 s_sediment = mix(style_sediment_color, style_b_sediment_color, blend_w);
	float s_turbidity = mix(style_turbidity, style_b_turbidity, blend_w);
	float s_turb_var = mix(style_turbidity_variation, style_b_turbidity_variation, blend_w);
	float s_slicks = mix(style_slicks, style_b_slicks, blend_w);
	float s_caustics = mix(style_caustics, style_b_caustics, blend_w);
	float s_caustics_size = mix(style_caustics_size, style_b_caustics_size, blend_w);
	float s_clarity = mix(style_clarity, style_b_clarity, blend_w);
	float s_detail_rest = mix(style_detail_rest, style_b_detail_rest, blend_w);
	float s_detail_speed = mix(style_detail_speed, style_b_detail_speed, blend_w);
	float s_refraction = mix(style_refraction, style_b_refraction, blend_w);
	vec3 s_foam_color = mix(style_foam_color, style_b_foam_color, blend_w);
	float s_foam_amount = mix(style_foam_amount, style_b_foam_amount, blend_w);
	float s_foam_soft = mix(style_foam_softness, style_b_foam_softness, blend_w);
	float s_foam_tile = mix(style_foam_tile, style_b_foam_tile, blend_w);
	float s_roughness = mix(style_roughness, style_b_roughness, blend_w);
	float s_specular = mix(style_specular, style_b_specular, blend_w);
	float s_bands = mix(style_color_bands, style_b_color_bands, blend_w);
	float s_shoreline = mix(style_shoreline_width, style_b_shoreline_width, blend_w);
	float s_sharp = mix(style_sharp_highlights, style_b_sharp_highlights, blend_w);
	float s_foam_tint = mix(style_foam_water_tint, style_b_foam_water_tint, blend_w);
	float s_ww_detail = mix(style_wind_wave_detail, style_b_wind_wave_detail, blend_w);
	float s_shore_foam = mix(style_shore_foam, style_b_shore_foam, blend_w);
	float s_inflow_foam = mix(style_inflow_foam, style_b_inflow_foam, blend_w);
	// still water (a pond or lake: a body with wind ripples), and how calm it is here
	bool lake = wind_ripple_strength > 0.001;
	float still = 1.0 - clamp(speed / 0.5, 0.0, 1.0);

	// --- detail noise: three-phase flow sampling, per-pixel phase jitter ------
	float tile = 2.0 / max(s_foam_tile, 0.25);
	// phase jitter must vary slowly: fine variation would shear the pattern
	// along the flow and smear fast water into streaks
	float jit = textureLod(noise_tex, v_metric * 0.031, 4.0).b * 2.0;
	// fast water stretches along the flow (the downstream metric axis)
	vec2 st = vec2(1.0, mix(1.0, 0.6, clamp(abs(flow.y) / 4.0, 0.0, 1.0)) * mix(1.0, 0.6, clamp((abs(flow.y) - 4.0) / 3.0, 0.0, 1.0)));
	vec2 uvm = v_metric * st;
	vec2 flow_m = flow * st;
	// on still water the wind drives a slow surface drift (a few percent of
	// the wind speed): the lace and the ripples are never frozen in place
	if (lake) {
		flow_m += wind_dir * 0.06 * still;
	}
#if DETAIL_LAYERS >= 2
	vec4 d1 = flow_phases(uvm, flow_m, 0.5 * tile, 1.2, jit, TIME);
	vec4 d2 = flow_phases(uvm, flow_m, 2.3 * tile, 0.45, jit + 0.5, TIME);
	float pattern = d1.a * 0.62 + d2.a * 0.38;
	vec2 detail_slope = (d1.rg - 0.5) * 0.7 + (d2.rg - 0.5) * 0.5;
#else
	vec4 d1 = flow_phases(uvm, flow_m, 0.9 * tile, 0.8, jit, TIME);
	float pattern = d1.a;
	vec2 detail_slope = (d1.rg - 0.5) * 1.0;
#endif
#ifdef FOAM_DETAIL
	// close-range bubble structure: a third, fine layer that only exists
	// where it can be seen
	float near_w = 1.0 - smoothstep(6.0, 14.0, length(v_world - (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz));
	float fine = 0.5;
	if (near_w > 0.01 && mask > 0.1) {
		vec4 d3 = flow_phases(uvm, flow_m, 4.7 * tile, 0.3, jit + 0.25, TIME);
		// blending three phases flattens contrast: restore it
		fine = mix(0.5, clamp((d3.a - 0.4) * 3.2 + 0.5, 0.0, 1.0), near_w);
		pattern = mix(pattern, pattern * 0.72 + d3.a * 0.28, near_w);
		detail_slope += (d3.rg - 0.5) * 0.35 * near_w;
	}
#else
	float fine = 0.5;
#endif

	// --- white water: the baked mask is a threshold on the moving lace -------
	// coverage curve: thin lace at low mask, closed white only near 1
	float cover = clamp(pow(max(mask - 0.16, 0.0) / 0.84, 2.1) * s_foam_amount, 0.0, 1.0);
	// only the very whitest water (falls, plunge pools) closes completely;
	// streaks and wakes always keep gaps where the water shows through
	cover *= mix(0.74, 1.0, smoothstep(0.9, 1.0, mask));
	// The tongue: where the bed steepens toward a lip the water accelerates
	// and smooths out into a clear, glassy sheet - it does not break into
	// white until it is in the air (the fall itself whitens it below). The
	// bake marks the approach as white water; only a few torn streaks of
	// that survive on the tongue.
	// (it carries on over the brink: the first stretch of the drop is still
	// the clear tongue, the sheet whitens as it takes in air further down)
	float tongue = v_fall_t > 0.001
		? 1.0 - smoothstep(0.04, 0.5, v_fall_t)
		: smoothstep(0.07, 0.22, ax.a) * (1.0 - smoothstep(0.3, 0.6, ax.a));
	cover *= mix(1.0, 0.12, tongue);
	// and no bubbles in it yet: the glassy tongue is see-through
	aer *= 1.0 - 0.85 * tongue;
	// Plunge pool: where a fall lands the water is beaten into a boiling
	// mat of white that breaks into lace as it drifts away - the bake's
	// foam only starts downstream, but the churn is right under the sheet.
	if (v_plunge > 0.001) {
		float boil_n = texture(fall_tex, v_metric * vec2(0.31, 0.27) + vec2(0.0, -TIME * 0.17)).g;
		cover = max(cover, clamp(v_plunge * (0.75 + 0.6 * boil_n), 0.0, 1.0));
		aer = max(aer, v_plunge);
	}
	float foam = smoothstep(1.0 - cover - s_foam_soft, 1.0 - cover + s_foam_soft, pattern)
		* step(0.001, cover);
	// no painted line along the banks: foam needs a little water under it
	foam *= smoothstep(0.03, 0.14, baked_depth);
	// --- still water: foam lapping at the shore, foam carried in by a river ---
	if (lake) {
		// small waves run up the shore and leave a fringe of lace at the
		// waterline that swells and recedes as each one arrives; the phase
		// wanders along the shore so the whole edge never pulses together
		float lap_ph = textureLod(noise_tex, v_world.xz * 0.09 + TIME * wind_dir * 0.01, 0.0).b;
		float lap = 0.5 + 0.5 * sin(TIME * 1.1 + lap_ph * 14.0);
		float reach = mix(0.07, 0.2, lap * lap);
		float fringe = (1.0 - smoothstep(reach * 0.3, reach, baked_depth)) * mix(0.6, 1.0, lap);
		// a second, older line left further out by the wave before, breaking up
		float trail = (1.0 - smoothstep(0.03, 0.06, abs(baked_depth - reach * 1.6))) * 0.55 * (1.0 - lap);
		float lake_cover = max(fringe, trail) * s_shore_foam * 1.25 * mix(0.4, 1.0, still);
		// foam a river brings in drifts out with its current in loose rafts
		// and streaks, thinning as the water slows
		float drift = smoothstep(0.01, 0.2, speed + ax.g * 0.3) * smoothstep(0.3, 0.7, d1.b + 0.12);
		lake_cover = max(lake_cover, (drift * 0.7 + mask * 0.5) * s_inflow_foam);
		// still water does not stretch the lace: the blended phases are flat,
		// so restore contrast (and the fine bubble grain where there is one)
		float lace = clamp((pattern - 0.5) * 2.4 + 0.5, 0.0, 1.0);
		lace = mix(lace, fine, 0.3);
		float lake_foam = smoothstep(1.0 - lake_cover - s_foam_soft, 1.0 - lake_cover + s_foam_soft, lace)
			* step(0.001, lake_cover) * smoothstep(0.004, 0.03, baked_depth);
		foam = max(foam, lake_foam);
		cover = max(cover, lake_cover * 0.8);
	} else if (fade_out_len_m > 0.001 && s_inflow_foam > 0.001) {
		// a river running out into still water (its junction ribbon over a
		// pond): the current slackens and the foam it carries bunches up into
		// loose rafts and lines that drift out with it
		float into = smoothstep(fade_out_start_m - 7.0, fade_out_start_m + fade_out_len_m * 0.6, v_metric.y);
		float rafts = smoothstep(0.35, 0.72, d1.b);
		float in_cover = into * rafts * s_inflow_foam * 0.75;
		float lace = clamp((pattern - 0.5) * 2.0 + 0.5, 0.0, 1.0);
		float in_foam = smoothstep(1.0 - in_cover - s_foam_soft, 1.0 - in_cover + s_foam_soft, lace)
			* step(0.001, in_cover) * smoothstep(0.03, 0.14, baked_depth);
		foam = max(foam, in_foam);
		cover = max(cover, in_cover * 0.8);
	}
#ifdef STYLIZED
	// foam line along shores and around rocks
	if (s_shoreline > 0.001) {
		float line = 1.0 - smoothstep(s_shoreline * 0.5, s_shoreline, baked_depth);
		line *= step(0.3, pattern + 0.25);
		foam = max(foam, line);
	}
#endif

	// --- surface normal: add slopes, then build the normal in the river frame -
	float rough_amp = clamp(mix(s_detail_rest, s_detail_speed, clamp(speed / 3.0, 0.0, 1.0))
		+ mask * 0.5, 0.0, 1.6) * (1.0 - fall * 0.6) * mix(1.0, 0.35, tongue);
	// slicks: glassy patches drifting with the current (boils of a slow river)
	rough_amp *= mix(1.0, mix(0.12, 1.0, smoothstep(0.38, 0.62, d1.b)), s_slicks);
	vec2 sl = v_wave_slope + detail_slope * rough_amp;
	// --- wind on still water: wave trains plus short ripples riding on them
	if (lake && still > 0.01) {
		float wind = min(wind_ripple_strength / 0.4, 2.5);
		// gusts: cat's-paws of rougher water sweeping across with the wind
		float gust = textureLod(noise_tex, v_world.xz * 0.022 - TIME * wind_dir * 0.035, 0.0).b;
		gust = mix(0.4, 1.4, smoothstep(0.32, 0.68, gust));
#if DETAIL_LAYERS >= 2
		vec3 ww = wind_waves(v_world.xz, TIME, wind_dir, 4);
#else
		vec3 ww = wind_waves(v_world.xz, TIME, wind_dir, 3);
#endif
		vec2 g = ww.yz * 0.6 * mix(0.8, 1.15, gust);
		vec2 w1 = texture(noise_tex, v_world.xz * 0.85 - TIME * wind_dir * 0.3).rg - 0.5;
		g += w1 * 0.36 * gust;
#if DETAIL_LAYERS >= 2
		vec2 w2 = texture(noise_tex, v_world.xz * 2.1 + vec2(0.31, 0.17) - TIME * wind_dir * 0.5).rg - 0.5;
		g += w2 * 0.24 * gust;
#endif
		g *= s_ww_detail * wind * still;
		// world-axis slopes, handed over in the surface frame
		vec3 gw = vec3(g.x, 0.0, g.y);
		sl += vec2(dot(gw, v_side), dot(gw, v_tan));
	}
	// player ripples bend the normal everywhere inside the ripple grid
	vec3 rip = ripple_sample(v_world.xz);
	sl += rip.yz * 2.0;
	// foam is a mat of bubbles: it loses the mirror-smooth wavelets but
	// keeps a lumpy surface of its own
	sl = mix(sl, detail_slope * 0.9, foam * 0.7);

	vec3 n_world = normalize(v_norm0 - v_side * sl.x - v_tan * sl.y);
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 to_cam = cam_pos - v_world;
	float dist = length(to_cam);
	vec3 view_dir = to_cam / dist;
	// seen from below: flip. Which side is seen is a property of the surface
	// as drawn, waves included: an eye just above the water looks at the
	// near slope of a crest that stands higher than the eye, and that is
	// still the top of the water.
	vec3 n_face = normalize(cross(dFdx(v_world), dFdy(v_world)));
	if (dot(n_face, v_norm0) < 0.0) {
		n_face = -n_face;
	}
	bool from_below = dot(view_dir, n_face) < 0.0;
	if (from_below) {
		n_world = -n_world;
	}
	float ndv = max(dot(n_world, view_dir), 0.02);
	float fresnel = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
	// from under water, beyond the critical angle the surface is a mirror of
	// the water below (total internal reflection); inside it is a window
	float tir = from_below ? 1.0 - smoothstep(0.6, 0.72, ndv) : 0.0;

	// --- water thickness -------------------------------------------------------
	float frag_depth_lin = -VERTEX.z;
#ifdef USE_DEPTH_BUFFER
	float d_raw = texture(depth_tex, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d_raw);
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float scene_depth_lin = -vpos.z / vpos.w;
	float thick_view = scene_depth_lin - frag_depth_lin;
	// far away the depth buffer loses precision: fall back to the baked depth
	float far_w = smoothstep(60.0, 120.0, dist);
	float thickness = mix(max(thick_view, 0.0), baked_depth / max(ndv, 0.35), far_w);
	// the light path through water is bounded by the real depth: grazing
	// views must not turn a shallow stream opaque
	thickness = min(thickness, baked_depth * 3.0 + 0.15);
#else
	float thickness = baked_depth / max(ndv, 0.35);
#endif
#ifdef USE_DEPTH_BUFFER
	// The shoreline is where the surface meets the ground, and the depth
	// buffer knows exactly where that is. The view ray's run through the
	// water times the sine of its angle to the surface is the height of
	// water over the point where it lands: zero right at the waterline,
	// whatever the angle, so the water reaches the bank at eye level too
	// (a shoreline taken from the baked grid stops a cell short of it and
	// leaves a dry strip). Only a few centimetres of fade: soft, no gap.
	float ray_len = max(thick_view, 0.0) * dist / max(frag_depth_lin, 1e-3);
	float column = ray_len * abs(dot(view_dir, v_norm0));
	column = mix(column, baked_depth, far_w);
	// where the bake found the ground well above the water there is none,
	// whatever lies behind (the side of a ribbon over a low bank)
	column = min(column, baked_depth + 0.12);
	float edge = smoothstep(0.0, 0.03, column);
	if (v_fall_t > 0.001) {
		// a falling sheet has no bed under it: only its own thickness
		edge = smoothstep(0.0, 0.04, min(thickness, baked_depth + 0.5));
	}
	edge *= v_fade;
#else
	// without the depth buffer the shoreline comes from the baked grid; it
	// interpolates to zero at the waterline, so fade over the last few
	// centimetres of depth only
	float edge = smoothstep(0.0, 0.05, baked_depth) * v_fade;
#endif
	// Seen from below by a camera that is not in this water (standing under
	// a ledge the river runs along, looking up at its brink): no deeper water
	// column to look into, just a thin layer seen from behind.
	bool outside_below = from_below && v_fall_t < 0.001
		&& v_world.y - cam_pos.y > baked_depth + 0.35;
	if (outside_below) {
		thickness = min(thickness, baked_depth * 0.5);
	}
	// in the air the light only crosses the sheet itself: a falling sheet is
	// as clear as it is thin, not the colour of the river it came from
	// (only once it has fallen a while: over the brink it is still the river,
	// as deep and as coloured as it was a step upstream - no seam there)
	thickness = mix(thickness, min(thickness, baked_depth), smoothstep(0.2, 0.75, v_fall_t));
	if (fade_out_len_m > 0.001) {
		edge *= 1.0 - clamp((v_metric.y - fade_out_start_m) / fade_out_len_m, 0.0, 1.0);
	}
	if (fade_in_len_m > 0.001) {
		edge *= clamp(v_metric.y / fade_in_len_m, 0.0, 1.0);
	}

	// --- suspended sediment -------------------------------------------------------
	// silt scatters light: visibility falls off exponentially with the path
	// through the water, in clouds that drift with the current
	float turb = clamp(s_turbidity + flowing_water_turbidity, 0.0, 1.0);
	// runoff brings its own mud: the more of the turbidity is storm, the
	// more the sediment takes the storm colour
	s_sediment = mix(s_sediment, flowing_water_storm_color, flowing_water_turbidity / max(s_turbidity + flowing_water_turbidity, 0.001));
	turb = clamp(turb * mix(1.0, 0.5 + d1.b, s_turb_var), 0.0, 1.0);
	float sigma_sed = turb * turb * 7.0 + turb * 0.7;
	float t_sed = exp(-sigma_sed * thickness);

	// --- transmitted scene (refraction) ----------------------------------------
#ifdef USE_SCREEN_TEXTURE
	vec2 ruv = SCREEN_UV;
#if defined(REFRACTION_FULL) || defined(REFRACTION_SIMPLE)
	// The bed seen through a tilted surface shifts by about the water
	// thickness times the slope (times 1 - 1/n); on screen that is metres
	// over the width the view covers at this distance. (A fixed screen
	// offset smeared objects standing in the water into jagged streaks.)
	float view_m = 2.0 * dist / max(PROJECTION_MATRIX[1][1], 0.1);
	vec2 roff = clamp(sl, vec2(-1.0), vec2(1.0)) * 0.25 * s_refraction * min(thickness, 1.2) / max(view_m, 0.5);
	roff = clamp(roff, vec2(-0.03), vec2(0.03));
	ruv = SCREEN_UV + roff;
#ifdef REFRACTION_FULL
	// if the refracted sample is in front of the water, an object above the
	// surface would smear into it: fall back to the straight sample
	float rd_raw = texture(depth_tex, ruv).x;
	vec4 rpos = INV_PROJECTION_MATRIX * vec4(ruv * 2.0 - 1.0, rd_raw, 1.0);
	float r_depth_lin = -rpos.z / rpos.w;
	if (r_depth_lin < frag_depth_lin - 0.02) {
		ruv = SCREEN_UV;
	}
#endif
#endif
	// turbid water blurs what is behind it: read a lower mip
	float blur_lod = clamp((1.0 - t_sed) * 5.0 + thickness * (1.0 - s_clarity) * 2.0 + aer * 2.5, 0.0, 5.0);
	vec3 scene_refr = textureLod(screen_tex, ruv, blur_lod).rgb;
#else
	vec3 scene_refr = s_scatter;
#endif

	// --- debug views -------------------------------------------------------------
	if (debug_view > 0) {
		vec3 dbg;
		if (debug_view == 1) {
			dbg = speed_ramp(clamp(speed / 5.0, 0.0, 1.0)) * (0.75 + 0.5 * pattern);
		} else if (debug_view == 2) {
			dbg = mix(vec3(0.03, 0.07, 0.09), vec3(1.0), mask) + vec3(0.0, 0.25, 0.25) * aer * (1.0 - mask);
		} else {
			dbg = mix(vec3(0.85, 0.95, 0.90), vec3(0.02, 0.12, 0.40), clamp(baked_depth / 1.3, 0.0, 1.0));
		}
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		EMISSION = dbg;
		ALPHA = edge > 0.02 ? 1.0 : 0.0;
		NORMAL = (VIEW_MATRIX * vec4(v_norm0, 0.0)).xyz;
	} else {
		// --- water colour ----------------------------------------------------------
		float absorb_scale = mix(4.0, 1.0, s_clarity);
		// the colour daylight takes on a short way through this water (and
		// its silt): what bubbles under and between the foam are lit with.
		// Foam and aerated water take their tint from here, never from a
		// fixed blue, so they sit in every water from peat to glacier milk.
		vec3 path_col = exp(-s_absorption * absorb_scale * 0.4);
		vec3 sed_hue = s_sediment / max(max(s_sediment.r, max(s_sediment.g, s_sediment.b)), 1e-3);
		path_col *= mix(vec3(1.0), sed_hue, (1.0 - t_sed) * 0.7);
		vec3 water_hue = path_col / max(max(path_col.r, max(path_col.g, path_col.b)), 1e-3);
#ifdef USE_SCREEN_TEXTURE
		// Shade under water. Whatever lies in shadow under the surface (a
		// rock's underside, the shadow it casts on the bed) was lit by the
		// renderer with sky ambient only, so it comes through navy blue. Under
		// real water that shade is filled by light the water scatters: it has
		// the water's colour, like the lit bed beside it. Re-tint the dark
		// part of the transmitted scene, keeping its brightness.
		if (!from_below && v_fall_t < 0.001) {
			float r_lum = dot(scene_refr, vec3(0.3, 0.59, 0.11));
			float shade_w = (1.0 - smoothstep(0.06, 0.25, r_lum)) * smoothstep(0.0, 0.05, thickness);
			vec3 hue_l = water_hue / max(dot(water_hue, vec3(0.3, 0.59, 0.11)), 1e-3);
			scene_refr = mix(scene_refr, hue_l * r_lum, shade_w * 0.95);
		}
#endif
		// bubbles carried under the surface below rapids and falls
		float bubbles = clamp(aer * 0.9, 0.0, 1.0);
		vec3 transmit = exp(-s_absorption * thickness * absorb_scale) * t_sed
			* (1.0 - 0.8 * bubbles * clamp(thickness * 2.0, 0.0, 1.0));
#ifdef STYLIZED
		if (s_bands >= 1.0) {
			// banded depth colour: quantize the transmission
			float t_lum = dot(transmit, vec3(0.333));
			float q = floor(t_lum * s_bands + 0.5) / s_bands;
			transmit *= (t_lum > 0.001 ? q / t_lum : 0.0);
		}
		if (style_use_depth_gradient > 0.5) {
			float gt = clamp(thickness / 3.0, 0.0, 1.0);
			if (s_bands >= 1.0) {
				gt = floor(gt * s_bands + 0.5) / s_bands;
			}
			vec3 grad = texture(style_depth_gradient, vec2(gt, 0.5)).rgb;
			transmit = mix(transmit, 1.0 - gt * (1.0 - grad), 0.85);
		}
#endif
		// what comes back out of the water: its own colour, the sediment
		// where the path is long enough to hit it, pale where it is aerated
		vec3 scatter = mix(s_scatter, s_sediment, 1.0 - t_sed);
		scatter = mix(scatter, path_col * 0.62, bubbles * 0.7);

#if defined(USE_DEPTH_BUFFER) && defined(USE_SCREEN_TEXTURE)
		// --- caustics: light focused onto whatever lies under the water --------
		// drawn here, from the depth buffer, so every material receives them
		if (s_caustics > 0.001 && !from_below) {
			vec3 bed = (INV_VIEW_MATRIX * vec4(vpos.xyz / vpos.w, 1.0)).xyz;
			float column = v_world.y - bed.y;
			if (column > 0.02) {
				// The light network is cast by the surface onto what lies
				// below: it lands on ground facing up, not on the side of a
				// leg, a log or a rock face, where a straight-down projection
				// draws it as vertical streaks. The receiver's slope comes
				// from the depth buffer.
				vec3 bed_n = normalize(cross(dFdx(bed), dFdy(bed)));
				bed_n *= sign(bed_n.y + 1e-4);
				// a depth step (an object's silhouette) has no surface of its own
				float step_px = max(length(dFdx(bed)), length(dFdy(bed))) / max(dist * 0.002, 1e-4);
				float flat_w = smoothstep(0.45, 0.85, bed_n.y) * (1.0 - smoothstep(4.0, 12.0, step_px));
				vec2 cuv = bed.xz * (1.0 / max(s_caustics_size, 0.1));
				float c1 = texture(noise_tex, cuv + TIME * vec2(0.021, 0.14)).a;
#ifdef CAUSTICS_FULL
				float c2 = texture(noise_tex, cuv * 1.29 - TIME * vec2(0.035, -0.09)).a;
				float caus = pow(clamp(min(c1, c2) * 1.6, 0.0, 1.0), 3.0) * 1.5;
#else
				float caus = pow(clamp(c1 * 1.2, 0.0, 1.0), 5.0) * 1.2;
#endif
				// sharpest a hand's depth down, fading in the deep and in silt
				float focus = smoothstep(0.02, 0.22, column) * exp(-column * 0.5) * t_sed * t_sed * flat_w;
				// focused light is taken from the gaps between the lines: the
				// bed gets a pattern, not a uniform brightening that burns out
				scene_refr *= 1.0 + (caus - 0.18) * s_caustics * focus * 0.8;
			}
		}
#endif


		// --- waterfalls -------------------------------------------------------------
		// A fall is the same river, only faster, and its speed comes from the
		// bake. What changes is that the water is now a sheet in the air:
		//  - it has two surfaces (v_shell) and a thickness (the baked depth);
		//  - it is clear where it leaves the lip unbroken, and turns white as
		//    it takes in air a short way down;
		//  - its white water has the structure of falling water - curtains,
		//    strands, fibres, surges - from the fall texture, scrolled along
		//    "time since the lip" so it accelerates with the water;
		//  - it tears into separate strands lower down, and a rock in its
		//    path leaves a gap below it.
		// The river does not stop at the brink: its surface, its colour and
		// its foam carry on over the edge and only give way to the look of
		// falling water as the sheet whitens - there must be no line where
		// the ground ends.
		float fall_amt = max(fall, smoothstep(0.02, 0.4, v_fall_t));
		float fall_cover = 1.0;
		float fall_white = 0.0;
		float fall_dens = 1.0;
		float lower = 1.0 - v_shell;
		if (fall_amt > 0.001) {
			// The texture rides with the water: its coordinate down the fall
			// is the moment the water left the lip (time of flight minus
			// now), so a feature keeps its place in the water and is
			// stretched as the water accelerates - slow and compact at the
			// lip, long fast streaks lower down.
			// (the lower surface runs slightly behind the upper one: parallax)
			float ft = (v_flight.x - TIME * (1.0 - 0.08 * lower)) * FALL_TEX_RATE;
			// columns wander apart as they fall (v_wander, from the vertices)
			vec2 fuv = vec2((v_metric.x + v_wander) * 0.29 + lower * 0.43, ft);
			vec4 f1 = texture(fall_tex, fuv);
			vec4 f2 = texture(fall_tex, fuv * vec2(2.3, 1.7) + vec2(0.37, 0.21));
			// strands inside surges
			fall_dens = clamp((f1.b * 0.65 + f2.b * 0.35) * (0.5 + 1.0 * f1.g), 0.0, 1.0);
			// Thin water breaks up first. The bake gives the sheet's thickness
			// and speed; their product is the water passing per metre of
			// width, and it runs out toward the sides of the fall. There the
			// sheet frays: a whole film at the lip, then strands, then drops.
			float q = baked_depth * speed;
			float thin = 1.0 - smoothstep(0.015, 0.2, q);
			thin = max(thin, 1.0 - smoothstep(0.0, 0.12, min(UV.x, 1.0 - UV.x)));
			float t_down = smoothstep(0.03, 0.6, v_fall_t);
			// drops: fine grain that is cut into beads along the fall
			vec4 f3 = texture(fall_tex, fuv * vec2(3.1, 2.6) + vec2(0.11, 0.57));
			float beads = clamp(f3.b * 1.5 - 0.1, 0.0, 1.0) * smoothstep(0.25, 0.6, f2.g + (f3.a - 0.5) * 0.5);
			float edge_dens = mix(fall_dens, beads, 0.7 * t_down);
			float dens_c = mix(fall_dens, edge_dens, thin);
			// whole at the top, torn into strands and drops lower down
			float er = mix(-0.3, 0.36, smoothstep(0.22, 1.0, v_fall_t)) + thin * mix(0.1, 0.62, t_down);
			fall_cover = smoothstep(er, er + mix(0.24, 0.12, thin), dens_c + 0.06);
			fall_dens = mix(fall_dens, dens_c, thin * 0.6);
			// (a rock parts the sheet below it; on the brink itself the water
			// still closes round the rock, so the gap opens on the way down)
			fall_cover *= 1.0 - 0.96 * smoothstep(0.05, 0.4, ax.b) * smoothstep(0.08, 0.4, v_fall_t);
			// unbroken and clear at the lip, aerated white after a short fall
			// (thin water between the strands stays translucent: you see the
			// rock through it)
			fall_white = smoothstep(0.0, 0.32, v_fall_t) * smoothstep(0.22, 0.72, fall_dens);
			// Its foot is not a sheet any more: where it hits the pool the
			// water explodes into a boiling wall of white that hides the
			// line where the sheet meets the surface. The boil's top edge is
			// ragged and heaves (clumps rising and falling on their own
			// clock, not riding down with the water).
			// (metres above the pool: fallen = drop * progress^2)
			float above = v_flight.z * (1.0 / max(v_fall_t * v_fall_t, 0.01) - 1.0);
			// (only the last metre or so of the sheet can boil: the rest
			// skips the two reads)
			if ((above < 1.2 && v_fall_t > 0.5) || v_plunge > 0.001) {
				vec4 fb1 = texture(fall_tex, vec2(v_metric.x * 0.23 + 0.13, above * 0.21 + TIME * 0.09));
				vec4 fb2 = texture(fall_tex, vec2(v_metric.x * 0.53 + 0.57, above * 0.47 + TIME * 0.23));
				float heave = (fb1.g - 0.5) * 0.5 + (fb2.g - 0.5) * 0.3;
				// (v_plunge: the strip where the sheet's foot meets the pool,
				// whose fall progress blends back to 0, is all boil)
				float boil = max((1.0 - smoothstep(0.2, 0.75, above + heave)) * smoothstep(0.5, 0.8, v_fall_t) * fall_amt,
					smoothstep(0.3, 0.8, v_plunge));
				float boil_d = clamp(fb1.g * 0.5 + fb2.b * 0.5 + 0.2, 0.0, 1.0);
				fall_cover = mix(fall_cover, smoothstep(0.15, 0.45, boil_d), boil);
				fall_white = mix(fall_white, smoothstep(0.1, 0.6, boil_d), boil);
				fall_dens = mix(fall_dens, boil_d, boil);
			}
			// A body in the fall: the water it catches does not fall on, so
			// a gap opens below it and travels down with the water; its
			// rim is torn white where the sheet splits around the body.
			if (fall_hit_on > 0.5 && v_flight.x > 0.0 && v_metric.y > fall_hit_s.x && v_metric.y < fall_hit_s.y) {
				float hr = fall_hit_head + v_flight.x / fall_hit_dt;
				if (hr - fall_hit_head < fall_hit_rows - 2.0) {
					float hit = texture(fall_hit_tex, vec2(UV.x, (hr + 0.5) / fall_hit_rows)).r;
					// ragged: the gap's edge is the sheet's own strands
					float torn = smoothstep(0.2, 0.8, hit + (fall_dens - 0.5) * 0.8);
					float rim = clamp(hit * (1.0 - hit) * 4.0, 0.0, 1.0) * smoothstep(0.25, 0.65, fall_dens + 0.15);
					fall_cover *= 1.0 - torn;
					fall_white = max(fall_white, rim * 0.9);
					fall_dens = max(fall_dens, rim);
				}
			}
			// a little relief across the fall, for the light to catch
			sl.x += (f1.r - 0.5) * 1.5 * fall_amt;
			n_world = normalize(v_norm0 - v_side * sl.x - v_tan * sl.y);
			if (from_below) {
				n_world = -n_world;
			}
		}

		// --- compose through Godot's lighting --------------------------------------
		// in-scattered light is lit albedo; the refracted bed is emission
		vec3 albedo = scatter * (1.0 - transmit);
		vec3 emission = scene_refr * transmit * (1.0 - fresnel);
		// thin foam is a film of bubbles you can see through; only dense
		// foam is opaque. The fine layer gives it grain up close.
		float grain = smoothstep(0.15, 0.85, clamp((pattern - 0.4) * 1.8 + 0.5, 0.0, 1.0) * 0.45 + fine * 0.55);
		float foam_a = foam * mix(0.55, 0.96, smoothstep(0.15, 0.7, cover)) * mix(0.72, 1.0, grain) * v_fade;
		// white water is not paint: bubbles shade each other (neutral grey
		// grain), and thin lace is coloured by the water seen through it
		// while a dense mat is nearly the white of the bubbles
#ifdef STYLIZED
		float tint_k = s_foam_tint * 0.3;
#else
		float tint_k = s_foam_tint;
#endif
		float thin_foam = 1.0 - smoothstep(0.15, 0.8, cover);
		vec3 foam_body = mix(vec3(1.0), water_hue, tint_k * mix(0.3, 0.85, thin_foam) * mix(1.0, 0.6, grain));
		vec3 foam_col = s_foam_color * foam_body * mix(0.6, 0.88, grain);
		// on a fall the white water is the aerated sheet, not surface foam:
		// dense curtains are bright, thin water between them greyer and more
		// the colour of the water, and the lower surface sits in the shade
		// of the upper one
		float sheet_d = smoothstep(0.3, 0.92, fall_dens);
		vec3 sheet_col = s_foam_color * mix(vec3(1.0), water_hue, tint_k * mix(0.75, 0.25, sheet_d)) * mix(0.52, 0.88, sheet_d);
		sheet_col *= mix(1.0, 0.8, lower);
		foam_col = mix(foam_col, sheet_col, fall_amt);
		foam_a = mix(foam_a, fall_white * 0.97, fall_amt);
		albedo = mix(albedo, foam_col, foam_a);
		emission *= 1.0 - foam_a;
		float rough = clamp(s_roughness + speed * 0.015, 0.0, 1.0);
		float spec = s_specular;
		if (s_sharp > 0.5) {
			rough = 0.03;
		}
		// a bubble mat scatters, it does not mirror: little sky in it (a
		// glossy foam picks up the blue of the sky and reads as a cold film)
		rough = mix(rough, 0.95, foam_a);
		spec = mix(spec, 0.06, foam_a);
		// aerated water scatters light through itself: matte, lit softly from
		// both sides, no mirror in it
		float fall_a = fall_amt * foam_a;
		rough = mix(rough, 0.95, fall_a);
		spec = mix(spec, 0.08, fall_a);
		BACKLIGHT = vec3(0.28) * fall_a;

		// (a falling sheet is seen from either side as what it is; the
		// under-water look only applies to a real water surface seen from below)
		// ... by a camera that is in that water
		if (from_below && !outside_below && v_fall_t < 0.001 && v_shell > 0.5) {
			// window: the world above, tinted; mirror: the water's own colour
			albedo = mix(albedo * 0.3, scatter * 0.6, tir);
			emission = mix(scene_refr * 0.9, scatter * 0.25, tir) * (1.0 - foam_a * 0.5);
#ifdef SSR
			// beyond the critical angle the surface is a mirror of what lies
			// under it: the bed and the rocks, dimmed by the water in between
			if (tir > 0.02) {
				vec3 n_mir = normalize((VIEW_MATRIX * vec4(-normalize(v_norm0 - v_side * sl.x * 0.18 - v_tan * sl.y * 0.18), 0.0)).xyz);
				float mir_jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
				vec4 hit = water_mirror_below(VERTEX, n_mir, PROJECTION_MATRIX, INV_PROJECTION_MATRIX, mir_jitter);
				float k = hit.a * tir * tir * (1.0 - foam_a) * 0.6;
				albedo *= 1.0 - k;
				emission = mix(emission, hit.rgb * 0.45 + scatter * 0.1, k);
			}
#endif
			spec = 0.0;
			rough = 1.0;
		}
		ALBEDO = albedo;
		ROUGHNESS = rough;
		SPECULAR = spec;
		// real alpha for the shore edge and junction fades: whatever is
		// drawn beneath (the pond under a river extension) shows through -
		// the screen texture only holds the opaque pass
		EMISSION = emission;
		// (the sides of a falling sheet are faded by the mesh, through v_fade,
		// where the baked sheet runs out; fall_cover frays them)
		float in_air = smoothstep(0.0, 0.06, v_fall_t);
		// water that reaches the side of the ribbon has no bank to end at:
		// it thins out over the last hand's width instead of ending in a cut
		// (one cell's width at most: a wider fade would itself leave a
		// strip of missing water along a bank at the ribbon's side)
		float rim = smoothstep(0.0, 0.5 / 48.0, min(UV.x, 1.0 - UV.x));
		ALPHA = clamp(edge, 0.0, 1.0) * rim * mix(1.0, fall_cover, max(fall_amt, in_air))
			* mix(1.0, in_air, lower) * (outside_below ? 0.4 : 1.0);
		NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
#ifdef SSR
		// mirror the surroundings in smooth water (not in foam or falls)
		float mirror = (1.0 - foam_a) * (1.0 - fall_a) * (1.0 - smoothstep(0.25, 0.6, rough));
		if (mirror > 0.02 && !from_below) {
			// a calmer normal for the mirror image keeps it readable
			vec3 n_ssr = normalize((VIEW_MATRIX * vec4(normalize(v_norm0 - v_side * sl.x * 0.35 - v_tan * sl.y * 0.35), 0.0)).xyz);
			vec3 n_geo = normalize((VIEW_MATRIX * vec4(v_norm0, 0.0)).xyz);
		vec4 hit = water_ssr(VERTEX, n_ssr, n_geo, PROJECTION_MATRIX, INV_PROJECTION_MATRIX);
			float k = hit.a * mirror;
			EMISSION += hit.rgb * fresnel * k;
			// where the mirror image is, the sky is not
			SPECULAR *= 1.0 - k * 0.85;
		}
#endif
	}
}
