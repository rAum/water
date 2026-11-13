// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

shader_type spatial;
render_mode depth_draw_always, cull_disabled, specular_schlick_ggx;
#define DETAIL_LAYERS 2
#define USE_SCREEN_TEXTURE
#define USE_DEPTH_BUFFER
#define REFRACTION_FULL
#define VERTEX_WAVES
#define SSR
#define FOAM_DETAIL
#define CAUSTICS_FULL
#include "water_surface_body.gdshaderinc"
