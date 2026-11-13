# Flowing Water

Rivers, streams, waterfalls and ponds for **Godot 4.7**. Draw a river down a
slope, press **Bake**, and get water that flows around rocks, pushes the
player, carries floating objects and runs well on a Steam Deck. Pure
GDScript and shaders: no GDExtension, nothing to compile.

<p align="center">
  <img src="docs/images/waterfall.jpg" alt="The demo scene: a stream pouring over a mossy rock ledge into a plunge pool" width="800">
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License: Apache-2.0"></a>
  <img src="https://img.shields.io/badge/Godot-4.7-478cbf" alt="Godot 4.7">
</p>

## In motion

<table>
  <tr>
    <td><img src="docs/images/clip_wade.gif" alt="Wading down a stream: ripples, a wake and floating logs drifting past" width="320"></td>
    <td><img src="docs/images/clip_fall.gif" alt="Stepping into the waterfall: the falling sheet parts around the body" width="320"></td>
  </tr>
  <tr>
    <td align="center">Wading: ripples, wake, the current's push</td>
    <td align="center">Step into a waterfall and the sheet parts around you</td>
  </tr>
  <tr>
    <td><img src="docs/images/clip_shove.gif" alt="Running into a floating log knocks it away" width="320"></td>
    <td><img src="docs/images/clip_carry.gif" alt="Picking up a log and throwing it into the stream" width="320"></td>
  </tr>
  <tr>
    <td align="center">Shove floating logs</td>
    <td align="center">Pick them up and throw them back in</td>
  </tr>
  <tr>
    <td><img src="docs/images/clip_styles.gif" alt="Cycling through the water style presets on the same pool" width="320"></td>
    <td><img src="docs/images/clip_flow.gif" alt="Raising the river's discharge: the flow is re-baked live and runs faster and whiter" width="320"></td>
  </tr>
  <tr>
    <td align="center">Eight style presets, from glacial to muddy to toon</td>
    <td align="center">More water: the flow is re-baked live</td>
  </tr>
</table>

Images and clips are recorded in the author's demo scene, which is not part
of this repository (see [License](#license)).

## Install

1. Copy [`addons/flowing_water/`](addons/flowing_water) into your project's
   `addons/` folder (or download the repository zip and keep only that folder).
2. **Project → Project Settings → Plugins** → enable **Flowing Water**.

The addon is self-contained and works in an empty project. The full manual
(nodes, baking, styles, gameplay API, underwater, quality presets) is in
[addons/flowing_water/README.md](addons/flowing_water/README.md).

## Getting started

1. Add a **WaterRiver** node and draw its curve down a slope over ground
   that has a collider (terrain and rocks as `StaticBody3D`).
2. Set the width per point, then press **Bake** in the inspector.
3. Add a **WaterInteractor** to your character and a **WaterFloater** to
   anything that should float.

Ponds (**WaterPond**), river-to-pond joins (**WaterJunction**), styles,
quality presets and the gameplay API are covered in the
[manual](addons/flowing_water/README.md).

## Repository layout

```
addons/flowing_water/   the addon: the only folder you need in your game
docs/                   images for this page
```

## License

Copyright 2026 Piotr Gródek and the Flowing Water contributors. Licensed
under the [Apache License, Version 2.0](LICENSE); see also [NOTICE](NOTICE).

This repository contains no third-party code or assets. The images on this
page are the author's own renders of a demo scene that is not distributed
here; that scene uses CC0 textures and rock scans from
[Poly Haven](https://polyhaven.com), which are not included.

## Disclaimer

Flowing Water is a personal, open-source project developed in the author's
spare time, on personal equipment. It is not affiliated with, sponsored or
endorsed by, and does not represent any current or former employer of the
author; the views and code here are the author's own. Names of third-party
projects (Godot Engine, Poly Haven, Steam Deck) are used only to identify
the software, assets and hardware involved and do not imply endorsement by
their owners.

Generative AI tools were used in developing this project, including code
and documentation.

Flowing Water is provided "as is", without warranty of any kind (see the
license). To the maximum extent permitted by applicable law, the author
accepts no liability for any damages or losses arising from its use.
