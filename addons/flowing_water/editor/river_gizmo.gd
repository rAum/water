# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
extends EditorNode3DGizmoPlugin
## Width handles for WaterRiver: one handle on each side of every curve
## point. Dragging changes the width at that point; undo/redo works.


func _init() -> void:
	create_handle_material("handles")
	create_material("lines", Color(0.35, 0.8, 0.9, 0.7))


func _get_gizmo_name() -> String:
	return "WaterRiver"


func _has_gizmo(node: Node3D) -> bool:
	return node is WaterRiver


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var river := gizmo.get_node_3d() as WaterRiver
	if river == null or river.curve == null:
		return
	var handles := PackedVector3Array()
	var ids := PackedInt32Array()
	for p in river.curve.point_count:
		var pos := river.curve.get_point_position(p)
		var s := river.curve.get_closest_offset(pos)
		var f := river.frame_at(s)
		var side: Vector3 = f["side"]
		var w: float = river.widths[p] if p < river.widths.size() else 2.0
		handles.append(pos + side * w)
		ids.append(p * 2)
		handles.append(pos - side * w)
		ids.append(p * 2 + 1)
	gizmo.add_handles(handles, get_material("handles", gizmo), ids)

	# edge lines so the width reads while editing
	var lines := PackedVector3Array()
	var length := river.curve.get_baked_length()
	if length > 1.0:
		var step := clampf(length / 64.0, 0.5, 4.0)
		var s := 0.0
		var prev_l := Vector3.ZERO
		var prev_r := Vector3.ZERO
		var first := true
		while s <= length + 0.01:
			var f := river.frame_at(minf(s, length))
			var c: Vector3 = f["pos"]
			var side: Vector3 = f["side"]
			var hw: float = f["half_width"]
			var l := c + side * hw
			var r := c - side * hw
			if not first:
				lines.append(prev_l)
				lines.append(l)
				lines.append(prev_r)
				lines.append(r)
			prev_l = l
			prev_r = r
			first = false
			s += step
		gizmo.add_lines(lines, get_material("lines", gizmo))


func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> String:
	return "Width %d" % (handle_id / 2)


func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> Variant:
	var river := gizmo.get_node_3d() as WaterRiver
	var p := handle_id / 2
	return river.widths[p] if p < river.widths.size() else 2.0


func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool,
		camera: Camera3D, screen_pos: Vector2) -> void:
	var river := gizmo.get_node_3d() as WaterRiver
	var p := handle_id / 2
	if river.curve == null or p >= river.curve.point_count:
		return
	var point := river.curve.get_point_position(p)
	var point_world := river.to_global(point)
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	# intersect the view ray with the horizontal plane through the point
	var denom := dir.y
	if absf(denom) < 1e-4:
		return
	var t := (point_world.y - from.y) / denom
	if t < 0.0:
		return
	var hit := from + dir * t
	var s := river.curve.get_closest_offset(point)
	var side_local: Vector3 = river.frame_at(s)["side"]
	var side_world := (river.global_transform.basis * side_local).normalized()
	var w := absf((hit - point_world).dot(side_world))
	river._ensure_widths()
	river.widths[p] = maxf(w, 0.3)
	river.widths = river.widths      # trigger the setter -> rebuild


func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool,
		restore: Variant, cancel: bool) -> void:
	var river := gizmo.get_node_3d() as WaterRiver
	var p := handle_id / 2
	if cancel:
		river.widths[p] = restore
		river.widths = river.widths
		return
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Change river width")
	var new_widths := river.widths.duplicate()
	var old_widths := river.widths.duplicate()
	old_widths[p] = restore
	undo.add_do_property(river, "widths", new_widths)
	undo.add_undo_property(river, "widths", old_widths)
	undo.commit_action()
