# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends SceneTree
func _init():
	var path := "res://examples/data/01_stream_Stream_water_0.res"
	for a in OS.get_cmdline_user_args():
		path = a
	var d: WaterData = load(path)
	print("rows %d  mist %d spray %d" % [d.rows, d.mist_points.size(), d.spray_points.size()])
	for j in range(0, d.rows, 6):
		var wet := 0
		var mx := 0.0
		var fo := 0.0
		var dep := 0.0
		for i in d.cells_across:
			var k := j * d.cells_across + i
			if d.depth[k] > 0.03:
				wet += 1
				mx = maxf(mx, Vector2(d.vel_across[k], d.vel_along[k]).length())
				fo += d.foam[k]
				dep = maxf(dep, d.depth[k])
		print("row %3d z=%5.1f slope=%.3f hw=%.2f wet=%2d maxdep=%.2f maxv=%.2f mean=%.2f foam=%.2f" % [j, d.row_center[j].z, d.row_slope[j], d.row_half_width[j], wet, dep, mx, d.row_mean_speed[j], fo / maxf(wet, 1)])
	quit()
