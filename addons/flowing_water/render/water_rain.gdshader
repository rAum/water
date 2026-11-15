// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Falling rain streaks (WaterRain): thin quads stretched along the drop's
// velocity. Unshaded and nearly transparent: a raindrop is seen by the sky
// it refracts, so it is a faint grey line that reads against dark ground
// and almost vanishes against the sky.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 rain_color : source_color = vec4(0.72, 0.75, 0.78, 0.3);
uniform float intensity = 1.0;
// distance (m) at which the streaks have faded out: the edge of the box
uniform float fade_far = 13.0;

varying float v_alpha;

void vertex() {
	vec3 vp = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float d = length(vp);
	// too close they would be thick bars across the view; at the box edge
	// they fade instead of ending in a line
	v_alpha = smoothstep(0.7, 2.2, d) * (1.0 - smoothstep(fade_far * 0.6, fade_far, d));
	// thin streaks far away shimmer: widen them to about a pixel and fade
	// them by the same factor (same coverage, no flicker)
	float px = d * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float w = 0.007;
	float widen = max(px * 1.2 / w, 1.0);
	VERTEX.x *= widen;
	v_alpha /= widen;
}

void fragment() {
	// bright head, fading tail; soft across (the quad's +y, UV.y = 0, points
	// along the velocity: down)
	float head = 1.0 - UV.y;
	float along = smoothstep(0.0, 0.7, head) * (1.0 - smoothstep(0.9, 1.0, head));
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	ALBEDO = rain_color.rgb;
	ALPHA = rain_color.a * along * across * v_alpha * mix(0.7, 1.0, intensity);
}
