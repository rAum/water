# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## A body standing in a waterfall must part it: a gap opens below the body
## (not above it), travels down with the water once the body leaves, and the
## fall is whole again a moment later. Also holds a log in the sheet.
## Captures tools/shots/fallhit_*.png.
## Run: godot --path . res://tools/fall_hit_check.tscn --resolution 1280x800

var _scene: Node3D
var _cam: Camera3D
var _errors := 0


func _ready() -> void:
	_scene = load("res://examples/03_waterfall.tscn").instantiate()
	add_child(_scene)
	_cam = Camera3D.new()
	add_child(_cam)
	_run.call_deferred()


func _fail(msg: String) -> void:
	_errors += 1
	print("FAIL: ", msg)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(name: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tools/shots"))
	img.save_png("res://tools/shots/%s.png" % name)
	print("shot: res://tools/shots/%s.png" % name)


## Blocked value (0..255) of the water at flight time t in column col.
func _cell(rv: WaterRiver, t: float, col: int) -> int:
	var h := rv._fall_hits
	var r := (h._head_row + int(t / WaterFallHits.ROW_DT)) % WaterFallHits.ROWS
	return h._data[r * WaterFallHits.COLS + col]


func _run() -> void:
	for i in 60:
		await get_tree().process_frame
	var rv := _scene.get_node("Stream") as WaterRiver
	rv._update_falls()
	if rv._falls.is_empty():
		_fail("no fall in 03_waterfall")
		get_tree().quit(1)
		return
	var f: Array = rv._falls[0]
	var foot_y: float = f[3]
	var line := rv._fall_line(0)
	# stand where the sheet passes 1.2 m above the pool
	var spot: Vector3 = line[0][0]
	for e: Array in line:
		if (e[0] as Vector3).y <= foot_y + 1.2:
			spot = e[0]
			break
	var stand := rv.global_transform * Vector3(spot.x, foot_y, spot.z)
	var lf := rv.frame_at(44.0)
	_cam.global_position = rv.global_transform * (lf["pos"] as Vector3) + Vector3.UP * 1.6
	_cam.look_at(stand + Vector3.UP * 1.4)
	_cam.make_current()

	# --- a person (1.8 m column) standing in the sheet ---------------------
	var person := Node3D.new()
	var mesh := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.3
	cap.height = 1.8
	mesh.mesh = cap
	mesh.position.y = 0.9
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.3, 0.2)
	mesh.material_override = mat
	person.add_child(mesh)
	var wi := WaterInteractor.new()
	wi.height = 1.8
	wi.radius = 0.32
	person.add_child(wi)
	_scene.add_child(person)
	person.global_position = stand
	await _wait(1.5)
	var h := rv._fall_hits
	if h == null or not h.active:
		_fail("standing in the fall left no record")
	else:
		var top := rv._fall_contact(0, rv.to_local(stand), rv.to_local(stand + Vector3.UP * 1.8).y, 0.32)
		if top.is_empty():
			_fail("no contact found for the person")
		else:
			var tb: float = top[0]
			var col := clampi(int(float(top[1]) * WaterFallHits.COLS), 0, WaterFallHits.COLS - 1)
			var above := _cell(rv, maxf(tb - 0.12, 0.0), col)
			var below := _cell(rv, tb + 0.15, col)
			var aside := _cell(rv, tb + 0.15, (col + WaterFallHits.COLS / 2) % WaterFallHits.COLS)
			print("person: contact t=%.2f s u=%.2f  above=%d below=%d aside=%d" % [tb, top[1], above, below, aside])
			if below < 200:
				_fail("no gap below the person (%d)" % below)
			if tb > 0.15 and above > 0:
				_fail("gap above the person (%d)" % above)
			if aside > 0:
				_fail("gap far to the side (%d)" % aside)
	await _shot("fallhit_person")

	# --- step out: the gap must leave with the water ------------------------
	person.queue_free()
	await _wait(0.18)
	await _shot("fallhit_leaving")
	await _wait(2.0)
	if h != null and h.active:
		_fail("the gap never closed after the person left")
	await _shot("fallhit_after")

	# --- a log held across the sheet ----------------------------------------
	var lg: RigidBody3D = load("res://examples/shared/log.tscn").instantiate()
	_scene.add_child(lg)
	lg.freeze = true
	var mid: Vector3 = line[int(line.size() * 0.45)][0]
	var side: Vector3 = line[0][2]
	lg.global_transform = Transform3D(Basis.looking_at(rv.global_transform.basis * side), rv.global_transform * mid)
	await _wait(1.2)
	if h == null or not h.active:
		_fail("a log held in the fall left no gap")
	await _shot("fallhit_log")
	lg.queue_free()
	await _wait(0.2)

	print("fall_hit_check: %d error(s)" % _errors)
	get_tree().quit(0 if _errors == 0 else 1)
