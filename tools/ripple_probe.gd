# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends Node
## Walks the demo player through the stream and reads the ripple heights
## back: the wake must stay a ripple, never a trough down to the bed.
## Run: godot --path . res://tools/ripple_probe.tscn

var _demo: Node


func _ready() -> void:
	_demo = load("res://examples/demo/demo.tscn").instantiate()
	add_child(_demo)
	_run.call_deferred()


func _run() -> void:
	for i in 60:
		await get_tree().process_frame
	var p := _demo.get_node("Player") as CharacterBody3D
	var rv := _demo.get_node("Stream") as WaterRiver
	var mgr := get_tree().root.get_node("WaterManager")
	var sim = mgr.get("_ripples") if mgr.get("_ripples") != null else null
	if sim == null:
		for c in mgr.get_children():
			if c is RippleSim:
				sim = c
	var worst := 0.0
	for leg in 3:
		var s := 26.0 + leg * 6.0
		for n in 150:
			var f := rv.frame_at(s + n * 0.02)
			p.global_position = rv.global_transform * (f["pos"] as Vector3) + Vector3.DOWN * 0.2
			p.velocity = Vector3.ZERO
			await get_tree().physics_frame
		var rid: RID = sim.output_rd_texture()
		if not rid.is_valid():
			print("ripples asleep")
			continue
		var rd := RenderingServer.get_rendering_device()
		var bytes := rd.texture_get_data(rid, 0)
		var rect: Vector4 = sim.world_rect()
		var n := int(rect.w)
		var lo := 0.0
		var hi := 0.0
		var lo_near := 0.0
		for k in range(0, bytes.size(), 4):
			var h := bytes.decode_half(k)
			lo = minf(lo, h)
			hi = maxf(hi, h)
			var cell := k / 4
			var wx := rect.x + (float(cell % n) + 0.5) * rect.z / float(n)
			var wz := rect.y + (float(cell / n) + 0.5) * rect.z / float(n)
			if Vector2(wx - p.global_position.x, wz - p.global_position.z).length() < 2.5:
				lo_near = minf(lo_near, h)
		var q = mgr.query(p.global_position)
		print("leg %d: ripple min %.3f max %.3f, within 2.5 m of the player %.3f; water depth there %.2f" % [leg, lo, hi, lo_near, q.depth])
		worst = minf(worst, lo_near)
	print("deepest trough at the player %.3f m" % worst)
	get_tree().quit()
