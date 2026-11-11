# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
class_name WaterBaker
extends RefCounted
## Port of the prototype's `bake(Q)`: depth -> Manning speed -> constant
## discharge -> pressure projection on face fluxes (non-square cells) ->
## wake, foam, aeration, surface offset -> emission points.
##
## The baker is pure math over a WaterData grid. Raycast depth is filled in by
## the node beforehand (physics queries belong to the main thread); everything
## here can run on a worker thread. The pressure iterations optionally run on
## a local RenderingDevice compute shader (red-black SOR); the GDScript loop
## is the fallback and the reference.

const SOLID_EPSILON := 0.03          # depth <= this means solid ground
const MAX_SPEED := 7.0
const MANNING_K := 25.0              # prototype: 25 * depth^(2/3) * sqrt(S)
const GRAVITY2 := 19.62              # 2 * g
const COMPUTE_MIN_CELLS := 16000     # below this GDScript is fast enough


## Preloaded on the main thread (warm_shader_cache) so worker-thread bakes
## never touch the resource loader.
static var pressure_shader_file: Resource


static func warm_shader_cache() -> void:
	if pressure_shader_file == null:
		pressure_shader_file = load("res://addons/flowing_water/bake/bake_pressure.glsl")


## Stable fingerprint of the colliders inside `aabb`: node paths relative to
## the scene plus quantized transforms, so it survives save/load and only
## changes when a collider really moved, appeared or disappeared.
static func collider_hash(scene_root: Node, aabb: AABB, mask: int, self_xform: Transform3D) -> int:
	var parts: Array = [_xform_key(self_xform)]
	if scene_root == null:
		return hash(parts)
	var stack: Array[Node] = [scene_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is CollisionObject3D:
			var co := node as CollisionObject3D
			if (co.collision_layer & mask) != 0 and aabb.has_point(co.global_position):
				parts.append(str(scene_root.get_path_to(co)))
				parts.append(_xform_key(co.global_transform))
	return hash(parts)


static func _xform_key(t: Transform3D) -> Array:
	return [
		roundi(t.origin.x * 100.0), roundi(t.origin.y * 100.0), roundi(t.origin.z * 100.0),
		roundi(t.basis.x.x * 500.0), roundi(t.basis.x.y * 500.0), roundi(t.basis.x.z * 500.0),
		roundi(t.basis.y.x * 500.0), roundi(t.basis.y.y * 500.0), roundi(t.basis.y.z * 500.0),
		roundi(t.basis.z.x * 500.0), roundi(t.basis.z.y * 500.0), roundi(t.basis.z.z * 500.0),
	]


class BakeParams:
	extends RefCounted
	var discharge := 1.5                      # m^3/s
	var waterfall_threshold := 0.3            # slope above which a row is a fall
	var plunge_length := 2.7                  # m of plunge foam below a fall
	var pressure_iterations := 100
	var use_compute := true
	## Optional inlet flux profile for row 0 (m^3/s per cell). When set, it
	## replaces the Manning guess on row 0 (pond -> river outlets).
	var inlet_flux := PackedFloat32Array()
	var inlet_foam := PackedFloat32Array()
	var inlet_aeration := PackedFloat32Array()
	## Pond mode: no Manning/discharge; flow is driven by inlets and outlets.
	var pond_mode := false
	## Pond inlets/outlets: arrays of cell indices; fluxes in m^3/s per cell.
	var pond_inlet_cells := PackedInt32Array()
	var pond_inlet_fluxes := PackedFloat32Array()
	var pond_inlet_foam := PackedFloat32Array()
	var pond_inlet_aeration := PackedFloat32Array()
	var pond_inlet_dirs := PackedVector2Array()   # grid-space (di, dj), normalized
	var pond_outlet_cells := PackedInt32Array()
	## Metres over which an inlet's momentum decays inside the pond.
	var pond_jet_length := 9.0
	## Plunge points (waterfall landing in a pond): cell indices + strength.
	var plunge_cells := PackedInt32Array()
	var plunge_strengths := PackedFloat32Array()


## Runs the whole bake except texture building. `progress` is an optional
## Callable(float frac, String phase) and may be called from a worker thread.
static func bake(data: WaterData, p: BakeParams, progress: Callable = Callable()) -> void:
	var t0 := Time.get_ticks_usec()
	var nx := data.cells_across
	var nz := data.rows
	var nc := nx * nz
	var dz := data.cell_length

	var depth := data.depth
	var solid := PackedByteArray()
	solid.resize(nc)
	var obst := PackedByteArray()
	obst.resize(nc)
	var vx := PackedFloat32Array()
	vx.resize(nc)
	var vz := PackedFloat32Array()
	vz.resize(nc)

	_report(progress, 0.02, "Classifying cells")

	# --- waterfalls: where every column of water leaves the ground -------------
	# eff = the row whose fall progress a cell has (its own row off falls);
	# air = 1 where the cell is in free fall.
	var fall_row := PackedByteArray()
	fall_row.resize(nz)
	var eff := PackedInt32Array()
	eff.resize(nc)
	var air := PackedByteArray()
	air.resize(nc)
	for k in nc:
		eff[k] = k / nx
	var falls: Array[Dictionary] = []
	var ray_depth := PackedFloat32Array()
	data.fall_lead = PackedFloat32Array()
	data.fall_throw = PackedFloat32Array()
	if not p.pond_mode:
		for j in nz:
			fall_row[j] = 1 if data.row_slope[j] > p.waterfall_threshold else 0
		ray_depth = depth.duplicate()
		falls = _find_brinks(data, depth, fall_row)

	# --- solids and obstacles -------------------------------------------------
	# An obstacle is a solid cell with water on both sides across the row; a
	# solid cell connected to the bank is not.
	for j in nz:
		var row := j * nx
		for i in nx:
			solid[row + i] = 1 if depth[row + i] <= SOLID_EPSILON else 0
		# bank-connected runs from the left and from the right
		var i2 := 0
		while i2 < nx and solid[row + i2] == 1:
			i2 += 1
		var left_end := i2
		i2 = nx - 1
		while i2 >= 0 and solid[row + i2] == 1:
			i2 -= 1
		var right_start := i2
		for i in nx:
			obst[row + i] = 1 if (solid[row + i] == 1 and i >= left_end and i <= right_start) else 0

	# --- 1. Manning first guess, scaled to constant discharge ------------------
	_report(progress, 0.06, "Initial speeds")
	var q := p.discharge
	for j in nz:
		var row := j * nx
		var dxj := data.row_cell_width[j]
		var s := maxf(data.row_slope[j], 0.002)
		var sqrt_s := sqrt(s)
		var qsum := 0.0
		for i in nx:
			var k := row + i
			if solid[k] == 1:
				vz[k] = 0.0
				continue
			var v := clampf(MANNING_K * pow(depth[k], 2.0 / 3.0) * sqrt_s, 0.2, 6.0)
			vz[k] = v
			qsum += v * depth[k] * dxj
		if p.pond_mode:
			# ponds start at rest; flow comes only from the pressure solve
			for i in nx:
				vz[row + i] = 0.0
		else:
			var sc := q / qsum if qsum > 1e-6 else 0.0
			for i in nx:
				var k := row + i
				if solid[k] == 0:
					vz[k] = clampf(vz[k] * sc, 0.05, MAX_SPEED)

	# --- 2. Pressure projection on face fluxes ---------------------------------
	_report(progress, 0.12, "Setting up pressure solve")
	# FZ: (nz+1) x nx fluxes between rows; FX: nz x (nx+1) fluxes across.
	var fz := PackedFloat32Array()
	fz.resize((nz + 1) * nx)
	var kz := PackedFloat32Array()
	kz.resize((nz + 1) * nx)
	var fx := PackedFloat32Array()
	fx.resize(nz * (nx + 1))
	var kx := PackedFloat32Array()
	kx.resize(nz * (nx + 1))
	var div := PackedFloat32Array()
	div.resize(nc)
	var pres := PackedFloat32Array()
	pres.resize(nc)
	# Open outlet mask per cell (pond outlets; river outlet is the last row).
	var open_out := PackedFloat32Array()
	open_out.resize(nc)

	if p.pond_mode:
		# all outer faces closed; fluxes start at zero
		for f in fz.size():
			fz[f] = 0.0
			kz[f] = 0.0
		for g in fx.size():
			fx[g] = 0.0
			kx[g] = 0.0
		for j in range(1, nz):
			for i in nx:
				var a := (j - 1) * nx + i
				var b := j * nx + i
				if solid[a] == 0 and solid[b] == 0:
					kz[j * nx + i] = data.row_cell_width[j] / dz
		for j in nz:
			for i in range(1, nx):
				if solid[j * nx + i - 1] == 0 and solid[j * nx + i] == 0:
					kx[j * (nx + 1) + i] = dz / data.row_cell_width[j]
		# Inflow carries momentum: seed a decaying jet from every inlet cell
		# along the river's direction. The projection below then makes the
		# whole field mass-conserving, which turns the jet into a fan at the
		# mouth, a slow current across the pond and return eddies in the bays.
		for n in p.pond_inlet_cells.size():
			var k0 := p.pond_inlet_cells[n]
			if k0 < 0 or k0 >= nc or solid[k0] == 1:
				continue
			var jdir := p.pond_inlet_dirs[n] if n < p.pond_inlet_dirs.size() else Vector2(0, 1)
			var flux0 := p.pond_inlet_fluxes[n]
			var fi := float(k0 % nx) + 0.5
			var fj := float(k0 / nx) + 0.5
			var travelled := 0.0
			while travelled < p.pond_jet_length * 3.0:
				var ci := int(fi)
				var cj := int(fj)
				if ci < 1 or cj < 1 or ci >= nx - 1 or cj >= nz - 1 or solid[cj * nx + ci] == 1:
					break
				var f := flux0 * exp(-travelled / p.pond_jet_length)
				# add to the downstream faces of this cell (only open faces)
				var gx_face := cj * (nx + 1) + ci + (1 if jdir.x >= 0.0 else 0)
				if kx[gx_face] > 0.0:
					fx[gx_face] += f * jdir.x
				var gz_face := (cj + (1 if jdir.y >= 0.0 else 0)) * nx + ci
				if kz[gz_face] > 0.0:
					fz[gz_face] += f * jdir.y
				fi += jdir.x * dz / data.row_cell_width[cj]
				fj += jdir.y
				travelled += dz
		for j in nz:
			for i in nx:
				var k := j * nx + i
				pres[k] = 0.0
				div[k] = fx[j * (nx + 1) + i + 1] - fx[j * (nx + 1) + i] \
					+ fz[(j + 1) * nx + i] - fz[j * nx + i]
		# inlets: injected volume shows up as negative divergence
		for n in p.pond_inlet_cells.size():
			var k := p.pond_inlet_cells[n]
			if k >= 0 and k < nc and solid[k] == 0:
				div[k] -= p.pond_inlet_fluxes[n]
		# outlets: conductance to outside pressure 0
		for n in p.pond_outlet_cells.size():
			var k := p.pond_outlet_cells[n]
			if k >= 0 and k < nc and solid[k] == 0:
				open_out[k] = data.row_cell_width[k / nx] / dz
	else:
		# river: faces between rows carry the Manning flux, inlet fixed, outlet open
		for j in nz + 1:
			var dx_a := data.row_cell_width[j - 1] if j > 0 else 0.0
			var dx_b := data.row_cell_width[j] if j < nz else 0.0
			for i in nx:
				var f := j * nx + i
				var fa := -2.0
				var fb := -2.0
				if j > 0:
					var a := (j - 1) * nx + i
					fa = -1.0 if solid[a] == 1 else vz[a] * depth[a] * dx_a
				if j < nz:
					var b := j * nx + i
					fb = -1.0 if solid[b] == 1 else vz[b] * depth[b] * dx_b
				if fa == -1.0 or fb == -1.0:
					fz[f] = 0.0
					kz[f] = 0.0
				elif fa == -2.0:
					# inlet: fixed flux
					if p.inlet_flux.size() == nx:
						fz[f] = p.inlet_flux[i]
					else:
						fz[f] = fb
					kz[f] = 0.0
				elif fb == -2.0:
					fz[f] = fa
					kz[f] = dx_a / dz          # outlet: open
				else:
					fz[f] = 0.5 * (fa + fb)
					kz[f] = 0.5 * (dx_a + dx_b) / dz
		for j in nz:
			for i in nx + 1:
				var g := j * (nx + 1) + i
				fx[g] = 0.0
				if i == 0 or i == nx or solid[j * nx + i - 1] == 1 or solid[j * nx + i] == 1:
					kx[g] = 0.0
				else:
					kx[g] = dz / data.row_cell_width[j]
		for j in nz:
			for i in nx:
				var k := j * nx + i
				pres[k] = 0.0
				div[k] = fx[j * (nx + 1) + i + 1] - fx[j * (nx + 1) + i] \
					+ fz[(j + 1) * nx + i] - fz[j * nx + i]

	_report(progress, 0.18, "Pressure solve")
	var solved_on_gpu := false
	if p.use_compute and nc >= COMPUTE_MIN_CELLS:
		solved_on_gpu = _solve_pressure_compute(pres, div, kx, kz, open_out, solid, nx, nz, p.pressure_iterations, p.pond_mode)
	if not solved_on_gpu:
		_solve_pressure_gdscript(pres, div, kx, kz, open_out, solid, nx, nz, p.pressure_iterations, p.pond_mode, progress)

	_report(progress, 0.55, "Applying pressure")
	# correct fluxes with the pressure gradient
	for j in range(1, nz + 1):
		for i in nx:
			var f := j * nx + i
			if kz[f] == 0.0:
				continue
			var hi := pres[j * nx + i] if j < nz else 0.0
			fz[f] -= kz[f] * (hi - pres[(j - 1) * nx + i])
	for j in nz:
		for i in range(1, nx):
			var g := j * (nx + 1) + i
			if kx[g] == 0.0:
				continue
			fx[g] -= kx[g] * (pres[j * nx + i] - pres[j * nx + i - 1])

	# velocities from fluxes
	var tmp := PackedFloat32Array()
	tmp.resize(nc)
	var tmp2 := PackedFloat32Array()
	tmp2.resize(nc)
	for j in nz:
		var dxj := data.row_cell_width[j]
		for i in nx:
			var k := j * nx + i
			if solid[k] == 1:
				tmp[k] = 0.0
				tmp2[k] = 0.0
				continue
			var hh := maxf(depth[k], 0.06)
			var ux := 0.5 * (fx[j * (nx + 1) + i] + fx[j * (nx + 1) + i + 1]) / dz / hh
			var uz := 0.5 * (fz[j * nx + i] + fz[(j + 1) * nx + i]) / dxj / hh
			var m := sqrt(ux * ux + uz * uz)
			if m > MAX_SPEED:
				ux *= MAX_SPEED / m
				uz *= MAX_SPEED / m
			tmp[k] = ux
			tmp2[k] = uz
	_blur(tmp, vx, solid, nx, nz)
	_blur(tmp2, vz, solid, nx, nz)

	# --- waterfalls: every column falls on its own arc ----------------------------
	# A column leaves its brink with the speed the solve gave it there, so it
	# is thrown as far as that speed carries it: the fast middle of the
	# channel arcs out to the foot of the curve, the slow shallow edges drop
	# closer to the rock. On the way down v = sqrt(v0^2 + 2 g h) and the sheet
	# thins so that thickness x speed stays what it was at the brink.
	var fall_wet := PackedFloat32Array()
	var air_off := PackedFloat32Array()
	air_off.resize(nc)
	if not falls.is_empty():
		data.fall_lead.resize(nc)
		data.fall_throw.resize(nc)
		data.fall_throw.fill(1.0)
		fall_wet.resize(nc)
		fall_wet.fill(1.0)
	for fl in falls:
		var j_lip: int = fl["j_lip"]
		var j_foot: int = fl["j_foot"]
		var lead: PackedInt32Array = fl["lead"]
		var lead_f: PackedFloat32Array = fl["lead_f"]
		var col_d: PackedFloat32Array = fl["col_d"]
		var dry: PackedByteArray = fl["dry"]
		var taper: PackedFloat32Array = fl["taper"]
		var h_top: float = data.row_height[maxi(j_lip - 1, 0)]
		var h_foot: float = data.row_height[mini(j_foot, nz - 1)]
		var n_rows := float(j_foot - j_lip)
		var col_v := PackedFloat32Array()
		col_v.resize(nx)
		var v_sum := 0.0
		var v_n := 0
		for i in nx:
			var kb := maxi(j_lip - 1 - lead[i], 0) * nx + i
			col_v[i] = 0.0
			if solid[kb] == 0 and dry[i] == 0 and j_lip > 0:
				col_v[i] = sqrt(vx[kb] * vx[kb] + vz[kb] * vz[kb])
				v_sum += col_v[i]
				v_n += 1
		var v0 := clampf(v_sum / float(v_n), 0.5, MAX_SPEED) if v_n > 0 and v_sum > 0.05 else 1.5
		# a rock on the brink or a dry bank has no speed of its own: it takes
		# its neighbour's, so the sheet is not sheared where it ends
		var last_v := 0.0
		for i in nx:
			if col_v[i] > 0.05:
				last_v = clampf(col_v[i], 0.6 * v0, 1.6 * v0)
			col_v[i] = last_v
		last_v = v0
		for i in range(nx - 1, -1, -1):
			if col_v[i] > 0.05:
				last_v = col_v[i]
			col_v[i] = last_v
		for pass_n in 5:
			var prev := col_v.duplicate()
			for i in nx:
				col_v[i] = 0.25 * prev[maxi(i - 1, 0)] + 0.5 * prev[i] + 0.25 * prev[mini(i + 1, nx - 1)]
		# the curve's foot is where ordinary fast water lands: a single jet
		# squeezed past a rock must not make everything else fall short
		var v_max := v0 * 1.1
		fl["v0"] = v0
		var fade_rows := maxi(int(0.5 / dz), 1)
		var win: int = fl["win"]
		for i in nx:
			var throw := clampf(col_v[i] / v_max, 0.75, 1.0)
			var vi := col_v[i]
			for jj in range(maxi(j_lip - win - 1, 0), j_foot):
				data.fall_lead[jj * nx + i] = lead_f[i] * dz
				data.fall_throw[jj * nx + i] = throw
			for jj in range(maxi(j_lip - lead[i], 0), j_foot):
				var k := jj * nx + i
				var x := float(jj - j_lip + lead[i]) + 0.5
				var t := x / maxf(n_rows * throw, 1.0)
				if t < 1.0:
					var je := mini(j_lip + int(t * n_rows), j_foot - 1)
					eff[k] = je
					air[k] = 1
					if dry[i] == 1:
						fall_wet[k] = 0.0
					if solid[k] == 1:
						continue
					var drop := maxf(h_top - data.row_height[je], 0.0)
					var vfall := minf(sqrt(vi * vi + GRAVITY2 * drop), MAX_SPEED)
					var into_end := j_foot - je
					if into_end <= fade_rows:
						vfall *= float(into_end) / float(fade_rows + 1)
					# in free fall the "depth" is the thickness of the sheet: the
					# brink depth (0.715 of the flow depth), thinning as it speeds
					# up, and thin toward the edges of the fall
					var sheet := clampf(col_d[i] * 0.715 * vi / maxf(vfall, vi), 0.035, maxf(col_d[i], 0.035))
					# (easing in from the river's own depth over the first
					# half metre, so nothing jumps at the brink)
					var ease := smoothstep(0.0, 1.0, x * dz / 0.6)
					depth[k] = lerpf(maxf(col_d[i], sheet), sheet, ease) * lerpf(0.12, 1.0, taper[i])
					# the surface was drawn down toward the brink: it leaves at
					# that height and the arc takes over from there
					air_off[k] = -0.285 * col_d[i] * (1.0 - ease)
					vx[k] *= 0.3
					if vz[k] < vfall:
						vz[k] = vfall
				else:
					# this column has landed already: pool water at the foot level
					eff[k] = mini(j_foot + int(x - n_rows * throw), nz - 1)
					var pool := ray_depth[k] - (data.row_height[jj] - h_foot)
					if pool > SOLID_EPSILON:
						depth[k] = pool
						if solid[k] == 1:
							solid[k] = 0
							vx[k] = 0.0
							vz[k] = 0.3
					else:
						depth[k] = 0.0
						solid[k] = 1
						vx[k] = 0.0
						vz[k] = 0.0
	# water breaks a little as it speeds up over a brink: a lace of foam
	# across it, which also carries the river's surface over the edge
	var brink_foam := PackedFloat32Array()
	brink_foam.resize(nc)
	for fl in falls:
		var lead_b: PackedInt32Array = fl["lead"]
		var dry_b: PackedByteArray = fl["dry"]
		var reach_b := maxi(int(0.9 / dz), 2)
		for i in nx:
			if dry_b[i] == 1:
				continue
			var jb: int = fl["j_lip"] - lead_b[i]
			for o in range(-reach_b, reach_b + 1):
				var jj := jb + o
				if jj < 0 or jj >= nz:
					continue
				var w := 1.0 - absf(float(o)) / float(reach_b + 1)
				brink_foam[jj * nx + i] = maxf(brink_foam[jj * nx + i], w * w)
	# slope per cell: what its part of the water is doing (a column that left
	# the ground early is already falling, one that landed early is pool)
	var cell_slope := PackedFloat32Array()
	cell_slope.resize(nc)
	for k in nc:
		cell_slope[k] = data.row_slope[eff[k]] if not p.pond_mode and data.row_slope.size() == nz else 0.0
	data.cell_slope = cell_slope

	# --- 3. derived maps ---------------------------------------------------------
	_report(progress, 0.62, "Foam and wakes")
	var row_mean := PackedFloat32Array()
	row_mean.resize(nz)
	var max_s := 0.0
	var pool := 99.0
	for j in nz:
		var s := 0.0
		var c := 0
		var row := j * nx
		for i in nx:
			var k := row + i
			if solid[k] == 0:
				var sp := sqrt(vx[k] * vx[k] + vz[k] * vz[k])
				s += sp
				c += 1
				if sp > max_s:
					max_s = sp
		row_mean[j] = s / c if c > 0 else 0.0
		if c > 6 and row_mean[j] < pool:
			pool = row_mean[j]
	data.max_speed = max_s
	data.min_row_speed = pool if pool < 99.0 else 0.0
	data.row_mean_speed = row_mean

	# wake behind obstacles: trace upstream, 12 steps of 0.25 m
	var wake := PackedFloat32Array()
	wake.resize(nc)
	for j in nz:
		var dxj := data.row_cell_width[j]
		for i in nx:
			var k := j * nx + i
			wake[k] = 0.0
			if solid[k] == 1:
				continue
			var fi := float(i)
			var fj := float(j)
			for n in range(1, 13):
				var ci := clampi(int(round(fi)), 0, nx - 1)
				var cj := clampi(int(round(fj)), 0, nz - 1)
				var cc := cj * nx + ci
				var wx := vx[cc]
				var wz := vz[cc]
				var wl := sqrt(wx * wx + wz * wz)
				if wl < 0.05:
					# still water has no wake
					if p.pond_mode:
						break
					wx = 0.0
					wz = 1.0
					wl = 1.0
				fi -= wx / wl * 0.25 / dxj
				fj -= wz / wl * 0.25 / dz
				if fj < 0.0 or fi < 0.0 or fi > float(nx - 1):
					break
				var oi := clampi(int(round(fi)), 0, nx - 1)
				var oj := clampi(int(round(fj)), 0, nz - 1)
				if obst[oj * nx + oi] == 1:
					# a wake needs moving water: it fades out below 0.5 m/s
					var here := sqrt(vx[k] * vx[k] + vz[k] * vz[k])
					wake[k] = (1.0 - float(n) / 13.0) * smoothstep(0.08, 0.5, here)
					break

	# plunge factor per row: rows within the plunge length after a fall
	# section; higher falls churn a longer reach
	var plunge_row := PackedFloat32Array()
	plunge_row.resize(nz)
	if not p.pond_mode:
		var plunge_rows := int(p.plunge_length / dz)
		var since_fall := 1 << 20
		var fall_top := 0.0
		var in_fall := false
		var reach := plunge_rows
		for j in nz:
			if fall_row[j] == 1:
				if not in_fall:
					in_fall = true
					fall_top = data.row_height[j]
				since_fall = 0
				plunge_row[j] = 0.0
				var drop := maxf(fall_top - data.row_height[j], 0.0)
				reach = int(float(plunge_rows) * clampf(sqrt(drop / 1.5), 1.0, 2.2))
			else:
				in_fall = false
				since_fall += 1
				if since_fall <= reach:
					plunge_row[j] = 1.0 - float(since_fall) / float(reach + 1)

	# In a waterfall the water is in free fall: nothing closes the gap a
	# rock tears in the sheet, so the parted strip runs to the foot of the
	# fall and spreads a little on the way down.
	if not p.pond_mode:
		for j in range(1, nz):
			var row := j * nx
			for i in nx:
				var k := row + i
				if solid[k] == 1 or air[k] == 0:
					continue
				var up := k - nx
				var carried := wake[up] if solid[up] == 0 else 1.0
				var l := wake[up - 1] if i > 0 and solid[up - 1] == 0 else (1.0 if i > 0 and solid[up - 1] == 1 and obst[up - 1] == 1 else 0.0)
				var r := wake[up + 1] if i < nx - 1 and solid[up + 1] == 0 else (1.0 if i < nx - 1 and solid[up + 1] == 1 and obst[up + 1] == 1 else 0.0)
				if solid[up] == 1 and obst[up] == 0:
					carried = 0.0
				wake[k] = maxf(wake[k], maxf(carried * 0.985, maxf(l, r) * 0.3))

	# foam and surface offset
	for j in nz:
		var dxj := data.row_cell_width[j]
		var vm := row_mean[j]
		for i in nx:
			var k := j * nx + i
			if solid[k] == 1:
				tmp[k] = 0.0
				tmp2[k] = 0.0
				continue
			var s2 := cell_slope[k]
			var sp := sqrt(vx[k] * vx[k] + vz[k] * vz[k])
			var jm := maxi(j - 1, 0)
			var jp := mini(j + 1, nz - 1)
			var im := maxi(i - 1, 0)
			var ip := mini(i + 1, nx - 1)
			var sp_jp := sqrt(vx[jp * nx + i] * vx[jp * nx + i] + vz[jp * nx + i] * vz[jp * nx + i])
			var sp_jm := sqrt(vx[jm * nx + i] * vx[jm * nx + i] + vz[jm * nx + i] * vz[jm * nx + i])
			var sp_ip := sqrt(vx[j * nx + ip] * vx[j * nx + ip] + vz[j * nx + ip] * vz[j * nx + ip])
			var sp_im := sqrt(vx[j * nx + im] * vx[j * nx + im] + vz[j * nx + im] * vz[j * nx + im])
			var gz := absf(sp_jp - sp_jm) / (2.0 * dz)
			var gx := absf(sp_ip - sp_im) / (2.0 * dxj)
			var riffle := 0.35 if (depth[k] < 0.15 and sp > 1.0) else 0.0
			var fo := maxf(0.0, s2 - 0.03) * 3.0 + wake[k] * 0.75 + (gz + gx) * 0.1 \
				+ riffle + plunge_row[eff[k]] + maxf(0.0, sp - 2.5) * 0.12 + brink_foam[k] * 0.45
			# A waterfall is the same river, only faster: its white water comes
			# from the slope and speed terms above, which rise smoothly from
			# the lip - there is no switch at the threshold.
			tmp[k] = clampf(fo, 0.0, 1.0)
			# the Bernoulli surface offset fades out as the water goes into
			# free fall
			var free_fall := smoothstep(p.waterfall_threshold * 0.5, p.waterfall_threshold * 1.5, s2)
			tmp2[k] = (clampf(0.6 * (vm * vm - sp * sp) / GRAVITY2, -0.12, 0.12) - wake[k] * 0.05) * (1.0 - free_fall)
			if air[k] == 1:
				tmp2[k] = 0.0
	# pond plunge points (waterfall landing)
	for n in p.plunge_cells.size():
		var k := p.plunge_cells[n]
		if k >= 0 and k < nc and solid[k] == 0:
			_splat(tmp, k, nx, nz, p.plunge_strengths[n], 10)
	var foam := PackedFloat32Array()
	foam.resize(nc)
	var off := PackedFloat32Array()
	off.resize(nc)
	_blur(tmp, foam, solid, nx, nz)
	_blur(tmp2, off, solid, nx, nz)

	# the surface draws down toward a brink: the flow speeds up and thins
	# over the last metre before it goes over
	for fl in falls:
		var lead: PackedInt32Array = fl["lead"]
		var col_d: PackedFloat32Array = fl["col_d"]
		var reach := maxi(int(1.2 / dz), 1)
		for i in nx:
			for back in range(1, reach + 1):
				var j: int = fl["j_lip"] - lead[i] - back
				if j < 0:
					break
				var w := 1.0 - float(back - 1) / float(reach)
				var k := j * nx + i
				if solid[k] == 0:
					off[k] = minf(off[k], lerpf(off[k], -0.285 * col_d[i], w * w))
	for k in nc:
		if air[k] == 1:
			off[k] = air_off[k]
	# Water that reaches the side of the ribbon has no bank to hold it (the
	# ground beside the river is lower than its surface): it spills. The
	# surface is drawn down to the bed over the last stretch, so the river
	# meets the ground there instead of ending in a cut hanging in the air.
	if not p.pond_mode:
		for j in nz:
			var n_sp := clampi(int(0.9 / maxf(data.row_cell_width[j], 0.01)), 2, nx / 3)
			for side_n in 2:
				var i0 := 0 if side_n == 0 else nx - 1
				var step := 1 if side_n == 0 else -1
				if solid[j * nx + i0] == 1:
					continue
				for c in n_sp:
					var k := j * nx + i0 + c * step
					if solid[k] == 1:
						break
					if air[k] == 1:
						continue
					var w := 1.0 - float(c) / float(n_sp)
					off[k] = minf(off[k], lerpf(off[k], -depth[k], w * w * (3.0 - 2.0 * w)))

	# --- aeration: foam carried downstream ---------------------------------------
	_report(progress, 0.74, "Aeration")
	var aer := PackedFloat32Array()
	aer.resize(nc)
	if p.pond_mode:
		_advect_pond_aeration(aer, foam, vx, vz, solid, data, p)
	else:
		var decay := exp(-dz / 5.0)
		for j in nz:
			var row := j * nx
			for i in nx:
				var k := row + i
				var up := 0.0
				if j > 0:
					var u0 := k - nx
					var ul := u0 - (1 if i > 0 else 0)
					var ur := u0 + (1 if i < nx - 1 else 0)
					up = 0.5 * aer[u0] + 0.25 * aer[ul] + 0.25 * aer[ur]
				elif p.inlet_aeration.size() == nx:
					up = p.inlet_aeration[i]
				aer[k] = 0.0 if solid[k] == 1 else maxf(foam[k] * 0.9, up * decay)
		# inlet foam carried in (river continuing from a pond)
		if p.inlet_foam.size() == nx:
			for i in nx:
				var k := i
				if solid[k] == 0:
					foam[k] = maxf(foam[k], p.inlet_foam[i])

	# --- no holes around rocks -------------------------------------------------------
	# A rock standing in the water is solid for the flow solve, but the water
	# surface must not stop short of it: fill the cells under obstacles from
	# the water around them (depth, velocity, foam, offset). The rock itself
	# then simply stands in continuous water. Banks stay as they are.
	var has_data := PackedByteArray()
	has_data.resize(nc)
	for k in nc:
		has_data[k] = 1 if solid[k] == 0 else 0
	for fill_pass in 40:
		var cells := PackedInt32Array()
		var v_depth := PackedFloat32Array()
		var v_vx := PackedFloat32Array()
		var v_vz := PackedFloat32Array()
		var v_off := PackedFloat32Array()
		var v_aer := PackedFloat32Array()
		var v_foam := PackedFloat32Array()
		for j in nz:
			for i in nx:
				var k := j * nx + i
				if obst[k] == 0 or has_data[k] == 1:
					continue
				var cnt := 0.0
				var sd := 0.0
				var sx := 0.0
				var sz := 0.0
				var so := 0.0
				var sa := 0.0
				var mf := 0.0
				for nb: int in [k - 1 if i > 0 else -1, k + 1 if i < nx - 1 else -1,
						k - nx if j > 0 else -1, k + nx if j < nz - 1 else -1]:
					if nb >= 0 and has_data[nb] == 1:
						cnt += 1.0
						sd += depth[nb]
						sx += vx[nb]
						sz += vz[nb]
						so += off[nb]
						sa += aer[nb]
						mf = maxf(mf, foam[nb])
				if cnt > 0.0:
					cells.append(k)
					v_depth.append(sd / cnt)
					v_vx.append(sx / cnt)
					v_vz.append(sz / cnt)
					v_off.append(so / cnt)
					v_aer.append(sa / cnt)
					v_foam.append(mf)
		if cells.is_empty():
			break
		for n in cells.size():
			var k := cells[n]
			depth[k] = v_depth[n]
			vx[k] = v_vx[n]
			vz[k] = v_vz[n]
			off[k] = v_off[n]
			aer[k] = v_aer[n]
			foam[k] = v_foam[n]
			has_data[k] = 1
	data.depth = depth
	data.obstacle = obst
	# what the mesh needs to build the falling sheet: its thickness where the
	# water is in the air, and where there is no sheet at all
	data.fall_wet = fall_wet
	data.fall_sheet = PackedFloat32Array()
	if not falls.is_empty():
		data.fall_sheet.resize(nc)
		for k in nc:
			data.fall_sheet[k] = depth[k] * fall_wet[k] if air[k] == 1 else 0.0

	# --- write back ----------------------------------------------------------------
	data.vel_across = vx
	data.vel_along = vz
	data.foam = foam
	data.aeration = aer
	data.wake = wake
	data.surface_offset = off
	data.discharge = p.discharge
	data.total_drop = (data.row_height[0] - data.row_height[nz - 1]) if data.row_height.size() == nz else 0.0

	_report(progress, 0.85, "Emission points")
	_build_emission_points(data, p, solid, foam, aer, vx, vz, air, eff, plunge_row)

	data.bake_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	data.baked_at = Time.get_datetime_string_from_system()
	_report(progress, 0.95, "Done")


## Finds every waterfall section and, for each column across it, the brink:
## the last cell with ground under the water. A cell hanging over the drop
## (bed far below the surface, compared with the channel upstream) is already
## in the air, so the fall starts where the rock ends, not on one straight
## line across the ribbon, and a bank that is dry at the brink stays dry all
## the way down. Rewrites `depth` for the solve and returns one Dictionary per
## fall: j_lip, j_foot (exclusive), win, lead (rows the brink lies upstream of
## j_lip, per column), lead_f (the same, unrounded), col_d (flow depth at the
## brink), dry (1 = no water goes over here), taper (0 at the sheet's edges).
static func _find_brinks(data: WaterData, depth: PackedFloat32Array, fall_row: PackedByteArray) -> Array[Dictionary]:
	var nx := data.cells_across
	var nz := data.rows
	var dz := data.cell_length
	var has_t := data.row_fall_t.size() == nz
	var out: Array[Dictionary] = []
	var j := 0
	while j < nz:
		if not (fall_row[j] == 1 or (has_t and data.row_fall_t[j] > 0.0)):
			j += 1
			continue
		var j_lip := j
		while j < nz and (fall_row[j] == 1 or (has_t and data.row_fall_t[j] > 0.0)):
			j += 1
		var j_foot := j
		var win := clampi(int(2.5 / dz), 0, maxi(j_lip - 1, 0))
		var lead := PackedInt32Array()
		lead.resize(nx)
		var col_d := PackedFloat32Array()
		col_d.resize(nx)
		col_d.fill(0.3)
		var wet := PackedByteArray()
		wet.resize(nx)
		wet.fill(1)
		var d_mean := 0.3
		if j_lip >= 1:
			# the channel just upstream is the reference for "ground under it"
			var sum := 0.0
			var cnt := 0
			var col_ref := PackedFloat32Array()
			col_ref.resize(nx)
			for jr in range(maxi(j_lip - win - 4, 0), maxi(j_lip - win, 1)):
				for i in nx:
					var d := depth[jr * nx + i]
					if d > SOLID_EPSILON and d < 3.9:
						sum += d
						cnt += 1
						for o in range(-1, 2):
							var io := clampi(i + o, 0, nx - 1)
							col_ref[io] = maxf(col_ref[io], d)
			if cnt > 0:
				d_mean = sum / float(cnt)
			var limit := maxf(2.5 * d_mean, d_mean + 0.3)
			var drop := data.row_height[j_lip - 1] - data.row_height[j_foot - 1]
			var use_lead := win >= 1 and drop > limit + 0.2
			for i in nx:
				var l := 0
				# at the lip the bed must be clearly gone; from there the brink
				# is followed upstream to where the column is as deep as it
				# was in the channel above (a bank that sags toward the drop
				# has no water standing on it: it runs off)
				var limit_i := minf(limit, 1.6 * col_ref[i] + 0.08)
				if use_lead and depth[(j_lip - 1) * nx + i] > maxf(limit_i, 0.6 * limit):
					while l < win and depth[(j_lip - 1 - l) * nx + i] > limit_i:
						l += 1
				lead[i] = l
				var db := depth[(j_lip - 1 - l) * nx + i]
				wet[i] = 1 if db > SOLID_EPSILON else 0
				col_d[i] = clampf(db, 0.0, limit)
		var first_wet := 0
		while first_wet < nx and wet[first_wet] == 0:
			first_wet += 1
		var last_wet := nx - 1
		while last_wet >= 0 and wet[last_wet] == 0:
			last_wet -= 1
		if first_wet > last_wet:
			# nothing reaches the brink: leave the rows as they are
			first_wet = 0
			last_wet = nx - 1
			wet.fill(1)
		var dry := PackedByteArray()
		dry.resize(nx)
		for i in nx:
			dry[i] = 1 if (i < first_wet or i > last_wet) else 0
			if i < first_wet:
				lead[i] = lead[first_wet]
			elif i > last_wet:
				lead[i] = lead[last_wet]
			elif wet[i] == 0:
				# a rock standing on the brink: water flows round it
				col_d[i] = d_mean
		# neighbouring columns leave the ground together: widen to the
		# earliest brink nearby, then smooth, so the sheet has no steps
		var lead_f := PackedFloat32Array()
		lead_f.resize(nx)
		for i in nx:
			var m := 0
			for o in range(-2, 3):
				m = maxi(m, lead[clampi(i + o, 0, nx - 1)])
			lead_f[i] = float(m)
		for pass_n in 2:
			var prev := lead_f.duplicate()
			var prev_d := col_d.duplicate()
			for i in nx:
				var a := maxi(i - 1, 0)
				var b := mini(i + 1, nx - 1)
				lead_f[i] = 0.25 * prev[a] + 0.5 * prev[i] + 0.25 * prev[b]
				col_d[i] = 0.25 * prev_d[a] + 0.5 * prev_d[i] + 0.25 * prev_d[b]
		var taper := PackedFloat32Array()
		taper.resize(nx)
		var n_tap := maxf(0.7 / maxf(data.row_cell_width[j_lip], 0.01), 2.0)
		for i in nx:
			lead[i] = mini(roundi(lead_f[i]), win)
			taper[i] = smoothstep(0.0, 1.0, (float(mini(i - first_wet, last_wet - i)) + 0.5) / n_tap)
		# the solve sees the fall as a channel as deep as the brink, with
		# walls where no water goes over
		for i in nx:
			for jj in range(maxi(j_lip - lead[i], 0), j_foot):
				var k := jj * nx + i
				if dry[i] == 1:
					depth[k] = 0.0
				elif depth[k] > SOLID_EPSILON:
					depth[k] = maxf(col_d[i], 0.06)
		out.append({"j_lip": j_lip, "j_foot": j_foot, "win": win, "lead": lead, "lead_f": lead_f,
			"col_d": col_d, "dry": dry, "taper": taper})
	return out


# ------------------------------------------------------------------ helpers --

static func _report(progress: Callable, frac: float, phase: String) -> void:
	if progress.is_valid():
		progress.call(frac, phase)


## 5-point blur that respects solids (port of the prototype's blur()).
static func _blur(src: PackedFloat32Array, dst: PackedFloat32Array, solid: PackedByteArray, nx: int, nz: int) -> void:
	for j in nz:
		for i in nx:
			var k := j * nx + i
			if solid[k] == 1:
				dst[k] = 0.0
				continue
			var s := src[k] * 2.0
			var w := 2.0
			if i > 0 and solid[k - 1] == 0:
				s += src[k - 1]
				w += 1.0
			if i < nx - 1 and solid[k + 1] == 0:
				s += src[k + 1]
				w += 1.0
			if j > 0 and solid[k - nx] == 0:
				s += src[k - nx]
				w += 1.0
			if j < nz - 1 and solid[k + nx] == 0:
				s += src[k + nx]
				w += 1.0
			dst[k] = s / w


## Adds a soft radial splat into a float array (plunge foam in ponds).
static func _splat(arr: PackedFloat32Array, k: int, nx: int, nz: int, strength: float, radius: int) -> void:
	var ci := k % nx
	var cj := k / nx
	for dj in range(-radius, radius + 1):
		var j := cj + dj
		if j < 0 or j >= nz:
			continue
		for di in range(-radius, radius + 1):
			var i := ci + di
			if i < 0 or i >= nx:
				continue
			var d := sqrt(float(di * di + dj * dj)) / float(radius)
			if d > 1.0:
				continue
			var kk := j * nx + i
			arr[kk] = maxf(arr[kk], strength * (1.0 - d) * (1.0 - d))


## GDScript SOR pressure solve (the reference; the prototype's loop verbatim).
static func _solve_pressure_gdscript(pres: PackedFloat32Array, div: PackedFloat32Array,
		kx: PackedFloat32Array, kz: PackedFloat32Array, open_out: PackedFloat32Array,
		solid: PackedByteArray, nx: int, nz: int, iterations: int, pond: bool,
		progress: Callable) -> void:
	var nx1 := nx + 1
	for it in iterations:
		if it % 20 == 0:
			_report(progress, 0.18 + 0.35 * float(it) / float(iterations), "Pressure solve (CPU)")
		for j in nz:
			var row := j * nx
			var grow := j * nx1
			for i in nx:
				var k := row + i
				if solid[k] == 1:
					continue
				var kw := kx[grow + i]
				var ke := kx[grow + i + 1]
				var kn := kz[row + i]
				var ks := kz[row + nx + i]
				var ko := open_out[k]
				var sum := kw + ke + kn + ks + ko
				if sum < 1e-9:
					continue
				var acc := 0.0
				if kw > 0.0:
					acc += kw * pres[k - 1]
				if ke > 0.0:
					acc += ke * pres[k + 1]
				if kn > 0.0:
					acc += kn * pres[k - nx]
				if ks > 0.0 and j < nz - 1:
					acc += ks * pres[k + nx]
				# ko: outside pressure is 0, contributes only to sum
				pres[k] += 1.8 * ((acc - div[k]) / sum - pres[k])


## Red-black SOR on a local RenderingDevice. Returns false if compute is
## unavailable (Compatibility renderer / headless without Vulkan).
static func _solve_pressure_compute(pres: PackedFloat32Array, div: PackedFloat32Array,
		kx: PackedFloat32Array, kz: PackedFloat32Array, open_out: PackedFloat32Array,
		solid: PackedByteArray, nx: int, nz: int, iterations: int, pond: bool) -> bool:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	var shader_file := pressure_shader_file
	if shader_file == null:
		shader_file = load("res://addons/flowing_water/bake/bake_pressure.glsl")
	if shader_file == null:
		rd.free()
		return false
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_warning("FlowingWater: pressure compute shader failed to compile, using CPU: %s" % spirv.compile_error_compute)
		rd.free()
		return false
	var shader := rd.shader_create_from_spirv(spirv)

	var solid_f := PackedFloat32Array()
	solid_f.resize(solid.size())
	for k in solid.size():
		solid_f[k] = 1.0 if solid[k] == 1 else 0.0

	var buffers: Array[RID] = []
	var uniforms: Array[RDUniform] = []
	var arrays := [pres, div, kx, kz, open_out, solid_f]
	for n in arrays.size():
		var bytes: PackedByteArray = arrays[n].to_byte_array()
		var buf := rd.storage_buffer_create(bytes.size(), bytes)
		buffers.append(buf)
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = n
		u.add_id(buf)
		uniforms.append(u)
	var uset := rd.uniform_set_create(uniforms, shader, 0)
	var pipeline := rd.compute_pipeline_create(shader)

	var groups_x := (nx + 7) / 8
	var groups_y := (nz + 7) / 8
	for it in iterations:
		for phase in 2:
			var push := PackedInt32Array([nx, nz, phase, 0]).to_byte_array()
			push.append_array(PackedFloat32Array([1.8, 0.0, 0.0, 0.0]).to_byte_array())
			var cl := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl, pipeline)
			rd.compute_list_bind_uniform_set(cl, uset, 0)
			rd.compute_list_set_push_constant(cl, push, push.size())
			rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
			rd.compute_list_end()
	rd.submit()
	rd.sync()

	var out_bytes := rd.buffer_get_data(buffers[0])
	var out := out_bytes.to_float32_array()
	for k in pres.size():
		pres[k] = out[k]

	for buf in buffers:
		rd.free_rid(buf)
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free()
	return true


## Pond aeration: trace forward from each inlet cell along the flow,
## depositing decaying foam/aeration, so there is a pale fan at the mouth.
static func _advect_pond_aeration(aer: PackedFloat32Array, foam: PackedFloat32Array,
		vx: PackedFloat32Array, vz: PackedFloat32Array, solid: PackedByteArray,
		data: WaterData, p: BakeParams) -> void:
	var nx := data.cells_across
	var nz := data.rows
	for k in aer.size():
		aer[k] = 0.0 if solid[k] == 1 else foam[k] * 0.9
	var step := data.cell_length
	for n in p.pond_inlet_cells.size():
		var k := p.pond_inlet_cells[n]
		if k < 0 or k >= nx * nz or solid[k] == 1:
			continue
		var a := p.pond_inlet_aeration[n] if n < p.pond_inlet_aeration.size() else 0.0
		var f := p.pond_inlet_foam[n] if n < p.pond_inlet_foam.size() else 0.0
		var strength := maxf(a, f)
		if strength < 0.02:
			continue
		var fi := float(k % nx)
		var fj := float(k / nx)
		var dir := p.pond_inlet_dirs[n] if n < p.pond_inlet_dirs.size() else Vector2(0, 1)
		for s in 160:
			var ci := clampi(int(round(fi)), 0, nx - 1)
			var cj := clampi(int(round(fj)), 0, nz - 1)
			var cc := cj * nx + ci
			if solid[cc] == 1:
				break
			aer[cc] = maxf(aer[cc], strength)
			foam[cc] = maxf(foam[cc], strength * 0.5)
			var wx := vx[cc]
			var wz := vz[cc]
			var wl := sqrt(wx * wx + wz * wz)
			if wl < 0.02:
				# still water: keep going a little in the inlet direction
				wx = dir.x
				wz = dir.y
				wl = 1.0
			fi += wx / wl * step / data.row_cell_width[cj]
			fj += wz / wl * step / data.cell_length
			if fi < 0.0 or fj < 0.0 or fi > float(nx - 1) or fj > float(nz - 1):
				break
			strength *= exp(-step / 4.0)
			if strength < 0.02:
				break


## Spray points at rough water, mist points in plunge zones. World positions.
static func _build_emission_points(data: WaterData, p: BakeParams, solid: PackedByteArray,
		foam: PackedFloat32Array, aer: PackedFloat32Array,
		vx: PackedFloat32Array, vz: PackedFloat32Array,
		air: PackedByteArray, eff: PackedInt32Array, plunge_row: PackedFloat32Array) -> void:
	var nx := data.cells_across
	var nz := data.rows
	var spray_pts := PackedVector3Array()
	var spray_w := PackedFloat32Array()
	var spray_v := PackedVector3Array()
	var mist_pts := PackedVector3Array()
	var max_spray := 600
	var stride := maxi(1, (nx * nz) / 20000)
	for j in range(0, nz, 1):
		for i in nx:
			var k := j * nx + i
			if solid[k] == 1 or (k % stride) != 0:
				continue
			var world := _cell_to_world(data, i, j)
			var is_fall := air[k] == 1
			var plunge := plunge_row[eff[k]] if plunge_row.size() > 0 else 0.0
			if is_fall or plunge > 0.0:
				world.y = data.row_height[eff[k]]
			if plunge > 0.3 and aer[k] > 0.3:
				mist_pts.append(world)
			# the foot of a fall throws water up
			if plunge > 0.55 and foam[k] > 0.5 \
					and spray_pts.size() < max_spray:
				spray_pts.append(world)
				spray_w.append(2.5)
				spray_v.append(_cell_vel_to_world(data, i, j, vx[k], vz[k]) * 0.4)
			# water hitting a rock head-on (in a fall or in fast water) bursts
			# upward: a splash crown on the rock's upstream face
			if j + 1 < nz and solid[(j + 1) * nx + i] == 1 and spray_pts.size() < max_spray:
				var hit_speed := sqrt(vx[k] * vx[k] + vz[k] * vz[k])
				if is_fall or hit_speed > 1.8:
					spray_pts.append(world)
					spray_w.append(4.0)
					spray_v.append(_cell_vel_to_world(data, i, j, vx[k], vz[k]) * 0.25)
			if foam[k] > 0.62 and not is_fall and spray_pts.size() < max_spray:
				var sp := sqrt(vx[k] * vx[k] + vz[k] * vz[k])
				if sp > 1.6:
					spray_pts.append(world)
					spray_w.append(foam[k] * sp)
					spray_v.append(_cell_vel_to_world(data, i, j, vx[k], vz[k]))
	# pond plunge points emit mist too
	for n in p.plunge_cells.size():
		var k := p.plunge_cells[n]
		if k >= 0 and k < nx * nz:
			mist_pts.append(_cell_to_world(data, k % nx, k / nx))
	# droplets that fall with the water: born across every waterfall with the
	# water's own velocity along its arc
	var fall_pts := PackedVector3Array()
	var fall_v := PackedVector3Array()
	if not data.is_pond_grid:
		var n_air := 0
		for k in nx * nz:
			n_air += int(air[k])
		var f_stride := maxi(1, n_air / 320)
		var seen := 0
		for j in nz:
			var d := data.row_dir[j]
			for i in nx:
				var k := j * nx + i
				if solid[k] == 1 or air[k] == 0:
					continue
				# thin water tears into drops first: the edges of the sheet
				# shed more of them than its middle
				seen += 1 if data.depth[k] > 0.06 else 3
				if seen < f_stride:
					continue
				seen = 0
				var tangent := (d + Vector3.DOWN * data.row_slope[eff[k]]).normalized()
				var pt := _cell_to_world(data, i, j)
				pt.y = data.row_height[eff[k]]
				fall_pts.append(pt)
				fall_v.append(tangent * sqrt(vx[k] * vx[k] + vz[k] * vz[k]))
	data.fall_points = fall_pts
	data.fall_velocities = fall_v
	data.spray_points = spray_pts
	data.spray_weights = spray_w
	data.spray_velocities = spray_v
	data.mist_points = mist_pts


static func _cell_to_world(data: WaterData, i: int, j: int) -> Vector3:
	if data.is_pond_grid:
		return data.grid_origin + Vector3((float(i) + 0.5) * data.row_cell_width[j], 0.0, (float(j) + 0.5) * data.cell_length)
	var c := data.row_center[j]
	var d := data.row_dir[j]
	var side := Vector3(d.z, 0.0, -d.x)   # right of flow
	var across := -data.row_half_width[j] + (float(i) + 0.5) * data.row_cell_width[j]
	var pos := c + side * across
	pos.y = data.row_height[j]
	return pos


static func _cell_vel_to_world(data: WaterData, i: int, j: int, u: float, v: float) -> Vector3:
	if data.is_pond_grid:
		return Vector3(u, 0.0, v)
	var d := data.row_dir[j]
	var side := Vector3(d.z, 0.0, -d.x)
	return side * u + d * v
