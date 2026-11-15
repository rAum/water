#[compute]
#version 450

// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Underwater post effect. Runs on every pixel whose point on the near plane
// lies below the water surface, so a camera half in the water gets a real
// waterline. For those pixels, in order:
//
//   lens      slight wavy refraction of the image, mild blur with distance
//   caustics  the sun's light network, projected from the surface along the
//             refracted sun direction onto whatever the depth buffer holds
//   fog       Beer-Lambert extinction per colour channel along the view ray
//             and in-scattered light that falls off with depth below the
//             surface (brighter looking up, darker looking down)
//   shafts    the same light network marched through the water volume
//   motes     suspended particles drifting with the current
//   finish    vignette, dither against banding, meniscus at the waterline
//
// Everything is driven by the style of the water body the camera is in;
// WaterManager fills the parameter block every frame.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) restrict uniform image2D color_img;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
// copy of the colour buffer (full mode only: the lens reads neighbours)
layout(set = 0, binding = 2) uniform sampler2D src_tex;
// the shared water noise: a = ridged light network
layout(set = 0, binding = 3) uniform sampler2D noise_tex;
// the player ripple simulation: r = height (m)
layout(set = 0, binding = 5) uniform sampler2D ripple_tex;

// Uniform buffer, not push constants: this block is larger than the 128-byte
// push-constant floor (the Steam Deck's limit).
layout(set = 0, binding = 4, std140) uniform Params {
	mat4 inv_proj;        // clip -> view
	mat4 cam_transform;   // view -> world
	vec4 extinction;      // rgb per metre along a ray, a = sediment part of it
	vec4 downwelling;     // rgb per metre of depth for daylight, a = surface height at the camera
	vec4 fog_color;       // rgb in-scattered colour at the surface, a = time
	vec4 sun_dir;         // xyz toward the sun, refracted into the water, a = shaft strength
	vec4 light;           // rgb sun colour * energy, a = mote density 0..1
	vec4 plane;           // xy surface gradient (dh/dx, dh/dz), zw caustic drift (m)
	vec4 caustics;        // x strength, y 1/size (1/m), z taps (1|2), w distortion
	vec4 quality;         // x shaft steps, y mote shells, z full mode, w near plane
	vec4 screen;          // xy render size, z frame, w vignette
	vec4 ripple_rect;     // xy world origin, z world size, w texels (0 = off)
} p;

const float FAR = 1.0e4;
// pattern scale of the underwater light network relative to the style's size
const float UNDER_SCALE = 0.4;

float ign(vec2 px) {
	return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

vec3 hash3(vec3 q) {
	q = fract(q * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yxz + 33.33);
	return fract((q.xxy + q.yxx) * q.zyx);
}

vec3 view_pos(vec2 uv, float raw) {
	vec4 v = p.inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return v.xyz / v.w;
}

// Surface height: a plane through the height at the camera (rivers slope).
float surface_h(vec2 xz) {
	return p.downwelling.a + dot(p.plane.xy, xz - p.cam_transform[3].xz);
}

// Height of the player ripples: the surface mesh is displaced by them, so
// the waterline at the lens has to be as well.
float ripple_h(vec2 xz) {
	if (p.ripple_rect.w < 0.5) {
		return 0.0;
	}
	vec2 uv = (xz - p.ripple_rect.xy) / p.ripple_rect.z;
	float border = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	if (border <= 0.01) {
		return 0.0;
	}
	return textureLod(ripple_tex, uv, 0.0).r * smoothstep(0.01, 0.1, border);
}

float hash1(vec2 px) {
	vec3 q = fract(vec3(px.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

// The light network on the horizontal plane, in pattern units.
float light_network(vec2 cuv, float lod, float taps) {
	float t = p.fog_color.a;
	float c1 = textureLod(noise_tex, cuv + t * vec2(0.021, 0.14), lod).a;
	if (taps < 1.5) {
		return pow(clamp(c1 * 1.2, 0.0, 1.0), 5.0) * 1.2;
	}
	float c2 = textureLod(noise_tex, cuv * 1.29 - t * vec2(0.035, -0.09), lod).a;
	return pow(clamp(min(c1, c2) * 1.6, 0.0, 1.0), 3.0) * 1.5;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	vec2 size = p.screen.xy;
	if (id.x >= int(size.x) || id.y >= int(size.y)) {
		return;
	}
	vec2 uv = (vec2(id) + 0.5) / size;
	float time = p.fog_color.a;
	float near = p.quality.w;
	bool full = p.quality.z > 0.5;
	mat3 cam_basis = mat3(p.cam_transform);
	vec3 cam = p.cam_transform[3].xyz;

	// --- waterline: where is this pixel's point on the near plane? -----------
	vec3 ray_view = normalize(view_pos(uv, 0.5));
	vec3 near_world = cam + cam_basis * (ray_view * (near / max(-ray_view.z, 1e-4)));
	// size of a pixel on the near plane, and how much of it is vertical
	float px_m = near * 2.0 * abs(p.inv_proj[1][1]) / size.y;
	float tilt = max(length(vec2(cam_basis[0].y, cam_basis[1].y)), 0.05);
	// the line laps at the lens
	float lap = sin(uv.x * 7.0 + time * 1.3) * 2.2 + sin(uv.x * 19.0 - time * 2.1) * 1.1;
	float h_near = surface_h(near_world.xz) + ripple_h(near_world.xz);
	float sd_px = (near_world.y - h_near) / (px_m * tilt) + lap;
	// The drawn surface carries waves this plane does not know, so with the
	// eye a few millimetres above the water the two disagree: the surface is
	// cut away by the near plane higher up the screen than the line computed
	// here, and the strip between shows the bed with no water over it. The
	// surface writes depth, so a pixel just above the line whose scene point
	// lies well under the water has no surface in front of it: it is that
	// strip, and belongs to the water.
	if (sd_px > -6.0 && sd_px < size.y * 0.2) {
		float raw0 = textureLod(depth_tex, uv, 0.0).x;
		if (raw0 > 1e-7) {
			vec3 w0 = cam + cam_basis * view_pos(uv, raw0);
			if (surface_h(w0.xz) + ripple_h(w0.xz) - w0.y > 0.03) {
				sd_px = -6.0;
			}
		}
	}
	if (sd_px > 6.0) {
		return;    // above the water: untouched
	}
	vec3 orig = imageLoad(color_img, id).rgb;
	float alpha = imageLoad(color_img, id).a;
	float under = 1.0 - smoothstep(-1.0, 1.0, sd_px);
	// lens effects calm down toward the waterline (nothing bleeds across it)
	float deep = smoothstep(2.0, 24.0, -sd_px);

	vec3 col = orig;
	if (under > 0.0) {
		vec3 ext = p.extinction.rgb;
		float ext_s = dot(ext, vec3(0.3333));
		float sed = p.extinction.a;

		// --- lens: wavy refraction, stronger on what is far away --------------
		vec2 suv = uv;
		if (full && p.caustics.w > 0.001) {
			float d0 = length(view_pos(uv, textureLod(depth_tex, uv, 0.0).x));
			vec2 w = vec2(
				sin(uv.y * 17.0 + time * 1.3) + 0.5 * sin(uv.y * 41.0 - time * 2.1 + uv.x * 9.0),
				cos(uv.x * 13.0 - time * 1.1) + 0.5 * cos(uv.x * 37.0 + time * 1.9 + uv.y * 11.0));
			vec2 e = smoothstep(vec2(0.0), vec2(0.05), uv) * smoothstep(vec2(0.0), vec2(0.05), 1.0 - uv);
			suv += w * vec2(size.y / size.x, 1.0) * 0.0016 * p.caustics.w * deep * e.x * e.y
				* smoothstep(0.3, 4.0, d0);
		}

		// --- the scene behind this pixel -----------------------------------------
		float raw = textureLod(depth_tex, suv, 0.0).x;
		vec3 vp = view_pos(suv, raw);
		float dist = raw <= 1e-7 ? FAR : length(vp);
		vec3 ray = normalize(cam_basis * (raw <= 1e-7 ? normalize(view_pos(suv, 0.5)) : vp));
		// a ray that climbs leaves through the surface: fog only up to there
		float climb = ray.y - dot(p.plane.xy, ray.xz);
		float head = max(h_near - near_world.y, 0.0);
		float t_exit = climb > 1e-4 ? head / climb + near : FAR;
		bool exits = t_exit < dist;
		float path = min(min(dist, t_exit), 400.0);
		vec3 transmit = exp(-ext * path);

		if (full) {
			// mild blur with distance: water is not a perfect lens
			float r = (1.0 - transmit.g) * 2.2 * deep * size.y / 800.0;
			vec2 o = r / size;
			col = textureLod(src_tex, suv, 0.0).rgb * 0.4
				+ (textureLod(src_tex, suv + o, 0.0).rgb
				+ textureLod(src_tex, suv - o, 0.0).rgb
				+ textureLod(src_tex, suv + vec2(o.x, -o.y), 0.0).rgb
				+ textureLod(src_tex, suv + vec2(-o.x, o.y), 0.0).rgb) * 0.15;
		}

		vec3 sun = p.sun_dir.xyz;
		vec2 sun_shear = sun.xz / max(sun.y, 0.2);
		float px_angle = 2.0 * abs(p.inv_proj[1][1]) / size.y;

		// --- light on what is under water: caustics, less daylight deeper down ---
		if (!exits && dist < 200.0) {
			vec3 pos = cam + ray * dist;
			float column = surface_h(pos.xz) - pos.y;
			if (column > 0.0) {
				if (p.caustics.x > 0.001) {
					// follow the refracted sunlight up to the surface
					// (seen from in the water the network is larger than the fine
					// one the surface draws in the shallows: light has further to spread)
					vec2 cuv = (pos.xz + sun_shear * column + p.plane.zw) * p.caustics.y * UNDER_SCALE;
					float lod = clamp(log2(dist * px_angle * 512.0 * p.caustics.y * UNDER_SCALE) + 0.5, 0.0, 6.0);
					float caus = light_network(cuv, lod, p.caustics.z);
					// sharpest a hand's depth down, fading in the deep and in silt
					float focus = smoothstep(0.03, 0.3, column) * exp(-column * 0.25)
						* exp(-sed * column * 2.0) * smoothstep(0.02, 0.25, sun.y);
					{
						// Surfaces that face away from the sun get almost none,
						// and steep ones little: the network is cast from above,
						// so on a vertical face it only draws streaks. (Both
						// quality modes: this is what keeps rock faces and legs
						// from being striped.)
						vec2 px = 1.0 / size;
						vec3 vx = view_pos(suv + vec2(px.x, 0.0), textureLod(depth_tex, suv + vec2(px.x, 0.0), 0.0).x) - vp;
						vec3 vy = view_pos(suv + vec2(0.0, px.y), textureLod(depth_tex, suv + vec2(0.0, px.y), 0.0).x) - vp;
						vec3 n = normalize(cam_basis * cross(vx, vy));
						n *= sign(-dot(n, ray));
						float jump = max(abs(vx.z), abs(vy.z)) / max(dist * px_angle, 1e-5);
						float facing = clamp(dot(n, sun) * 1.4 + 0.25, 0.12, 1.0)
							* mix(0.15, 1.0, smoothstep(0.35, 0.8, n.y));
						// across a silhouette the normal is meaningless: no light
						focus *= mix(facing, 0.3, smoothstep(8.0, 30.0, jump));
					}
					// lines bright, gaps a little darker: a pattern on the bed
					// rather than a brightening that burns rocks out to white
					col *= max(1.0 + (caus - 0.18) * p.caustics.x * focus * 1.1, 0.0);
				}
				col *= exp(-p.downwelling.rgb * column * 0.6);
			}
		}

		// --- fog -----------------------------------------------------------------
		// in-scattered daylight fades with depth, so the integral along the ray
		// has a closed form: brighter looking up, darker looking down
		float cam_depth = max(surface_h(cam.xz) - cam.y, 0.0);
		vec3 a = max(ext - p.downwelling.rgb * climb, ext * 0.25);
		vec3 inscatter = p.fog_color.rgb * exp(-p.downwelling.rgb * cam_depth)
			* ext / a * (1.0 - exp(-a * path));
		col = col * transmit + inscatter;

		float dither = ign(vec2(id) + p.screen.z * 5.588);

		// --- light shafts ------------------------------------------------------------
		// the light network again, marched through the water. Drawn as a
		// variation around the fog's own brightness: beams lighter, the gaps
		// between them darker, the water no milkier on average.
		int steps = int(p.quality.x);
		if (steps > 0 && p.sun_dir.a > 0.001 && sun.y > 0.03) {
			float reach = min(path, min(12.0, 3.0 / max(ext_s, 0.05)));
			float dt = reach / float(steps);
			float k_s = dot(p.downwelling.rgb, vec3(0.3333));
			// (a little jitter hides the steps; a lot would show as grain)
			float jitter = 0.3 + 0.4 * hash1(vec2(id) + p.screen.z * 3.7);
			float acc = 0.0;
			float norm = 0.0;
			for (int i = 0; i < steps; i++) {
				float t = (float(i) + jitter) * dt;
				vec3 q = near_world + ray * t;
				float column = surface_h(q.xz) - q.y;
				float w = exp(-ext_s * t);
				norm += w;
				if (column <= 0.0) {
					continue;
				}
				vec2 cuv = (q.xz + sun_shear * column + p.plane.zw) * p.caustics.y * UNDER_SCALE * 0.5;
				float c1 = textureLod(noise_tex, cuv + time * vec2(0.012, 0.05), 2.5).a;
				float c2 = textureLod(noise_tex, cuv * 1.37 - time * vec2(0.02, -0.035), 2.5).a;
				float beam = smoothstep(0.35, 0.8, min(c1, c2) * 1.6) - 0.16;
				// the direct beam dies quickly in silt; daylight fades with depth
				acc += beam * w * exp(-(k_s * 0.5 + sed * 2.5) * column / max(sun.y, 0.3));
			}
			float shaft = acc / max(norm, 1e-3) * (1.0 - exp(-ext_s * reach));
			// water scatters forward: shafts are brightest looking toward the sun
			float toward = max(dot(ray, sun), 0.0);
			float phase = 0.45 + 1.8 * toward * toward;
			// a trace of silt makes the beams visible
			float body = 0.55 + min(sed * 4.0, 1.2);
			vec3 lit = p.fog_color.rgb * exp(-p.downwelling.rgb * cam_depth) + p.light.rgb * 0.012;
			col += lit * shaft * phase * body * p.sun_dir.a * 2.6;
			col = max(col, vec3(0.0));
		}

		// --- suspended particles ----------------------------------------------------
		// motes on a few distance shells around the camera, fixed in the water
		// (they drift with the current and slide past as the camera moves)
		int shells = int(p.quality.y);
		if (shells > 0 && p.light.a > 0.001) {
			float motes = 0.0;
			float d = 0.14;
			for (int i = 0; i < shells; i++) {
				if (d > path) {
					break;
				}
				float cell = d * 0.085;
				vec3 q = (near_world + ray * d + vec3(p.plane.z, 0.0, p.plane.w) * 2.0) / cell;
				vec3 cid = floor(q);
				vec3 h = hash3(cid + float(i) * 19.0);
				if (h.y < p.light.a) {
					vec3 centre = 0.25 + 0.5 * hash3(cid + 7.31)
						+ 0.08 * sin(time * (0.3 + h.z) + h * 6.283);
					float rad = mix(0.035, 0.12, h.x * h.x);
					float dd = length(q - cid - centre);
					// the nearest ones are out of focus: larger and fainter
					float soft = i == 0 ? 0.05 : 0.45;
					motes += smoothstep(rad, rad * soft, dd) * (0.25 + 0.75 * h.z)
						* (i == 0 ? 0.45 : 1.0) * exp(-ext_s * d);
				}
				d *= 2.0;
			}
			vec3 lit = p.fog_color.rgb * exp(-p.downwelling.rgb * cam_depth) * 1.6 + p.light.rgb * 0.03;
			col += lit * motes * 0.5;
		}

		// --- finish ---------------------------------------------------------------------
		vec2 vc = uv - 0.5;
		col *= 1.0 - p.screen.w * smoothstep(0.25, 0.95, dot(vc, vc) * 2.6);
		// 8-bit output bands in slow dark gradients: break them up
		col *= 1.0 + (dither - 0.5) * 0.035;
		col = mix(orig, col, under);
	}

	// --- meniscus: the water climbs the lens in a thin dark line with a bright rim
	float band = exp(-sd_px * sd_px / 5.0);
	col = mix(col, p.fog_color.rgb * 0.35, band * 0.8);
	float rim = sd_px - 2.6;
	col += (p.light.rgb * 0.1 + orig * 0.25) * exp(-rim * rim / 0.9);
	imageStore(color_img, id, vec4(col, alpha));
}
