# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends SceneTree
## Validation harness: loads every script and shader in the addon, runs a
## tiny headless bake, and exercises the CPU query path.
## Run:  godot --headless --path . --script tools/check_all.gd

var errors := 0


func _init() -> void:
	_check_scripts("res://addons/flowing_water")
	_check_shaders("res://addons/flowing_water")
	_check_bake()
	print("check_all: %d error(s)" % errors)
	quit(1 if errors > 0 else 0)


func _walk(dir: String, ext: Array, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var path := dir + "/" + f
		if d.current_is_dir() and not f.begins_with("."):
			_walk(path, ext, out)
		elif ext.has(f.get_extension()):
			out.append(path)
		f = d.get_next()


func _check_scripts(root: String) -> void:
	var files: Array = []
	_walk(root, ["gd"], files)
	for path: String in files:
		var s: Script = load(path)
		if s == null:
			push_error("FAILED TO LOAD: " + path)
			errors += 1
			continue
		if not s.can_instantiate():
			# @tool scripts instantiate; parse errors mean they cannot
			s.reload()
			push_error("CANNOT INSTANTIATE (parse error?): " + path)
			errors += 1
		else:
			print("ok script  ", path)


func _check_shaders(root: String) -> void:
	var files: Array = []
	_walk(root, ["gdshader"], files)
	for path: String in files:
		var sh: Shader = load(path)
		if sh == null:
			push_error("FAILED TO LOAD SHADER: " + path)
			errors += 1
			continue
		var rid := sh.get_rid()
		if not rid.is_valid():
			push_error("SHADER HAS NO RID: " + path)
			errors += 1
		else:
			print("ok shader  ", path)


func _check_bake() -> void:
	# a tiny synthetic channel: 24 cells x 80 rows, straight, sloped
	var data := WaterData.new()
	var nx := 24
	var nz := 80
	data.cells_across = nx
	data.rows = nz
	data.cell_length = 0.25
	data.row_cell_width.resize(nz)
	data.row_slope.resize(nz)
	data.row_height.resize(nz)
	data.row_center.resize(nz)
	data.row_dir.resize(nz)
	data.row_half_width.resize(nz)
	data.row_mean_speed.resize(nz)
	data.depth.resize(nx * nz)
	for j in nz:
		data.row_cell_width[j] = 4.0 / nx
		data.row_slope[j] = 0.08 if (j > 30 and j < 45) else 0.02
		data.row_height[j] = 10.0 - 0.03 * j
		data.row_center[j] = Vector3(0, data.row_height[j], j * 0.25)
		data.row_dir[j] = Vector3(0, 0, 1)
		data.row_half_width[j] = 2.0
		for i in nx:
			var a := absf(float(i) / float(nx - 1) - 0.5) * 2.0
			var dep := 0.5 * (1.0 - a * a)
			# a rock in the middle
			if j > 40 and j < 44 and i > 10 and i < 14:
				dep = 0.0
			data.depth[j * nx + i] = dep
	var params := WaterBaker.BakeParams.new()
	params.discharge = 1.5
	params.use_compute = false
	params.pressure_iterations = 60
	WaterBaker.bake(data, params)
	data.build_textures()
	if data.max_speed <= 0.0 or is_nan(data.max_speed):
		push_error("bake: max_speed bad: %f" % data.max_speed)
		errors += 1
	# mass conservation: total flux through rows within 15% of discharge
	var worst := 0.0
	for j in range(5, nz - 5):
		var q := 0.0
		for i in nx:
			var k := j * nx + i
			# cells under a rock are filled in for display only: not real flow
			if data.obstacle[k] == 1:
				continue
			q += data.vel_along[k] * data.depth[k] * data.row_cell_width[j]
		worst = maxf(worst, absf(q - params.discharge) / params.discharge)
	print("bake: max_speed=%.2f m/s, worst row flux error=%.1f%%, foam max=%.2f, %d ms" % [
		data.max_speed, worst * 100.0,
		data.foam[data.cells_across * 50 + 5],
		int(data.bake_ms)])
	if worst > 0.15:
		push_error("bake: discharge not conserved (%.1f%% worst row)" % (worst * 100.0))
		errors += 1
	# wake behind the rock should be nonzero
	var wake_behind := 0.0
	for j in range(44, 52):
		wake_behind = maxf(wake_behind, data.wake[j * nx + 12])
	if wake_behind <= 0.0:
		push_error("bake: no wake behind the obstacle")
		errors += 1
	else:
		print("bake: wake behind rock = %.2f" % wake_behind)
	if data.flow_tex == null or data.flow_tex.get_width() != nx:
		push_error("bake: flow texture wrong")
		errors += 1
	else:
		print("ok bake textures ", data.flow_tex.get_size())
