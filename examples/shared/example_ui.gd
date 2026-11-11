# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends CanvasLayer
## On-screen help and hotkeys shared by the example scenes.
##   1-4  debug views (final / flow speed / foam mask / depth)
##   5    cycle the style presets        Q  cycle quality presets
##   R    toggle storm turbidity (WaterManager.storm_turbidity: rain muddies everything)
##   L    drop a floating log at the LogSpawn marker (if the scene has one)

@export var title := "Flowing Water example"
@export_multiline var description := ""
@export var allow_style_cycle := true

const STYLES := ["spring", "clear_mountain", "glacial", "lowland", "peat", "muddy", "stylized", "toon"]
const LOG_SCENE := "res://examples/shared/log.tscn"
var _style_idx := 0
var _label: Label
var _status := ""


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(14, 10)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label, false, Node.INTERNAL_MODE_BACK)
	_refresh()


func _refresh() -> void:
	var keys := "1-4 debug views   Q quality   R rain"
	if allow_style_cycle:
		keys += "   5 style"
	if _spawn() != null:
		keys += "   L drop a log"
	if get_parent().get_node_or_null("Player") != null:
		keys += "\nWalk into logs to push them   E pick up / drop   F throw"
	else:
		keys += "\nLeft-click a log to shove it"
	_label.text = "%s\n%s\n%s%s" % [title, description, keys, ("\n" + _status) if _status != "" else ""]


func _spawn() -> Node3D:
	return get_parent().get_node_or_null("LogSpawn") as Node3D


func _water_bodies(n: Node, out: Array) -> void:
	if n is WaterRiver or n is WaterPond:
		out.append(n)
	for c in n.get_children():
		_water_bodies(c, out)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var bodies: Array = []
	_water_bodies(get_parent(), bodies)
	match (event as InputEventKey).keycode:
		KEY_1, KEY_2, KEY_3, KEY_4:
			var view: int = (event as InputEventKey).keycode - KEY_1
			for b in bodies:
				b.debug_view = view
			_status = "view: " + ["final", "flow speed", "foam mask", "depth"][view]
		KEY_5:
			if allow_style_cycle:
				_style_idx = (_style_idx + 1) % STYLES.size()
				var st: WaterStyle = load("res://addons/flowing_water/styles/%s.tres" % STYLES[_style_idx])
				for b in bodies:
					b.style = st
				_status = "style: " + STYLES[_style_idx]
		KEY_Q:
			var mgr := get_tree().root.get_node_or_null("WaterManager")
			if mgr != null:
				mgr.quality = (mgr.quality + 1) % 4
				_status = "quality: " + ["Deck", "Low", "Medium", "High"][mgr.quality]
		KEY_R:
			var mgr2 := get_tree().root.get_node_or_null("WaterManager")
			if mgr2 != null:
				mgr2.storm_turbidity = 0.0 if mgr2.storm_turbidity > 0.01 else 0.6
				_status = "storm turbidity: %.1f" % mgr2.storm_turbidity
		KEY_L:
			var spawn := _spawn()
			if spawn != null:
				var lg: RigidBody3D = load(LOG_SCENE).instantiate()
				get_parent().add_child(lg)
				lg.global_position = spawn.global_position + Vector3(randf() - 0.5, 0.0, randf() - 0.5)
				lg.rotation.y = randf() * TAU
	_refresh()
