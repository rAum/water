# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Re-bakes the water of saved example scenes in place: same terrain, rocks
## and nodes, only the flow is solved again and its .res files overwritten
## (use after changing the baker; build_examples.tscn regenerates whole
## scenes). Needs a windowed run so the baked textures are real.
## Run: godot --path . res://tools/rebake.tscn [-- scene=res://... ...]

const DEFAULT := [
	"res://examples/01_stream.tscn", "res://examples/02_pond.tscn",
	"res://examples/03_waterfall.tscn", "res://examples/04_river_pond_river.tscn",
	"res://examples/05_styles.tscn", "res://examples/06_gameplay.tscn",
	"res://examples/07_lowland_river.tscn", "res://examples/demo/demo.tscn",
]


func _ready() -> void:
	var scenes: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("scene="):
			scenes.append(a.substr(6))
	if scenes.is_empty():
		scenes = DEFAULT
	_run.call_deferred(scenes)


func _collect(n: Node, rivers: Array, ponds: Array, junctions: Array) -> void:
	if n is WaterRiver:
		rivers.append(n)
	elif n is WaterPond:
		ponds.append(n)
	elif n is WaterJunction:
		junctions.append(n)
	for c in n.get_children():
		_collect(c, rivers, ponds, junctions)


func _run(scenes: Array) -> void:
	for path: String in scenes:
		var scene: Node = load(path).instantiate()
		add_child(scene)
		for n in 6:
			await get_tree().physics_frame
		var rivers: Array = []
		var ponds: Array = []
		var junctions: Array = []
		_collect(scene, rivers, ponds, junctions)
		# remember where each body's data lives, then solve from scratch
		var river_paths := {}
		for r: WaterRiver in rivers:
			var paths: Array[String] = []
			for d in r.baked_segments:
				paths.append(d.resource_path if d != null else "")
			river_paths[r] = paths
			r.baked_segments = []
		var pond_paths := {}
		for p: WaterPond in ponds:
			pond_paths[p] = p.baked_data.resource_path if p.baked_data != null else ""
			p.baked_data = null
		var done := {}
		for j: WaterJunction in junctions:
			if not done.has(j.get_pond()):
				done[j.get_pond()] = true
				j.bake_all()
		for r: WaterRiver in rivers:
			if r.baked_segments.is_empty():
				r.bake_segments_blocking()
			var paths: Array = river_paths[r]
			for seg in r.baked_segments.size():
				var d: WaterData = r.baked_segments[seg]
				var out: String = paths[seg] if seg < paths.size() and paths[seg] != "" else ""
				if out == "":
					push_warning("%s: no saved path for segment %d" % [r.name, seg])
					continue
				d.take_over_path(out)
				ResourceSaver.save(d, out, ResourceSaver.FLAG_COMPRESS)
			print("  %s %s: max %.1f m/s, %.0f ms" % [path.get_file(), r.name, r.baked_segments[0].max_speed, r.baked_segments[0].bake_ms])
		for p: WaterPond in ponds:
			if p.baked_data == null:
				p.bake_blocking()
			var out: String = pond_paths[p]
			if out != "":
				p.baked_data.take_over_path(out)
				ResourceSaver.save(p.baked_data, out, ResourceSaver.FLAG_COMPRESS)
			print("  %s %s: pond baked" % [path.get_file(), p.name])
		scene.queue_free()
		await get_tree().process_frame
	get_tree().quit()
