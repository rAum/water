# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

@tool
class_name WaterData
extends Resource
## Baked flow data for one water body (one river segment, or one pond).
##
## The grid is `cells_across` x `rows`. For rivers the grid follows the curve:
## column i runs across the channel, row j runs downstream, one row every
## `cell_length` metres. For ponds the grid is world-axis aligned over the
## pond bounds: column i runs +X, row j runs +Z, and `cell_length` ==
## `row_cell_width[j]` (square cells).
##
## Textures are half-float (FORMAT_RGBAH) and store real units, no packing:
##   flow_tex: r = speed across / +X (m/s), g = speed along / +Z (m/s),
##             b = foam mask (0-1),         a = depth (m)
##   aux_tex:  r = surface offset (m),      g = aeration (0-1),
##             b = wake (0-1),              a = slope (dH per metre downstream, per cell)
##
## The same data is kept as PackedFloat32Arrays for CPU queries; gameplay never
## reads the GPU back.

## Grid shape.
@export var cells_across: int = 0
@export var rows: int = 0
## Metres covered along the flow by one row.
@export var cell_length: float = 0.25

## Per-row data (length == rows).
@export var row_cell_width: PackedFloat32Array = []   ## metres across covered by one cell
@export var row_slope: PackedFloat32Array = []        ## dH/ds downstream
@export var row_mean_speed: PackedFloat32Array = []
@export var row_height: PackedFloat32Array = []       ## water surface Y of the row
@export var row_center: PackedVector3Array = []       ## world centre of the row
@export var row_dir: PackedVector3Array = []          ## world flow (downstream) direction, normalized, horizontal
@export var row_half_width: PackedFloat32Array = []   ## half width incl. margin, metres

## Waterfall progress of the row's centre (0 off falls, 0..1 lip to foot),
## filled in by the river before the bake.
@export var row_fall_t: PackedFloat32Array = []

## Per-cell data (length == cells_across * rows).
@export var vel_across: PackedFloat32Array = []
@export var vel_along: PackedFloat32Array = []
@export var depth: PackedFloat32Array = []
@export var foam: PackedFloat32Array = []
@export var aeration: PackedFloat32Array = []
@export var wake: PackedFloat32Array = []
@export var surface_offset: PackedFloat32Array = []
## Slope of the water in this cell. Equals the row's slope except at falls,
## where every column leaves the ground and lands at its own place.
@export var cell_slope: PackedFloat32Array = []
## Waterfalls (empty when the river has none): metres a column's brink lies
## upstream of the fall's lip, and its throw as a fraction of the lip-to-foot
## distance (slow water at the edges lands closer to the rock).
@export var fall_lead: PackedFloat32Array = []
@export var fall_throw: PackedFloat32Array = []
## Thickness of the falling sheet (0 where the water is not in the air) and
## 0 where a bank that is dry at the brink leaves no sheet at all.
@export var fall_sheet: PackedFloat32Array = []
@export var fall_wet: PackedFloat32Array = []

## Baked textures (RGBAH).
@export var flow_tex: Texture2D
@export var aux_tex: Texture2D

## Emission points for spray (at rocks / rough water) and mist (below falls).
## Positions are world space; weight scales emission probability.
@export var spray_points: PackedVector3Array = []
@export var spray_weights: PackedFloat32Array = []
@export var spray_velocities: PackedVector3Array = []
@export var mist_points: PackedVector3Array = []
## Points on waterfalls where falling droplets are born, with the water's
## velocity there (they then fall under gravity alongside the sheet).
@export var fall_points: PackedVector3Array = []
@export var fall_velocities: PackedVector3Array = []
## 1 where a cell is inside an obstacle standing in the water (a rock). The
## flow arrays are filled in under obstacles from the water around them, so
## the surface has no holes; this mask keeps the truth for things that need
## it (ripples bounce off it).
@export var obstacle: PackedByteArray = []

## Pond-only: world-space origin (min X/Z corner of the grid) and water level.
@export var grid_origin: Vector3 = Vector3.ZERO
@export var is_pond_grid: bool = false

## Statistics from the bake.
@export var max_speed: float = 0.0
@export var min_row_speed: float = 0.0
@export var total_drop: float = 0.0
@export var bake_ms: float = 0.0
@export var discharge: float = 0.0
## Hash of the collider layout inside the bounds at bake time, used for the
## "bake is out of date" hint.
@export var scene_hash: int = 0
@export var baked_at: String = ""


func cell_index(i: int, j: int) -> int:
	return j * cells_across + i


func is_valid() -> bool:
	return cells_across > 0 and rows > 0 \
		and depth.size() == cells_across * rows \
		and flow_tex != null


## Bilinear sample of one cell array at fractional grid coords.
func sample_array(arr: PackedFloat32Array, fi: float, fj: float) -> float:
	if arr.is_empty():
		return 0.0
	fi = clampf(fi, 0.0, float(cells_across) - 1.001)
	fj = clampf(fj, 0.0, float(rows) - 1.001)
	var i := int(fi)
	var j := int(fj)
	var tx := fi - float(i)
	var tz := fj - float(j)
	var k := j * cells_across + i
	var a := arr[k] * (1.0 - tx) + arr[k + 1] * tx
	var b := arr[k + cells_across] * (1.0 - tx) + arr[k + cells_across + 1] * tx
	return a * (1.0 - tz) + b * tz


## Build the two RGBAH textures from the cell arrays. Called at the end of a
## bake on the main thread.
func build_textures() -> void:
	var nc := cells_across * rows
	var flow_f := PackedFloat32Array()
	flow_f.resize(nc * 4)
	var aux_f := PackedFloat32Array()
	aux_f.resize(nc * 4)
	for k in nc:
		var o := k * 4
		var j := k / cells_across
		flow_f[o] = vel_across[k]
		flow_f[o + 1] = vel_along[k]
		flow_f[o + 2] = foam[k]
		flow_f[o + 3] = depth[k]
		aux_f[o] = surface_offset[k]
		aux_f[o + 1] = aeration[k]
		aux_f[o + 2] = wake[k]
		if cell_slope.size() == nc:
			aux_f[o + 3] = cell_slope[k]
		else:
			aux_f[o + 3] = row_slope[j] if j < row_slope.size() else 0.0
	var flow_img := Image.create_from_data(cells_across, rows, false, Image.FORMAT_RGBAF, flow_f.to_byte_array())
	flow_img.convert(Image.FORMAT_RGBAH)
	var aux_img := Image.create_from_data(cells_across, rows, false, Image.FORMAT_RGBAF, aux_f.to_byte_array())
	aux_img.convert(Image.FORMAT_RGBAH)
	flow_tex = ImageTexture.create_from_image(flow_img)
	aux_tex = ImageTexture.create_from_image(aux_img)
