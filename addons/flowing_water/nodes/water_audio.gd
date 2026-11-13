# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
@icon("../editor/icons/water_audio.svg")
class_name WaterAudio
extends Node3D
## Places a few AudioStreamPlayer3D along nearby rivers. Volume and
## brightness follow the baked turbulence (foam); waterfalls get their own
## louder source; ponds are quiet. Supply your own loops - the plugin ships
## silent placeholders so nothing errors without them.

## Looping stream for flowing water. Silent placeholder if empty.
@export var flow_stream: AudioStream
## Looping stream for waterfalls. Silent placeholder if empty.
@export var falls_stream: AudioStream
## Sources placed every this many metres along the river near the camera.
@export var spacing := 12.0
@export var max_sources := 6
@export_range(0.0, 1.0) var volume := 0.8

var _players: Array[AudioStreamPlayer3D] = []
var _accum := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# silent placeholders so nothing errors until real loops are supplied
	if flow_stream == null:
		flow_stream = load("res://addons/flowing_water/audio/silence.wav")
	if falls_stream == null:
		falls_stream = load("res://addons/flowing_water/audio/silence.wav")
	for n in max_sources:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 6.0
		p.max_distance = 40.0
		p.bus = "Master"
		add_child(p, false, Node.INTERNAL_MODE_BACK)
		_players.append(p)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_accum += delta
	if _accum < 0.5:
		return
	_accum = 0.0
	var cam := get_viewport().get_camera_3d()
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	if cam == null or mgr == null:
		return
	var spots: Array = []     # [pos, turbulence, is_fall]
	for body in mgr.get_bodies():
		if body is WaterRiver:
			var river := body as WaterRiver
			if river.baked_segments.is_empty() or river.curve == null:
				continue
			var aabb: AABB = river.get_water_aabb()
			if not aabb.grow(50.0).has_point(cam.global_position):
				continue
			var length: float = river.curve.get_baked_length()
			var s := 0.0
			while s < length:
				var pos: Vector3 = river.global_transform * river.curve.sample_baked(s, true)
				var d := cam.global_position.distance_to(pos)
				if d < 45.0:
					var seg: int = river._segment_of(s)
					var data: WaterData = river.baked_segments[mini(seg, river.baked_segments.size() - 1)]
					if data != null and data.is_valid():
						var rng: Vector2 = river._segment_range(seg)
						var j := clampi(int((s - rng.x) / WaterRiver.ROW_STEP), 0, data.rows - 1)
						var turb := 0.0
						var wet := 0
						for i in data.cells_across:
							var k := j * data.cells_across + i
							if data.depth[k] > 0.03:
								turb += data.foam[k]
								wet += 1
						turb = turb / maxf(wet, 1.0)
						var is_fall: bool = data.row_slope[j] > 0.3
						spots.append([pos, turb, is_fall, d])
				s += spacing
	spots.sort_custom(func(a, b): return a[3] < b[3])
	for n in _players.size():
		var p := _players[n]
		if n < spots.size() and volume > 0.0:
			var spot: Array = spots[n]
			p.global_position = spot[0]
			var turb: float = spot[1]
			var want: AudioStream = falls_stream if spot[2] else flow_stream
			if want == null:
				if p.playing:
					p.stop()
				continue
			if p.stream != want:
				p.stream = want
			p.volume_db = linear_to_db(clampf((0.15 + turb) * volume, 0.0, 1.0))
			p.pitch_scale = 0.9 + turb * 0.3
			if not p.playing:
				p.play()
		else:
			if p.playing:
				p.stop()
