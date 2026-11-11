# Contributing

The maintainer does not promise that pull requests will be reviewed or
merged, and contributions must follow the rules below to be considered.
This is an open-source project, and everyone is free to keep their own
version.

## Development setup

Open the repository root in Godot 4.7 (it is a Godot project). The checks
in `tools/` are run from the repository root (`G` is your Godot binary):

```bash
G=/path/to/Godot
$G --headless --path . --import                       # after editing any .glsl compute shader
$G --headless --path . --script tools/check_all.gd    # scripts, shaders, synthetic bake assertions
$G --path . res://tools/check_scenes.tscn             # loads every example: baked, queries, floating logs
```

Visual changes: render before/after screenshots with
`res://tools/screenshot.tscn` (output goes to `tools/shots/`, which is not
committed) and include them in the pull request.

## Ground rules

- The addon (`addons/flowing_water/`) must stay self-contained: pure
  GDScript and shaders, no GDExtension, and nothing under `addons/` may
  reference `examples/` or `tools/`.
- Example-only assets go in `examples/` and must be CC0 or otherwise
  redistributable. Record their source in `NOTICE`.
- `check_all.gd` and `check_scenes.tscn` must pass with no errors.

By contributing you agree that your contributions are licensed under
Apache-2.0 (section 5 of the license). You keep the copyright to your
contributions. New source files (`.gd`, `.gdshader`, `.gdshaderinc`,
`.glsl`, `.sh`) start with the same two SPDX lines as the existing ones:

```
SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
SPDX-License-Identifier: Apache-2.0
```
