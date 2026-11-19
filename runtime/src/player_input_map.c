// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_player_input_map.h"
#include <math.h>
#include <string.h>
int s2a_player_mapping_valid(const s2a_input_config *c) {
    if (!c || !isfinite(c->deadzone) || c->deadzone < 0 || c->deadzone >= 1) return 0;
    for (int i = 0; i < 24; i++) if (c->gamepad[i] < -1 || c->gamepad[i] >= 16) return 0;
    for (int i = 0; i < 4; i++)
        if (c->axes[i].source < -1 || c->axes[i].source >= 4 ||
            (c->axes[i].invert != 0 && c->axes[i].invert != 1)) return 0;
    return 1;
}
int s2a_player_map(const s2a_input_config *c, const s2a_player_raw_input *raw, s2a_player_input_slot *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    if (!raw || !s2a_player_mapping_valid(c)) return 0;
    int32_t sticks[4] = {0};
    for (int i = 0; i < 24; i++) {
        int source = c->gamepad[i];
        if (source < 0 || !(raw->buttons & (1u << source))) continue;
        if (i < 16) out->buttons |= 1u << i;
        else {
            int d = i - 16;
            sticks[(d < 4 ? 0 : 2) + d % 2] += (d % 4 == 0 || d % 4 == 3) ? -32767 : 32767;
        }
    }
    for (int i = 0; i < 4; i++) {
        int source = c->axes[i].source;
        float v = source < 0 ? 0 : raw->axes[source];
        if (!isfinite(v)) v = 0;
        if (v > 1) v = 1;
        if (v < -1) v = -1;
        if (fabsf(v) > c->deadzone) sticks[i] += (int32_t)(v * (c->axes[i].invert ? -32767 : 32767));
        if (sticks[i] > 32767) sticks[i] = 32767;
        if (sticks[i] < -32767) sticks[i] = -32767;
    }
    out->lx = sticks[0]; out->ly = sticks[1]; out->rx = sticks[2]; out->ry = sticks[3];
    return 1;
}
