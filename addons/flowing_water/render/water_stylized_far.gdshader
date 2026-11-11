// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

shader_type spatial;
render_mode depth_draw_always, cull_disabled, specular_schlick_ggx;
#define DETAIL_LAYERS 1
#define STYLIZED
#include "water_surface_body.gdshaderinc"
