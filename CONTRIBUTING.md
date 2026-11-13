# Contributing

The maintainer does not promise that pull requests will be reviewed or
merged, and contributions must follow the rules below to be considered.
This is an open-source project, and everyone is free to keep their own
version.

## Development setup

Copy (or symlink) `addons/flowing_water/` into a Godot 4.7 project and
enable the plugin. After editing any `.glsl` compute shader, re-import
(`godot --headless --path <project> --import`), or the old shader keeps
running.

Visual changes: include before/after screenshots in the pull request.

## Ground rules

- The addon must stay self-contained: pure GDScript and shaders, no
  GDExtension, and nothing under `addons/` may depend on files outside it.
- No third-party code or assets in this repository, including textures,
  models and sounds, even under permissive licences.
- Scripts and shaders must load without errors in Godot 4.7.

By contributing you agree that your contributions are licensed under
Apache-2.0 (section 5 of the license). You keep the copyright to your
contributions. New source files (`.gd`, `.gdshader`, `.gdshaderinc`,
`.glsl`, `.sh`) start with the same two SPDX lines as the existing ones:

```
SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
SPDX-License-Identifier: Apache-2.0
```
