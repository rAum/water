// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Spray and mist from baked emission points (port of the prototype's
// SPRAY_VS). kind 0 = short droplets at rocks, kind 1 = slow mist at falls,
// kind 2 = water falling with a waterfall (born with the water's velocity,
// drawn by water_droplet.gdshader as streaks along that velocity).
// points_tex row 0: xyz = world position, w = unused (list is already
// importance-expanded on the CPU); row 1: xyz = water velocity at the point.
shader_type particles;

uniform sampler2D points_tex : filter_nearest, repeat_disable;
uniform int point_count = 1;
uniform float kind = 0.0;
uniform float life_rand = 0.4;
uniform vec3 wind = vec3(0.4, 0.0, 0.3);

float prand(inout uint seed) {
	seed = seed * 747796405u + 2891336453u;
	uint w = ((seed >> ((seed >> 28u) + 4u)) ^ seed) * 277803737u;
	w = (w >> 22u) ^ w;
	return float(w) / 4294967295.0;
}

void start() {
	uint seed = RANDOM_SEED + uint(NUMBER) * 1664525u;
	if (RESTART_POSITION) {
		float drop_w = 0.0;
		int idx = int(prand(seed) * float(point_count - 1) + 0.5);
		vec3 p = texelFetch(points_tex, ivec2(idx, 0), 0).xyz;
		vec3 wv = texelFetch(points_tex, ivec2(idx, 1), 0).xyz;
		p.x += (prand(seed) - 0.5) * 0.5;
		p.z += (prand(seed) - 0.5) * 0.5;
		if (kind > 1.5) {
			// falling water: leaves the sheet with the water's own velocity
			// (width and opacity vary: many fine drops, a few heavy ones)
			p.y += 0.05 - prand(seed) * 0.15;
			VELOCITY = wv * (0.8 + 0.3 * prand(seed))
				+ vec3((prand(seed) - 0.5) * 0.9, prand(seed) * 0.6 - 0.1, (prand(seed) - 0.5) * 0.9);
			float r = prand(seed);
			float s = 0.012 + r * r * 0.04;
			TRANSFORM = mat4(vec4(s, 0, 0, 0), vec4(0, s, 0, 0), vec4(0, 0, s, 0), vec4(p, 1.0));
			// red carries this drop's own opacity; process() builds alpha from it
			COLOR = vec4(0.35 + 0.6 * prand(seed), 0.96, 0.98, 0.0);
			drop_w = s;
		} else if (kind < 0.5) {
			// droplet: thrown up from the surface, carried by the water
			p.y += 0.03;
			VELOCITY = wv * 0.5
				+ vec3((prand(seed) - 0.5) * 0.8, 1.0 + prand(seed) * 1.8, (prand(seed) - 0.5) * 0.5);
			float s = 0.02 + prand(seed) * 0.035;
			TRANSFORM = mat4(vec4(s, 0, 0, 0), vec4(0, s, 0, 0), vec4(0, 0, s, 0), vec4(p, 1.0));
			COLOR = vec4(0.96, 0.98, 0.99, 0.75);
		} else {
			// mist: slow, grows, drifts with the wind
			p.y += 0.1 + prand(seed) * 0.4;
			VELOCITY = vec3((prand(seed) - 0.5) * 0.5, 0.2 + prand(seed) * 0.5, (prand(seed) - 0.5) * 0.5);
			float s = 0.35 + prand(seed) * 0.6;
			TRANSFORM = mat4(vec4(s, 0, 0, 0), vec4(0, s, 0, 0), vec4(0, 0, s, 0), vec4(p, 1.0));
			COLOR = vec4(0.96, 0.98, 0.99, 0.05);
		}
		// z = per-particle life fraction (the node lifetime is the maximum),
		// w = width of a falling drop
		CUSTOM = vec4(prand(seed), 0.0, 1.0 - life_rand * prand(seed), drop_w);
	}
}

void process() {
	float t = CUSTOM.y / max(LIFETIME * CUSTOM.z, 0.01);
	t = min(t, 1.0);
	CUSTOM.y += DELTA;
	if (kind < 0.5 || kind > 1.5) {
		VELOCITY.y -= 9.8 * DELTA;
	} else {
		VELOCITY = mix(VELOCITY, wind + vec3(0.0, 0.05, 0.0), DELTA * 0.6);
		// mist grows as it ages
		float g = 1.0 + DELTA * 0.45;
		TRANSFORM[0].xyz *= g;
		TRANSFORM[1].xyz *= g;
		TRANSFORM[2].xyz *= g;
	}
	// fade in fast, fade out over life
	float a = (1.0 - t) * smoothstep(0.0, 0.12, t);
	if (kind > 1.5) {
		// falling water is seen as a streak: as long as the distance it
		// covers while the eye (or the shutter) holds it, so it lengthens as
		// it speeds up. Air drag slows the finest drops a little.
		float w = CUSTOM.w;
		VELOCITY *= 1.0 - DELTA * 0.6 * (1.0 - smoothstep(0.012, 0.04, w));
		float len = w * 1.6 + length(VELOCITY) * 0.028;
		TRANSFORM[0].xyz = vec3(w, 0.0, 0.0);
		TRANSFORM[1].xyz = vec3(0.0, len, 0.0);
		TRANSFORM[2].xyz = vec3(0.0, 0.0, w);
		// a stretched drop spreads the same water over more length, so it
		// is fainter
		COLOR.a = a * COLOR.r * clamp(w * 3.0 / len + 0.35, 0.0, 1.0);
	} else {
		COLOR.a = a * (kind < 0.5 ? 0.7 : 0.035);
	}
}
