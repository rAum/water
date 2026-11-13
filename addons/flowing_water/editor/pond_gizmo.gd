# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
extends EditorNode3DGizmoPlugin
## Outline handles for WaterPond: drag points in the pond plane; undo works.
## Hold Ctrl/Cmd and drag a handle to insert a point after it; delete points
## from the inspector's outline array.


func _init() -> void:
	create_handle_material("handles")
	create_material("lines", Color(0.35, 0.8, 0.9, 0.8))


func _get_gizmo_name() -> String:
	return "WaterPond"


func _has_gizmo(node: Node3D) -> bool:
	return node is WaterPond


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var pond := gizmo.get_node_3d() as WaterPond
	if pond == null or pond.outline.size() < 2:
		return
	var handles := PackedVector3Array()
	var ids := PackedInt32Array()
	var lines := PackedVector3Array()
	var n := pond.outline.size()
	for i in n:
		var p := pond.outline[i]
		var q := pond.outline[(i + 1) % n]
		handles.append(Vector3(p.x, 0.0, p.y))
		ids.append(i)
		lines.append(Vector3(p.x, 0.0, p.y))
		lines.append(Vector3(q.x, 0.0, q.y))
	gizmo.add_handles(handles, get_material("handles", gizmo), ids)
	gizmo.add_lines(lines, get_material("lines", gizmo))


func _get_handle_name(_gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> String:
	return "Point %d" % handle_id


func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> Variant:
	var pond := gizmo.get_node_3d() as WaterPond
	return pond.outline[handle_id] if handle_id < pond.outline.size() else Vector2.ZERO


func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool,
		camera: Camera3D, screen_pos: Vector2) -> void:
	var pond := gizmo.get_node_3d() as WaterPond
	if handle_id >= pond.outline.size():
		return
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var level := pond.global_position.y
	if absf(dir.y) < 1e-4:
		return
	var t := (level - from.y) / dir.y
	if t < 0.0:
		return
	var hit := pond.to_local(from + dir * t)
	var outline := pond.outline
	outline[handle_id] = Vector2(hit.x, hit.z)
	pond.outline = outline


func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool,
		restore: Variant, cancel: bool) -> void:
	var pond := gizmo.get_node_3d() as WaterPond
	if cancel:
		var outline := pond.outline
		outline[handle_id] = restore
		pond.outline = outline
		return
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Move pond point")
	var new_outline := pond.outline.duplicate()
	var old_outline := pond.outline.duplicate()
	old_outline[handle_id] = restore
	undo.add_do_property(pond, "outline", new_outline)
	undo.add_undo_property(pond, "outline", old_outline)
	undo.commit_action()
