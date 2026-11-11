# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends SceneTree
func _init():
	for id in ["rock_moss_set_01", "rock_moss_set_02"]:
		var sc: Node = load("res://examples/shared/polyhaven/models/%s/%s.gltf" % [id, id]).instantiate()
		_walk(sc, 0)
		sc.free()
	quit()
func _walk(n: Node, d: int):
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var a := mi.mesh.get_aabb()
		var mat = mi.mesh.surface_get_material(0)
		print("%s%s  aabb size %s center %s  verts %d  mat %s" % ["  ".repeat(d), n.name, str(a.size.snapped(Vector3.ONE*0.01)), str((mi.transform * a.get_center()).snapped(Vector3.ONE*0.01)), mi.mesh.surface_get_array_len(0), mat.get_class() if mat else "none"])
	else:
		print("  ".repeat(d), n.name, " (", n.get_class(), ")")
	for c in n.get_children():
		_walk(c, d + 1)
