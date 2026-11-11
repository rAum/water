// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Grass and reed tufts for the example scenes: crossed alpha-tested cards
// carrying a blade-clump texture (MultiMesh). COLOR.r = height along the
// card (0 root, 1 tip), INSTANCE_CUSTOM.r = per-tuft tint.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D blade_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;

varying float v_h;
varying float v_tint;

void vertex() {
	v_h = COLOR.r;
	v_tint = INSTANCE_CUSTOM.r;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = sin(TIME * 1.6 + wp.x * 0.7 + wp.z * 0.9) * 0.6 + sin(TIME * 2.9 + wp.x * 1.9 - wp.z * 0.4) * 0.3;
	vec3 push = vec3(0.8, 0.0, 0.6) * w * 0.06 * v_h * v_h;
	VERTEX += transpose(mat3(MODEL_MATRIX)) * push;
	// lit like the ground it grows from, not like a wall of cards
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	// far tufts keep a sharper mip: thin blades otherwise average away and
	// the alpha test turns them into blocks
	vec4 t = textureLod(blade_tex, UV, min(textureQueryLod(blade_tex, UV).x, 2.5));
	vec3 col = t.rgb * mix(vec3(0.8, 0.9, 0.66), vec3(1.1, 1.0, 0.8), v_tint);
	ALBEDO = col * mix(0.6, 1.0, v_h);
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.4;
	ROUGHNESS = 0.8;
	SPECULAR = 0.15;
	BACKLIGHT = col * 0.35 * v_h;
}
