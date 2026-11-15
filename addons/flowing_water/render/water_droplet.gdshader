// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Water falling beside a waterfall: each particle is a short streak along
// its own velocity (GPUParticles3D aligns the quad's Y axis with it; the
// particle shader sets its width and its length from the speed), drawn as a
// soft-edged drop with a heavier head and a thinning tail.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

varying float v_seed;

void vertex() {
	v_seed = INSTANCE_CUSTOM.x;
}

void fragment() {
	// UV.y runs along the velocity: 0 = head (leading end), 1 = tail
	vec2 c = UV * 2.0 - 1.0;
	float across = exp(-c.x * c.x * 4.5);
	float head = smoothstep(-1.0, -0.55, c.y);
	float tail = 1.0 - smoothstep(-0.2, 1.0, c.y);
	// a streak is not a solid bar: it breaks into two or three beads
	float beads = 0.72 + 0.28 * sin(c.y * (5.0 + v_seed * 9.0) + v_seed * 40.0);
	float a = across * head * tail * beads;
	// fade where it meets rock or the pool
	float d_raw = texture(depth_tex, SCREEN_UV).x;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d_raw, 1.0);
	float gap = -vp.z / vp.w + VERTEX.z;
	a *= smoothstep(0.0, 0.1, gap);
	// (red is the drop's opacity, not a colour: see water_spray.gdshader)
	ALBEDO = vec3(0.93, COLOR.gb);
	ALPHA = clamp(a * COLOR.a, 0.0, 1.0);
}
