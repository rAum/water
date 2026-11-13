# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Dark-chunk probe: walks downstream along a river at walking speed,
## grabs every rendered frame and flags frames where a block of the image
## suddenly turns darker (or brighter) than the frame around it - a square
## of water that "pops" for a moment. Each event saves the frames before,
## at and after it plus a difference image to tools/shots/glitch_*.png and
## prints what the water systems did that frame (map swap, ripple re-centre,
## LOD switch, underwater flip).
##
## Run windowed with a fixed frame time so the walk is deterministic:
##   godot --path . res://tools/glitch_walk.tscn --resolution 1280x800 \
##       --fixed-fps 60 -- [scene=res://examples/demo/demo.tscn] \
##       [rivers=Stream,Outlet] [side=0] [speed=1.4] [save=1] [grab=Stream:1724]
## A Player in the scene is walked along the river (so it makes ripples);
## the camera follows it like the third-person camera, minus the bobbing.
## Exit code 0 = no events, 1 = events found.

const GRID_W := 64          # luminance blocks across the image
const GRID_H := 40
const CELL := 4             # blocks per coarse cell side (16 x 10 cells)
const DROP := 0.03          # cell luminance jump that counts (0-1)
const MIN_CELLS := 12       # ...in this many of the 160 cells at once
const CAM_BACK := 3.0       # camera this far upstream of the walker (m)
const CAM_HEIGHT := 2.2     # and this high above the water / ground
const SETTLE_FRAMES := 45   # frames after a teleport that are not judged

var _scene: Node
var _player: CharacterBody3D
var _cam: Camera3D
var _mgr: Node
var _events := 0
var _save := true
var _scores: Array = []
var _saved := 0
var _cam_y := NAN
var _grab: PackedStringArray = []   # "River:frame" to save regardless


func _ready() -> void:
	var scene_path := "res://examples/demo/demo.tscn"
	var rivers: PackedStringArray = []
	var side := 0.0
	var speed := 1.4
	for a in OS.get_cmdline_user_args():
		if a.begins_with("scene="):
			scene_path = a.substr(6)
		elif a.begins_with("rivers="):
			rivers = a.substr(7).split(",")
		elif a.begins_with("side="):
			side = float(a.substr(5))
		elif a.begins_with("speed="):
			speed = float(a.substr(6))
		elif a.begins_with("grab="):
			for g in a.substr(5).split(","):
				_grab.append(g)
		elif a.begins_with("save="):
			_save = a.substr(5) != "0"
	_scene = load(scene_path).instantiate()
	add_child(_scene)
	if rivers.is_empty():
		for c in _scene.get_children():
			if c is WaterRiver:
				rivers.append(c.name)
	_run.call_deferred(rivers, side, speed)


func _run(rivers: PackedStringArray, side: float, speed: float) -> void:
	_mgr = get_tree().root.get_node("WaterManager")
	_player = _scene.get_node_or_null("Player") as CharacterBody3D
	# The probe camera rides a smoothed path a few metres behind the
	# walker: the player's own camera bobs with every step and rock, and
	# those jumps would drown the rendering pops this tool looks for.
	# (the walker itself is hidden: it hops onto rocks, which is not a
	# rendering glitch)
	if _player != null:
		(_player.get_node("Body") as Node3D).visible = false
	_cam = Camera3D.new()
	_cam.fov = 65.0
	_scene.add_child(_cam)
	_cam.make_current()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tools/shots"))
	for i in 30:
		await get_tree().process_frame
	var total_frames := 0
	for rname in rivers:
		var rv := _scene.get_node(String(rname)) as WaterRiver
		var length := rv.curve.get_baked_length()
		print("walking %s: %.0f m at %.1f m/s, side %.1f" % [rname, length, speed, side])
		var s := 1.0
		_cam_y = NAN
		_place(rv, s, side)
		# history of block luminance, and of the frames themselves
		var hist: Array[PackedFloat32Array] = []
		var imgs: Array[Image] = []
		var frame := 0
		var state_prev := _state(rv)
		while s < length - 1.0:
			s += speed / 60.0
			_place(rv, s, side)
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var lum := _blocks(img)
			var st := _state(rv)
			hist.append(lum)
			imgs.append(img)
			if hist.size() > 3:
				hist.pop_front()
				imgs.pop_front()
			frame += 1
			total_frames += 1
			if _grab.has("%s:%d" % [rname, frame]):
				img.save_png("res://tools/shots/glitch_grab_%s_%d.png" % [rname, frame])
			if frame > SETTLE_FRAMES and hist.size() >= 2:
				_judge(rname, s, frame, hist, imgs, state_prev, st)
			state_prev = st
	_report()
	print("glitch_walk: %d frames, %d dark/bright-chunk events" % [total_frames, _events])
	get_tree().quit(1 if _events > 0 else 0)


## Puts the walker at river arc length `s` and the camera behind it,
## looking downstream.
func _place(rv: WaterRiver, s: float, side: float) -> void:
	var f := rv.frame_at(s)
	var pos: Vector3 = rv.global_transform * (f["pos"] + f["side"] * side)
	var dir: Vector3 = rv.global_transform.basis * (f["dir"] as Vector3)
	var yaw := atan2(-dir.x, -dir.z)
	if _player != null:
		var h: float = _mgr.get_height(pos)
		var ground := _ground(pos)
		var y := ground if is_nan(h) else maxf(ground, h - 0.6)
		_player.global_position = Vector3(pos.x, y + 0.05, pos.z)
		_player.velocity = Vector3.ZERO
		_player.rotation.y = yaw
	var fc := rv.frame_at(maxf(s - CAM_BACK, 0.0))
	var cpos: Vector3 = rv.global_transform * (fc["pos"] + fc["side"] * side)
	var ch: float = _mgr.get_height(cpos)
	var want_y := maxf(_ground(cpos), -1e9 if is_nan(ch) else ch) + CAM_HEIGHT
	_cam_y = want_y if is_nan(_cam_y) else lerpf(_cam_y, want_y, 0.03)
	_cam.global_position = Vector3(cpos.x, _cam_y, cpos.z)
	_cam.rotation = Vector3(-0.3, yaw, 0.0)


func _ground(pos: Vector3) -> float:
	var space := get_viewport().find_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 50.0, pos + Vector3.DOWN * 50.0, 1)
	var hit := space.intersect_ray(q)
	return (hit["position"] as Vector3).y if not hit.is_empty() else pos.y


## Mean luminance of GRID_W x GRID_H blocks.
func _blocks(img: Image) -> PackedFloat32Array:
	# a straight resize to 64 x 40 only reads a few source pixels per block:
	# go through an intermediate size and average 4 x 4 of those
	var mid := img.duplicate() as Image
	mid.convert(Image.FORMAT_RGB8)
	mid.resize(GRID_W * 4, GRID_H * 4, Image.INTERPOLATE_TRILINEAR)
	var out := PackedFloat32Array()
	out.resize(GRID_W * GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			var acc := 0.0
			for dy in 4:
				for dx in 4:
					var c := mid.get_pixel(x * 4 + dx, y * 4 + dy)
					acc += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			out[y * GRID_W + x] = acc / 16.0
	return out


## What the water systems did this frame (logged next to every event).
func _state(rv: WaterRiver) -> Dictionary:
	var lod := []
	for c in rv.get("_chunks"):
		lod.append(c.material_override.get_instance_id() if c.material_override else 0)
	var sim = _mgr.get("_ripples")
	return {
		"map_origin": _mgr.get("_map_origin"),
		"map_active": _mgr.get("_map_active"),
		"map_building": _mgr.get("_build") != null,
		"ripple_origin": sim.get("_origin") if sim else Vector2.ZERO,
		"ripple_active": sim.get("_active") if sim else false,
		"underwater": _mgr.call("is_camera_underwater"),
		"lod": lod,
		"cam": _cam.global_position,
	}


func _judge(rname: String, s: float, frame: int, hist: Array[PackedFloat32Array],
		imgs: Array[Image], prev: Dictionary, st: Dictionary) -> void:
	# Signed change of each coarse cell (CELL x CELL blocks, about 80 px):
	# grass sway, sparkle and the camera's own motion change single blocks
	# a lot but average out over a cell; a patch of water that changes
	# brightness as a whole does not.
	var a := hist[hist.size() - 2]
	var b := hist[hist.size() - 1]
	var worst := 0.0
	var darker := 0
	var brighter := 0
	var cw := GRID_W / CELL
	var ch := GRID_H / CELL
	var cell_d := PackedFloat32Array()
	cell_d.resize(cw * ch)
	for cy in ch:
		for cx in cw:
			var acc := 0.0
			for y in CELL:
				for x in CELL:
					var i := (cy * CELL + y) * GRID_W + cx * CELL + x
					acc += b[i] - a[i]
			var d := acc / float(CELL * CELL)
			cell_d[cy * cw + cx] = d
			if absf(d) > absf(worst):
				worst = d
			if d < -DROP:
				darker += 1
			elif d > DROP:
				brighter += 1
	_scores.append([absf(worst), worst, rname, s, frame])
	var cells := maxi(darker, brighter)
	if cells < MIN_CELLS:
		return
	_events += 1
	var what := []
	for k in st:
		if k != "cam" and st[k] != prev[k]:
			what.append(k)
	print("EVENT %s s=%.2f frame %d: %d cells darker, %d brighter, worst %+.3f; changed: %s; cam %s" % [
		rname, s, frame, darker, brighter, worst, what, st["cam"]])
	if _save and _saved < 40:
		_saved += 1
		var tag := "glitch_%s_%d" % [rname, frame]
		imgs[imgs.size() - 2].save_png("res://tools/shots/%s_a.png" % tag)
		imgs[imgs.size() - 1].save_png("res://tools/shots/%s_b.png" % tag)
		var diff := Image.create(cw, ch, false, Image.FORMAT_RGB8)
		for i in cell_d.size():
			var d := cell_d[i] * 10.0
			diff.set_pixel(i % cw, i / cw, Color(maxf(-d, 0.0), maxf(d, 0.0), 0.0))
		diff.resize(cw * 32, ch * 32, Image.INTERPOLATE_NEAREST)
		diff.save_png("res://tools/shots/%s_diff.png" % tag)


func _report() -> void:
	_scores.sort_custom(func(x, y): return x[0] > y[0])
	print("largest frame-to-frame cell changes:")
	for k in mini(10, _scores.size()):
		var e: Array = _scores[k]
		print("  %+.3f  %s s=%.2f frame %d" % [e[1], e[2], e[3], e[4]])
