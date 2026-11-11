# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

extends SceneTree
## Regenerates the shared water textures (noise, waterfall fluid, spray puff).
func _init():
	var t0 := Time.get_ticks_msec()
	var err := ResourceSaver.save(WaterNoise.generate(512), "res://addons/flowing_water/render/water_noise.res", ResourceSaver.FLAG_COMPRESS)
	var err2 := ResourceSaver.save(WaterNoise.generate_fall(512), "res://addons/flowing_water/render/water_fall.res", ResourceSaver.FLAG_COMPRESS)
	var err3 := ResourceSaver.save(WaterNoise.generate_puff(128), "res://addons/flowing_water/render/water_puff.res", ResourceSaver.FLAG_COMPRESS)
	print("noise: err=%d %d %d, %d ms" % [err, err2, err3, Time.get_ticks_msec() - t0])
	quit(0 if err == OK and err2 == OK and err3 == OK else 1)
