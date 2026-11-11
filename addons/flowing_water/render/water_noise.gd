# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
class_name WaterNoise
extends RefCounted
## The one tileable RGBA texture every water shader shares:
##   r,g = surface slopes, b = height (fbm), a = foam pattern.
## The foam pattern is a warped cell-wall "lace" (two scales of Worley
## borders, broken up by fbm): thresholding it gives thin connected foam
## lines first and closed white water last, the way real river foam breaks
## up. Generated once and saved as a resource next to the shaders.


static func _h2(ix: int, iy: int, seed: int) -> float:
	var n := (ix * 374761393) ^ (iy * 668265263) ^ ((seed + 1) * 1442695041)
	n &= 0xFFFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
	return float((n ^ (n >> 16)) & 0xFFFFFFFF) / 4294967296.0


static func _tile(x: float, y: float, per: int, seed: int) -> float:
	var ix := int(floor(x))
	var iy := int(floor(y))
	var fx := x - float(ix)
	var fy := y - float(iy)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var x0 := ((ix % per) + per) % per
	var x1 := (x0 + 1) % per
	var y0 := ((iy % per) + per) % per
	var y1 := (y0 + 1) % per
	var a := _h2(x0, y0, seed)
	var b := _h2(x1, y0, seed)
	var c := _h2(x0, y1, seed)
	var d := _h2(x1, y1, seed)
	return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy


## Tileable Worley: returns F2 - F1 (0 on cell borders) for `cells` cells
## per tile at uv (0..1).
static func _worley_border(u: float, v: float, cells: int, seed: int) -> float:
	var px := u * cells
	var py := v * cells
	var cx := int(floor(px))
	var cy := int(floor(py))
	var f1 := 9.0
	var f2 := 9.0
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var gx := cx + ox
			var gy := cy + oy
			var wx := ((gx % cells) + cells) % cells
			var wy := ((gy % cells) + cells) % cells
			var jx := float(gx) + 0.15 + 0.7 * _h2(wx, wy, seed)
			var jy := float(gy) + 0.15 + 0.7 * _h2(wx, wy, seed + 17)
			var dx := jx - px
			var dy := jy - py
			var d := sqrt(dx * dx + dy * dy)
			if d < f1:
				f2 = f1
				f1 = d
			elif d < f2:
				f2 = d
	return f2 - f1


static func generate(n: int = 512) -> ImageTexture:
	var h := PackedFloat32Array()
	h.resize(n * n)
	for y in n:
		for x in n:
			var u := float(x) / float(n)
			var v := float(y) / float(n)
			var hh := 0.0
			var amp := 0.5
			var per := 4
			for o in 6:
				hh += amp * _tile(u * per, v * per, per, 50 + o)
				amp *= 0.5
				per *= 2
			h[y * n + x] = hh
	var hmin := 9.0
	var hmax := -9.0
	for k in n * n:
		hmin = minf(hmin, h[k])
		hmax = maxf(hmax, h[k])
	for k in n * n:
		h[k] = (h[k] - hmin) / (hmax - hmin)

	# foam lace: cell borders at two scales, domain-warped by the fbm
	var foam := PackedFloat32Array()
	foam.resize(n * n)
	for y in n:
		for x in n:
			var k := y * n + x
			var u := float(x) / float(n)
			var v := float(y) / float(n)
			var wu := h[y * n + (x + n / 3) % n] - 0.5
			var wv := h[((y + n / 5) % n) * n + x] - 0.5
			var b1 := _worley_border(u + wu * 0.09, v + wv * 0.09, 9, 301)
			var b2 := _worley_border(u + wu * 0.05, v + wv * 0.05, 23, 517)
			var lace1 := 1.0 - smoothstep(0.0, 0.42, b1)
			var lace2 := 1.0 - smoothstep(0.0, 0.5, b2)
			# patchy: fbm lifts some regions, thins others
			var patch := h[((y + n / 2) % n) * n + (x + n / 4) % n]
			foam[k] = clampf(lace1 * 0.55 + lace2 * 0.3 + (patch - 0.5) * 0.55 + 0.12, 0.0, 1.0)

	var out := PackedByteArray()
	out.resize(n * n * 4)
	var sx := PackedFloat32Array()
	sx.resize(n * n)
	var sy := PackedFloat32Array()
	sy.resize(n * n)
	var smax := 0.0
	for y in n:
		for x in n:
			var k := y * n + x
			sx[k] = h[y * n + (x + 1) % n] - h[y * n + (x + n - 1) % n]
			sy[k] = h[((y + 1) % n) * n + x] - h[((y + n - 1) % n) * n + x]
			smax = maxf(smax, maxf(absf(sx[k]), absf(sy[k])))
	for k in n * n:
		out[k * 4] = int(clampf((sx[k] / smax * 0.5 + 0.5) * 255.0, 0.0, 255.0))
		out[k * 4 + 1] = int(clampf((sy[k] / smax * 0.5 + 0.5) * 255.0, 0.0, 255.0))
		out[k * 4 + 2] = int(clampf(h[k] * 255.0, 0.0, 255.0))
		out[k * 4 + 3] = int(clampf(foam[k] * 255.0, 0.0, 255.0))
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, out)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _tile2(x: float, y: float, perx: int, pery: int, seed: int) -> float:
	var ix := int(floor(x))
	var iy := int(floor(y))
	var fx := x - float(ix)
	var fy := y - float(iy)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var x0 := ((ix % perx) + perx) % perx
	var x1 := (x0 + 1) % perx
	var y0 := ((iy % pery) + pery) % pery
	var y1 := (y0 + 1) % pery
	var a := _h2(x0, y0, seed)
	var b := _h2(x1, y0, seed)
	var c := _h2(x0, y1, seed)
	var d := _h2(x1, y1, seed)
	return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy


## The waterfall "fluid" texture. Falling water is not stripes: it is
## curtains of uneven width, bright ridged strands with darker gaps between
## them, fine fibres, and clumps - surges that start and stop along the fall.
## Tileable.
##   r = slope across the fall (relief), g = clumps/surges,
##   b = density of the sheet (curtains x strands x fibres), a = fine fibres.
static func generate_fall(n: int = 512) -> ImageTexture:
	var dens := PackedFloat32Array()
	dens.resize(n * n)
	var clumps := PackedFloat32Array()
	clumps.resize(n * n)
	var fib := PackedFloat32Array()
	fib.resize(n * n)
	for y in n:
		for x in n:
			var u := float(x) / float(n)
			var v := float(y) / float(n)
			# warp across, so strands wander and widths vary instead of
			# repeating like a barcode
			var wu := u + 0.045 * (_tile2(u * 3.0, v * 2.0, 3, 2, 5) - 0.5) \
				+ 0.012 * (_tile2(u * 9.0, v * 4.0, 9, 4, 6) - 0.5)
			var curtain := _tile2(wu * 4.0, v * 2.0, 4, 2, 11) * 0.6 + _tile2(wu * 9.0, v * 3.0, 9, 3, 12) * 0.4
			# ridged: thin bright strands, broader dark gaps
			var s1 := 1.0 - absf(2.0 * _tile2(wu * 19.0, v * 3.0, 19, 3, 21) - 1.0)
			var s2 := 1.0 - absf(2.0 * _tile2(wu * 43.0, v * 5.0, 43, 5, 22) - 1.0)
			var strands := pow(s1, 1.6) * 0.62 + pow(s2, 1.4) * 0.38
			var fb := _tile2(wu * 110.0, v * 7.0, 110, 7, 31) * 0.6 + _tile2(wu * 210.0, v * 11.0, 210, 11, 32) * 0.4
			# clumps: roughly as long as wide, so the fall has surges along it
			var cl := _tile2(u * 6.0, v * 6.0, 6, 6, 41) * 0.6 + _tile2(u * 13.0, v * 11.0, 13, 11, 42) * 0.4
			var k := y * n + x
			clumps[k] = clampf((cl - 0.5) * 2.2 + 0.5, 0.0, 1.0)
			fib[k] = clampf((fb - 0.5) * 2.4 + 0.5, 0.0, 1.0)
			var d := (0.25 + 0.75 * curtain) * (0.3 + 0.7 * strands) * (0.75 + 0.25 * fb)
			dens[k] = clampf(d * 1.9 - 0.12 + (cl - 0.5) * 0.3, 0.0, 1.0)
	var out := PackedByteArray()
	out.resize(n * n * 4)
	for y in n:
		for x in n:
			var k := y * n + x
			var sx := dens[y * n + (x + 1) % n] - dens[y * n + (x + n - 1) % n]
			out[k * 4] = int(clampf((sx * 2.0 + 0.5) * 255.0, 0.0, 255.0))
			out[k * 4 + 1] = int(clampf(clumps[k] * 255.0, 0.0, 255.0))
			out[k * 4 + 2] = int(clampf(dens[k] * 255.0, 0.0, 255.0))
			out[k * 4 + 3] = int(clampf(fib[k] * 255.0, 0.0, 255.0))
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, out)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## A ragged puff for spray and mist sprites (not a clean disc): white with a
## noisy, soft-edged alpha.
static func generate_puff(n: int = 128) -> ImageTexture:
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := float(x) / float(n)
			var v := float(y) / float(n)
			var d := Vector2(u - 0.5, v - 0.5).length() * 2.0
			var nz := _tile(u * 5.0, v * 5.0, 5, 71) * 0.6 + _tile(u * 11.0, v * 11.0, 11, 72) * 0.4
			var a := clampf(1.0 - smoothstep(0.25, 1.0, d + (nz - 0.5) * 0.7), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
