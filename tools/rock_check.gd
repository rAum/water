# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Compares every rock's collision shape (what the bake sees) with its mesh
## (what the player sees) and reports rocks standing in water.
## Run: godot --headless --path . res://tools/rock_check.tscn [-- scene=...]

func _ready() -> void:
	var path := "res://examples/demo/demo.tscn"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("scene="):
			path = a.substr(6)
	var scene: Node = load(path).instantiate()
	add_child(scene)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	var mgr = get_tree().root.get_node("WaterManager")
	var rocks := scene.get_node_or_null("Rocks")
	for r in rocks.get_children():
		var mi := r.get_node("Mesh") as MeshInstance3D
		var cs := r.get_node("Shape") as CollisionShape3D
		var maabb: AABB = r.global_transform * (mi.transform * mi.mesh.get_aabb())
		var pts: PackedVector3Array = (cs.shape as ConvexPolygonShape3D).points
		var saabb := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			saabb = saabb.expand(p)
		saabb = r.global_transform * (cs.transform * saabb)
		var c := maabb.get_center()
		var q = mgr.query(Vector3(c.x, maabb.end.y, c.z))
		var near := false
		for dx in [-1.0, 0.0, 1.0]:
			for dz in [-1.0, 0.0, 1.0]:
				var q2 = mgr.query(c + Vector3(dx * maabb.size.x * 0.7, 0, dz * maabb.size.z * 0.7))
				if q2.valid and q2.depth > 0.03:
					near = true
		if not near:
			continue
		var top_above: float = maabb.end.y - (q.height if q.valid else -99.0)
		print("%s mesh %s..%s  shape %s..%s  top-above-water %.2f  depth@centre %.2f" % [r.name,
			maabb.position.snapped(Vector3.ONE * 0.01), maabb.end.snapped(Vector3.ONE * 0.01),
			saabb.position.snapped(Vector3.ONE * 0.01), saabb.end.snapped(Vector3.ONE * 0.01),
			top_above, q.depth if q.valid else -1.0])
	get_tree().quit()
