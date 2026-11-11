# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node3D
## Prints the deepest water points of a scene (for placing underwater cameras).
## Run: godot --path . res://tools/find_deep.tscn -- scene=res://...

func _ready() -> void:
	var scene_path := "res://examples/demo/demo.tscn"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("scene="):
			scene_path = a.substr(6)
	var scene: Node = load(scene_path).instantiate()
	add_child(scene)
	for i in 40:
		await get_tree().process_frame
	var mgr := get_tree().root.get_node("WaterManager")
	var best: Array = []
	for body in mgr.get_bodies():
		var bb: AABB = body.get_water_aabb()
		var x := bb.position.x
		while x < bb.end.x:
			var z := bb.position.z
			while z < bb.end.z:
				var r: Array = body.query_water(Vector3(x, bb.end.y, z))
				if not r.is_empty() and r[3] > 0.5 and r[2] > 0.5 and r[2] < 3.9 and absf(x) < 40.0 and absf(z) < 40.0:
					best.append([r[2], body.name, Vector3(x, r[0], z), r[1]])
				z += 0.5
			x += 0.5
	best.sort_custom(func(a, b): return a[0] > b[0])
	print("== ", scene_path)
	var shown := {}
	for b in best:
		var n: int = shown.get(b[1], 0)
		if n < 6:
			shown[b[1]] = n + 1
			print("%s depth=%.2f surface=%s flow=%s" % [b[1], b[0], b[2], b[3]])
	get_tree().quit()
