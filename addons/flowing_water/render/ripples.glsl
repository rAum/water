#[compute]
#version 450

// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// One step of the player-centred ripple simulation (wave equation).
// State textures are RG16F: r = height, g = previous height.
// The grid recentres on the player and the heights drift with the baked
// current from the world water map, so wakes form V shapes and rings drift
// downstream. Land (depth 0) is a hard wall; the outer cells absorb.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D prev_tex;     // rg = h, h_prev
layout(set = 0, binding = 1, rg16f) restrict writeonly uniform image2D out_img;
layout(set = 0, binding = 2) uniform sampler2D map_tex;      // world water map
layout(set = 0, binding = 3, std430) restrict readonly buffer Inj {
	vec4 inj[];   // xy = world xz, z = radius, w = strength
};

layout(push_constant, std430) uniform Params {
	vec2 origin_old;    // world min corner of the previous grid
	vec2 origin_new;
	vec4 map_rect;      // xy = origin, z = size, w = active
	float grid_size;    // world metres covered by the grid
	float texel;        // metres per texel
	float dt;
	float damp;
	int n;              // texels per side
	int inj_count;
	float map_base;
	float _pad;
} pc;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= pc.n || id.y >= pc.n) {
		return;
	}
	vec2 world = pc.origin_new + (vec2(id) + 0.5) * pc.texel;

	// water data at this texel
	vec2 muv = (world - pc.map_rect.xy) / pc.map_rect.z;
	vec4 m = texture(map_tex, clamp(muv, 0.0, 1.0));
	float depth = m.a * 8.0;
	if (pc.map_rect.w < 0.5 || depth <= 0.015) {
		imageStore(out_img, id, vec4(0.0));
		return;
	}
	vec2 flow = (m.rg - 0.5) * 16.0;

	// moves with the current: sample upstream, in the previous grid's frame
	vec2 src = world - flow * pc.dt;
	vec2 uv = (src - pc.origin_old) / pc.grid_size;
	float e = 1.0 / float(pc.n);
	vec2 hv = texture(prev_tex, uv).rg;
	float h = hv.r;
	float hp = hv.g;
	float hl = texture(prev_tex, uv - vec2(e, 0.0)).r;
	float hr = texture(prev_tex, uv + vec2(e, 0.0)).r;
	float hd = texture(prev_tex, uv - vec2(0.0, e)).r;
	float hu = texture(prev_tex, uv + vec2(0.0, e)).r;
	float lap = hl + hr + hd + hu - 4.0 * h;

	// Ripple speed: these are short surface waves, not long shallow-water
	// waves: a couple of metres per second in open water, slower in the
	// shallows. CFL clamped.
	float c = clamp(sqrt(9.81 * depth) * 0.9, 0.6, 2.6);
	float cmax = 0.55 * pc.texel / pc.dt;
	c = min(c, cmax);
	float k = c * c * pc.dt * pc.dt / (pc.texel * pc.texel);

	float hn = (2.0 * h - hp + k * lap) * pc.damp;

	// outer cells absorb waves
	float border = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	hn *= smoothstep(0.0, 0.06, border);

	// land neighbours reflect a little less (soft wall): damp where shallow
	hn *= smoothstep(0.0, 0.05, depth);

	for (int i = 0; i < pc.inj_count; i++) {
		vec2 d = world - inj[i].xy;
		float r2 = inj[i].z * inj[i].z;
		float g = exp(-dot(d, d) / max(r2, 1e-4));
		hn -= inj[i].w * g;
	}
	hn = clamp(hn, -0.35, 0.35);
	imageStore(out_img, id, vec4(hn, h, 0.0, 0.0));
}
