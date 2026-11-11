# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
extends EditorInspectorPlugin
## Inspector buttons for the water nodes:
##   WaterRiver:    Snap to terrain | Make downhill | Rebuild mesh | Bake
##   WaterPond:     Rebuild mesh | Bake
##   WaterJunction: Snap to pond level | Bake river + pond
## Every button supports undo/redo; river bakes run the solver on a worker
## thread with a live progress readout on the button.

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return object is WaterRiver or object is WaterPond or object is WaterJunction


func _parse_begin(object: Object) -> void:
	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	box.add_child(row)
	if object is WaterRiver:
		var river := object as WaterRiver
		row.add_child(_button("Snap to terrain", func(): _with_curve_undo(river, "Snap river to terrain", river.snap_to_terrain)))
		row.add_child(_button("Make downhill", func(): _with_curve_undo(river, "Make river downhill", river.make_downhill)))
		var row2 := HBoxContainer.new()
		box.add_child(row2)
		row2.add_child(_button("Rebuild mesh", river.rebuild_mesh))
		var bake := _button("Bake", Callable())
		bake.pressed.connect(func(): _bake_river(river, bake))
		row2.add_child(bake)
	elif object is WaterPond:
		var pond := object as WaterPond
		row.add_child(_button("Rebuild mesh", pond.rebuild_mesh))
		var bake := _button("Bake", Callable())
		bake.pressed.connect(func(): _bake_pond(pond, bake))
		row.add_child(bake)
	elif object is WaterJunction:
		var junction := object as WaterJunction
		row.add_child(_button("Snap to pond level", func():
			var river := junction.get_river()
			if river != null:
				_with_curve_undo(river, "Snap river to pond level", junction.snap_river_to_pond)))
		var bake := _button("Bake river + pond", Callable())
		bake.pressed.connect(func(): _bake_junction(junction, bake))
		row.add_child(bake)
	add_custom_control(box)


func _button(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if on_pressed.is_valid():
		b.pressed.connect(on_pressed)
	return b


# runs an action that edits the curve/widths, wrapped in one undo step
func _with_curve_undo(river: WaterRiver, action_name: String, action: Callable) -> void:
	var before_pts := _curve_points(river)
	var before_widths := river.widths.duplicate()
	action.call()
	var after_pts := _curve_points(river)
	var after_widths := river.widths.duplicate()
	if undo_redo == null:
		return
	undo_redo.create_action(action_name)
	undo_redo.add_do_method(self, "_apply_curve_points", river, after_pts, after_widths)
	undo_redo.add_undo_method(self, "_apply_curve_points", river, before_pts, before_widths)
	undo_redo.commit_action(false)   # already executed


static func _curve_points(river: WaterRiver) -> Array:
	var pts := []
	for p in river.curve.point_count:
		pts.append([
			river.curve.get_point_position(p),
			river.curve.get_point_in(p),
			river.curve.get_point_out(p),
		])
	return pts


func _apply_curve_points(river: WaterRiver, pts: Array, widths: PackedFloat32Array) -> void:
	if not is_instance_valid(river) or river.curve == null:
		return
	for p in mini(pts.size(), river.curve.point_count):
		river.curve.set_point_position(p, pts[p][0])
		river.curve.set_point_in(p, pts[p][1])
		river.curve.set_point_out(p, pts[p][2])
	river.widths = widths
	river.rebuild_mesh()


# ------------------------------------------------------------------- baking --

func _bake_river(river: WaterRiver, button: Button) -> void:
	if button.disabled:
		return
	button.disabled = true
	var old_segments := river.baked_segments.duplicate()
	var prep: Array = river.prepare_all_bakes()
	var progress := {"frac": 0.0, "phase": "starting"}
	var datas: Array = prep[0]
	var inlet: Array = prep[1]
	var task := WorkerThreadPool.add_task(
		func() -> void:
			river.solve_prepared(datas, inlet,
				func(f: float, phase: String) -> void:
					progress["frac"] = f
					progress["phase"] = phase),
		true, "FlowingWater bake: " + String(river.name))
	while not WorkerThreadPool.is_task_completed(task):
		button.text = "Baking %d%% - %s" % [int(progress["frac"] * 100.0), progress["phase"]]
		await Engine.get_main_loop().process_frame
		if not is_instance_valid(button) or not is_instance_valid(river):
			WorkerThreadPool.wait_for_task_completion(task)
			return
	WorkerThreadPool.wait_for_task_completion(task)
	river.finalize_bake(datas)
	river.save_baked_data()
	if undo_redo != null:
		undo_redo.create_action("Bake river")
		undo_redo.add_do_property(river, "baked_segments", river.baked_segments.duplicate())
		undo_redo.add_undo_property(river, "baked_segments", old_segments)
		undo_redo.commit_action(false)
	var data: WaterData = river.baked_segments[0]
	button.text = "Bake  (%.1f s, max %.1f m/s)" % [data.bake_ms / 1000.0, data.max_speed]
	button.disabled = false


func _bake_pond(pond: WaterPond, button: Button) -> void:
	if button.disabled:
		return
	button.disabled = true
	button.text = "Baking..."
	await Engine.get_main_loop().process_frame
	var old := pond.baked_data
	pond.bake_blocking()
	pond.save_baked_data()
	if undo_redo != null:
		undo_redo.create_action("Bake pond")
		undo_redo.add_do_property(pond, "baked_data", pond.baked_data)
		undo_redo.add_undo_property(pond, "baked_data", old)
		undo_redo.commit_action(false)
	button.text = "Bake"
	button.disabled = false


func _bake_junction(junction: WaterJunction, button: Button) -> void:
	if button.disabled:
		return
	button.disabled = true
	button.text = "Baking river + pond..."
	await Engine.get_main_loop().process_frame
	junction.bake_all()
	var river := junction.get_river()
	var pond := junction.get_pond()
	if river != null:
		river.save_baked_data()
	if pond != null:
		pond.save_baked_data()
	button.text = "Bake river + pond"
	button.disabled = false
