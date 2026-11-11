#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
# SPDX-License-Identifier: Apache-2.0
# Underwater look-dev set: ./tools/uw_shots.sh <prefix> [extra screenshot args]
# Renders the same swimmer's-eye shots every time so before/after compare.
G=${GODOT:-/Users/raum/Downloads/Godot.app/Contents/MacOS/Godot}
A=res://examples
P=$1; shift
cd "$(dirname "$0")/.."
run() { $G --path . res://tools/screenshot.tscn --resolution 1280x800 -- "$@" 2>&1 | grep -E "shot:|ERROR|error|WARNING" ; }
run scene=$A/demo/demo.tscn shot=${P}_pond:2,-0.8,3.5:1.5,-1.0,-6 shot=${P}_pond_up:2,-1.1,3:2.5,0.3,-2 shot=${P}_pond_down:3,-0.5,2:1,-1.6,-2 shot=${P}_waterline:2,-0.012,3.5:1.5,-0.1,-6 shot=${P}_above:2,1.6,6:1.5,0,-6 "$@"
run scene=$A/03_waterfall.tscn shot=${P}_plunge:-2.2,-0.8,4.6:-0.9,-0.6,0.4 shot=${P}_plunge_up:-2.6,-0.95,4.6:-1.5,0.3,1.5 "$@"
run scene=$A/07_lowland_river.tscn shot=${P}_lowland:7.8,-0.4,-11.5:9.2,-0.6,-9.5 shot=${P}_lowland_up:7,-0.45,-11:7.6,0.02,-9.6 "$@"
run scene=$A/demo/demo.tscn style=spring shot=${P}_cmp_spring:2,-0.8,3.5:1.5,-1.0,-6 "$@"
run scene=$A/demo/demo.tscn style=muddy shot=${P}_cmp_muddy:2,-0.8,3.5:1.5,-1.0,-6 "$@"
