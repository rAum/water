#!/bin/sh
# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0
#
# Records the README clips and encodes them as small GIFs in docs/images/.
# Usage: tools/make_gifs.sh [clip ...]   (default: all)
# Needs ffmpeg. Godot path from $GODOT or the usual app location.
set -e
cd "$(dirname "$0")/.."
G="${GODOT:-/Users/raum/Downloads/Godot.app/Contents/MacOS/Godot}"
CLIPS="${*:-wade shove carry fall styles flow}"
for c in $CLIPS; do
	"$G" --path . res://tools/record_clips.tscn --resolution 640x360 --fixed-fps 30 -- clip="$c" 2>&1 | grep "^clip " || true
	# 10 fps, 320 px wide, 48 colours, one shared palette, ordered dither (compresses
	# far better than error diffusion), only changed rectangles stored
	ffmpeg -loglevel error -y -framerate 30 -i "tools/clips/$c/f%04d.png" \
		-vf "fps=10,scale=320:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=48:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
		"docs/images/clip_$c.gif"
	ls -l "docs/images/clip_$c.gif" | awk '{printf "%s %d KB\n", $9, $5/1024}'
done
