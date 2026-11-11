# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
extends EditorPlugin
## Flowing Water: registers the WaterManager autoload, the gizmo plugins for
## rivers and ponds, the inspector buttons and the shader globals. Everything
## is cleaned up again on disable.

const AUTOLOAD_NAME := "WaterManager"
const ADDON := "res://addons/flowing_water/"

var _river_gizmos: EditorNode3DGizmoPlugin
var _pond_gizmos: EditorNode3DGizmoPlugin
var _inspector: EditorInspectorPlugin


func _enter_tree() -> void:
	_register_shader_globals_in_project()
	_ensure_noise_texture()
	add_autoload_singleton(AUTOLOAD_NAME, ADDON + "water_manager.gd")
	_river_gizmos = preload(ADDON + "editor/river_gizmo.gd").new()
	add_node_3d_gizmo_plugin(_river_gizmos)
	_pond_gizmos = preload(ADDON + "editor/pond_gizmo.gd").new()
	add_node_3d_gizmo_plugin(_pond_gizmos)
	_inspector = preload(ADDON + "editor/inspector_buttons.gd").new()
	_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
	remove_node_3d_gizmo_plugin(_river_gizmos)
	remove_node_3d_gizmo_plugin(_pond_gizmos)
	remove_inspector_plugin(_inspector)
	_river_gizmos = null
	_pond_gizmos = null
	_inspector = null


func _get_plugin_name() -> String:
	return "Flowing Water"


## Shader globals are declared in the project settings so exported games get
## them without the editor. (Left in place on disable: they are inert without
## the plugin's shaders, and removing them would break saved water scenes.)
func _register_shader_globals_in_project() -> void:
	var manager_script := load(ADDON + "water_manager.gd")
	var changed := false
	for name: String in manager_script.SHADER_GLOBALS:
		var key: String = "shader_globals/" + name
		if ProjectSettings.has_setting(key):
			continue
		var type_str: String = manager_script.SHADER_GLOBALS[name][0]
		var value = manager_script.SHADER_GLOBALS[name][1]
		ProjectSettings.set_setting(key, {"type": type_str, "value": value})
		changed = true
	if changed:
		ProjectSettings.save()


func _ensure_noise_texture() -> void:
	var path := ADDON + "render/water_noise.res"
	if not ResourceLoader.exists(path):
		ResourceSaver.save(WaterNoise.generate(512), path, ResourceSaver.FLAG_COMPRESS)
	if not ResourceLoader.exists(ADDON + "render/water_fall.res"):
		ResourceSaver.save(WaterNoise.generate_fall(512), ADDON + "render/water_fall.res", ResourceSaver.FLAG_COMPRESS)
	if not ResourceLoader.exists(ADDON + "render/water_puff.res"):
		ResourceSaver.save(WaterNoise.generate_puff(128), ADDON + "render/water_puff.res", ResourceSaver.FLAG_COMPRESS)
