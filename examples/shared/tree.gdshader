// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Conifer branches for the example scenes: alpha-tested cards carrying a
// needle-branch texture, placed in whorls around a trunk (MultiMesh).
// COLOR.a = sway weight, INSTANCE_CUSTOM.r = per-tree tint.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D branch_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;

varying float v_tint;

void vertex() {
	v_tint = INSTANCE_CUSTOM.r;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = sin(TIME * 0.9 + wp.x * 0.21 + wp.z * 0.17) + 0.4 * sin(TIME * 2.3 + wp.y * 0.8 + wp.x);
	vec3 push = vec3(0.8, 0.15, 0.6) * w * 0.045 * COLOR.a;
	VERTEX += transpose(mat3(MODEL_MATRIX)) * push;
}

void fragment() {
	vec4 t = texture(branch_tex, UV);
	ALBEDO = t.rgb * mix(0.72, 1.12, v_tint);
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.32;
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
	BACKLIGHT = t.rgb * 0.5;
	// cards are lit as foliage volume, whichever way they face
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
