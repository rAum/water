# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends CanvasLayer
## On-screen help and hotkeys shared by the example scenes.
##   1-4  debug views (final / flow speed / foam mask / depth)
##   5    cycle the style presets        Q  cycle quality presets
##   R    toggle storm turbidity (WaterManager.storm_turbidity: rain muddies everything)
##   L    drop a floating log at the LogSpawn marker (if the scene has one)
##   [ ]  less / more water: scales every river's discharge and re-bakes the
##        flow at runtime (WaterRiver.discharge; junction chains re-solve in order)
##   H    show / hide the full help

@export var title := "Flowing Water example"
@export_multiline var description := ""
@export var allow_style_cycle := true

const STYLES := ["spring", "clear_mountain", "glacial", "lowland", "peat", "muddy", "stylized", "toon"]
const LOG_SCENE := "res://examples/shared/log.tscn"
var _style_idx := 0
var _label: Label
var _status := ""
var _help := false
var _baking := false
## Discharge multiplier relative to the scene as saved.
var _flow_scale := 1.0
var _base_discharge := {}


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
	var keys: String
	if _help:
		keys = _full_help()
	else:
		keys = "1-4 debug views   Q quality   R rain   [ ] flow"
		if allow_style_cycle:
			keys += "   5 style"
		if _spawn() != null:
			keys += "   L drop a log"
		if get_parent().get_node_or_null("Player") != null:
			keys += "\nWalk into logs to push them   E pick up / drop   F throw"
		else:
			keys += "\nLeft-click a log to shove it"
		keys += "   H full help"
	_label.text = "%s\n%s\n%s%s" % [title, description, keys, ("\n" + _status) if _status != "" else ""]


func _full_help() -> String:
	var mgr := get_tree().root.get_node_or_null("WaterManager")
	var q: String = ["Deck", "Low", "Medium", "High"][mgr.quality] if mgr != null else "-"
	var lines := PackedStringArray()
	lines.append("--- help (H to hide) ---")
	if get_parent().get_node_or_null("Player") != null:
		lines.append("WASD walk   Shift run   Space jump   mouse look (click to capture, Esc to release)")
		lines.append("E pick up / drop a log   F throw the held log   walk into logs to shove them")
	else:
		lines.append("WASD fly   Q/E down/up   Shift faster   right mouse look   left-click a log to shove it")
	lines.append("1 final look   2 flow speed (blue slow -> white fast)   3 foam mask   4 depth")
	lines.append("[ less water   ] more water: scales river discharge and re-bakes (now x%.2f)" % _flow_scale)
	lines.append("Q quality preset: Deck / Low / Medium / High (now %s)" % q)
	lines.append("R rain: storm turbidity muddies every river at once")
	if allow_style_cycle:
		lines.append("5 next style: " + ", ".join(STYLES))
	if _spawn() != null:
		lines.append("L drop a floating log upstream")
	lines.append("In the editor: select a river for discharge, widths, waterfall threshold;")
	lines.append("its Style resource for colour, clarity, foam, waves and caustics.")
	return "\n".join(lines)


func _rivers(bodies: Array) -> Array:
	return bodies.filter(func(b): return b is WaterRiver)


## Scales every river's discharge and re-solves the flow. Rivers joined by a
## pond re-bake as one chain (inflow -> pond -> outflow) through their
## junction, so the outlet carries what the pond receives.
func _set_flow_scale(bodies: Array, f: float) -> void:
	if _baking:
		return
	var rivers := _rivers(bodies)
	if rivers.is_empty():
		return
	f = clampf(f, 0.25, 4.0)
	if is_equal_approx(f, _flow_scale):
		return
	_flow_scale = f
	_baking = true
	_status = "re-baking the flow at x%.2f ..." % f
	_refresh()
	# let the status draw before the (blocking) solve
	await get_tree().process_frame
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	for r: WaterRiver in rivers:
		if not _base_discharge.has(r):
			_base_discharge[r] = r.discharge
		r.discharge = _base_discharge[r] * f
	var junctions: Array = []
	_junctions(get_parent(), junctions)
	var done := {}
	for j: WaterJunction in junctions:
		var key: Object = j.get_pond() if j.get_pond() != null else j.get_river()
		if key == null or done.has(key):
			continue
		done[key] = true
		j.bake_all()
		if j.get_pond() != null:
			for jj in j.get_pond()._junctions:
				if jj is WaterJunction:
					done[jj.get_river()] = true
		else:
			done[j.get_river()] = true
	for r: WaterRiver in rivers:
		if not done.has(r):
			r.bake_segments_blocking()
	var top := 0.0
	for r: WaterRiver in rivers:
		for d in r.baked_segments:
			if d != null:
				top = maxf(top, d.max_speed)
	_status = "flow x%.2f (discharge %.1f m3/s): fastest water %.1f m/s, re-baked in %d ms" % [
		f, (rivers[0] as WaterRiver).discharge, top, Time.get_ticks_msec() - t0]
	_baking = false
	_refresh()


func _junctions(n: Node, out: Array) -> void:
	if n is WaterJunction:
		out.append(n)
	for c in n.get_children():
		_junctions(c, out)


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
		KEY_BRACKETLEFT:
			_set_flow_scale(bodies, _flow_scale / 1.4)
			return
		KEY_BRACKETRIGHT:
			_set_flow_scale(bodies, _flow_scale * 1.4)
			return
		KEY_H:
			_help = not _help
		KEY_L:
			var spawn := _spawn()
			if spawn != null:
				var lg: RigidBody3D = load(LOG_SCENE).instantiate()
				get_parent().add_child(lg)
				lg.global_position = spawn.global_position + Vector3(randf() - 0.5, 0.0, randf() - 0.5)
				lg.rotation.y = randf() * TAU
	_refresh()
