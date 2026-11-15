// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Mist and impact spray: soft puffs of fine drops. They are big and stacked
// many deep near a fall, so every pixel must be cheap: no engine lighting
// (no shadow lookups per sprite layer), only a lit colour from the sun's
// direction and colour (set by WaterSprayFactory) - drops scatter light
// forward, so a puff glows when the sun is behind it - plus sky light.
// Puffs fade where they meet rock or water (soft particles) and close to
// the camera, so standing in the mist leaves no veil on the screen.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D puff_tex : source_color, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 sun_dir = vec3(0.3, 0.8, 0.2);      // towards the sun (world)
uniform vec3 sun_color = vec3(1.0, 0.97, 0.9);   // colour x energy
uniform vec3 sky_color = vec3(0.32, 0.38, 0.45);
uniform float soft_distance = 0.5;
uniform float near_fade_start = 0.6;
uniform float near_fade_end = 3.0;

varying vec3 v_light;

void vertex() {
	// camera-facing quad that keeps the particle's scale
	mat4 m = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]),
		normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	m = m * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * m;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	// lighting per puff, not per pixel: the view direction to its centre
	vec3 to_puff = normalize(MODEL_MATRIX[3].xyz - INV_VIEW_MATRIX[3].xyz);
	float fwd = max(dot(to_puff, normalize(sun_dir)), 0.0);
	float glow = pow(fwd, 6.0) * 1.4 + fwd * 0.25;
	v_light = sky_color + sun_color * (0.45 + glow);
}

void fragment() {
	float a = texture(puff_tex, UV).a * COLOR.a;
	float dist = length(VERTEX);
	a *= smoothstep(near_fade_start, near_fade_end, dist);
	if (a < 0.002) {
		discard;
	}
	float d_raw = texture(depth_tex, SCREEN_UV).x;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d_raw, 1.0);
	float gap = -vp.z / vp.w + VERTEX.z;
	a *= clamp(gap / soft_distance, 0.0, 1.0);
	ALBEDO = COLOR.rgb * v_light;
	ALPHA = clamp(a, 0.0, 1.0);
}
