# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0

class_name WaterFallHits
extends RefCounted
## What a body standing in a waterfall does to it: the water that hits the
## body does not fall on below it, so the sheet opens a gap under the body
## that travels down with the water and closes again from the top when the
## body leaves.
##
## The record is a small grid in the falling water's own frame: across the
## ribbon (u, 0..1) by time of flight since the lip. In that frame every
## parcel of water moves at the same speed (one second per second), so
## "advecting" the grid is only a matter of moving a ring buffer's head one
## row per step: a cell written at the body's height then rides down the
## fall by itself. Each step the row that comes round to the lip is cleared
## (fresh water), and every blocker marks the row at its own height.
##
## The shader reads the grid at (u, head + time_of_flight / ROW_DT) and cuts
## the gap (with a white, torn rim) into the sheet.

## Columns across the ribbon.
const COLS := 64
## Rows of flight time. ROWS * ROW_DT is the longest flight recorded
## (1.6 s: a 12.5 m fall); below that the sheet is left alone.
const ROWS := 64
const ROW_DT := 0.025

var image: Image
var texture: ImageTexture
## Ring-buffer row that holds the water now at the lip (fractional: the
## shader interpolates between steps so the gap glides instead of ticking).
var head := 0.0
var active := false

var _data: PackedByteArray
var _head_row := 0
var _accum := 0.0
var _blocked_rows := 0     # rows since the last write: the grid is empty when >= ROWS
var _dirty := false


func _init() -> void:
	_data = PackedByteArray()
	_data.resize(COLS * ROWS)
	image = Image.create_from_data(COLS, ROWS, false, Image.FORMAT_L8, _data)
	texture = ImageTexture.create_from_image(image)
	_blocked_rows = ROWS


## Advances the water by delta seconds. Call once per frame, then mark().
func step(delta: float) -> void:
	_accum += delta
	# (a long hitch is not replayed row by row: past ROWS steps the grid is
	# empty anyway)
	var n := mini(int(_accum / ROW_DT), ROWS + 1)
	_accum -= float(n) * ROW_DT
	if _accum > ROW_DT:
		_accum = 0.0
	for k in n:
		_head_row = (_head_row - 1 + ROWS) % ROWS
		if _blocked_rows < ROWS:
			# the oldest water leaves the record; this row is the lip's now
			var o := _head_row * COLS
			for i in COLS:
				_data[o + i] = 0
			_dirty = true
		_blocked_rows += 1
	head = float(_head_row) - _accum / ROW_DT
	active = _blocked_rows < ROWS


## A body blocks the water at flight time t over the ribbon columns
## u0..u1 (0..1), with strength 0..1.
func mark(t: float, u0: float, u1: float, strength: float) -> void:
	if t < 0.0 or t > ROW_DT * float(ROWS - 2):
		return
	var r := (_head_row + int(t / ROW_DT)) % ROWS
	var v := int(clampf(strength, 0.0, 1.0) * 255.0)
	var c0 := clampi(int(floor(u0 * float(COLS))), 0, COLS - 1)
	var c1 := clampi(int(ceil(u1 * float(COLS))), 0, COLS - 1)
	var o := r * COLS
	for i in range(c0, c1 + 1):
		# soft shoulders: a body's edge only thins the water
		var e := 1.0
		if c1 > c0:
			var x := (float(i) - float(c0)) / float(c1 - c0)
			e = clampf(minf(x, 1.0 - x) * 4.0 + 0.25, 0.0, 1.0)
		_data[o + i] = maxi(_data[o + i], int(float(v) * e))
	_blocked_rows = 0
	active = true
	_dirty = true


## Uploads the grid if anything changed this frame.
func upload() -> void:
	if not _dirty:
		return
	_dirty = false
	image.set_data(COLS, ROWS, false, Image.FORMAT_L8, _data)
	texture.update(image)
