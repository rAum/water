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


## The waterfall "fluid" texture. Tileable; the shader reads it in the
## falling water's own frame: across the fall (u, about 3.4 m per tile) and
## by the moment the water left the lip (v, about 1.7 s per tile), so
## everything drawn here rides down with the water and stretches as it
## speeds up.
##
## Falling water is not stripes. What the eye reads in a real fall is:
##  - columns: the lip is uneven, so the sheet carries long streaks of
##    thicker and thinner water that persist all the way down;
##  - jets: lumps of water that surge ahead with a dense, rounded head and
##    a fraying tail of the water behind them (the "arrowheads" of a fall);
##  - fibres: fine threads and beads in between.
## The jets are splatted as particles (head downstream, tail upstream);
## columns and fibres are tileable noise.
##   r = slope across the fall (relief), g = clumps/surges (low frequency),
##   b = density of the sheet, a = fine fibres.
static func generate_fall(n: int = 512) -> ImageTexture:
	var dens := PackedFloat32Array()
	dens.resize(n * n)
	var jets := PackedFloat32Array()
	jets.resize(n * n)
	var clumps := PackedFloat32Array()
	clumps.resize(n * n)
	var fib := PackedFloat32Array()
	fib.resize(n * n)

	# --- jets: splatted lumps with a head and a tail ------------------------
	var rng := RandomNumberGenerator.new()
	rng.seed = 7351
	var fn := float(n)
	for c in 360:
		var cx := rng.randf() * fn
		var cy := rng.randf() * fn
		# small jets are common, big ones rare
		var w := lerpf(2.0, 11.0, pow(rng.randf(), 2.0))
		var tail := w * lerpf(6.0, 16.0, rng.randf())
		var amp := lerpf(0.45, 1.0, rng.randf())
		var lean := (rng.randf() - 0.5) * 0.25     # tails are not perfectly vertical
		var x0 := int(floor(cx - w * 3.0 - absf(lean) * tail))
		var x1 := int(ceil(cx + w * 3.0 + absf(lean) * tail))
		var y0 := int(floor(cy - tail))
		var y1 := int(ceil(cy + w * 2.4))
		for yy in range(y0, y1 + 1):
			var dy := cy - float(yy)        # > 0: in the tail (upstream)
			var along := 0.0
			var wt := w
			var xc := cx
			if dy > 0.0:
				var a := dy / tail
				# the head is dense, the tail thins and frays out
				along = exp(-2.4 * a) * (1.0 - a)
				wt = w * (1.0 + 0.5 * a)
				xc = cx + lean * dy
			else:
				var hy := -dy / (1.1 * w)
				along = exp(-hy * hy)
			if along < 0.01:
				continue
			var row := (((yy % n) + n) % n) * n
			for xx in range(x0, x1 + 1):
				var dx := (float(xx) - xc) / wt
				var v := amp * along * exp(-dx * dx)
				if v < 0.01:
					continue
				var k := row + (((xx % n) + n) % n)
				jets[k] = 1.0 - (1.0 - jets[k]) * (1.0 - v)

	for y in n:
		for x in n:
			var u := float(x) / fn
			var v := float(y) / fn
			# warp across, so columns wander and widths vary instead of
			# repeating like a barcode
			var wu := u + 0.04 * (_tile2(u * 3.0, v * 2.0, 3, 2, 5) - 0.5) \
				+ 0.012 * (_tile2(u * 9.0, v * 5.0, 9, 5, 6) - 0.5)
			# columns: long-lived thick and thin streaks from the uneven lip
			var col := _tile2(wu * 7.0, v * 2.0, 7, 2, 11) * 0.6 + _tile2(wu * 17.0, v * 3.0, 17, 3, 12) * 0.4
			var ridge := 1.0 - absf(2.0 * _tile2(wu * 31.0, v * 4.0, 31, 4, 21) - 1.0)
			var streak := clampf((col - 0.5) * 1.8 + 0.5, 0.0, 1.0) * (0.55 + 0.45 * pow(ridge, 1.5))
			# fibres: fine threads cut into short beads along the fall
			var fb := _tile2(wu * 120.0, v * 16.0, 120, 16, 31) * 0.6 + _tile2(wu * 230.0, v * 28.0, 230, 28, 32) * 0.4
			# clumps: surges roughly as long as wide
			var cl := _tile2(u * 6.0, v * 6.0, 6, 6, 41) * 0.6 + _tile2(u * 13.0, v * 11.0, 13, 11, 42) * 0.4
			var k := y * n + x
			clumps[k] = clampf((cl - 0.5) * 2.2 + 0.5, 0.0, 1.0)
			fib[k] = clampf((fb - 0.5) * 2.4 + 0.5, 0.0, 1.0)
			var j := jets[k]
			# the sheet: columns as a base, jets on top, fibres as grain
			var d := streak * 0.7 * (0.8 + 0.2 * fb)
			d = 1.0 - (1.0 - d) * (1.0 - j * 0.85)
			dens[k] = clampf(d * 1.15 - 0.04 + (cl - 0.5) * 0.18, 0.0, 1.0)
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
