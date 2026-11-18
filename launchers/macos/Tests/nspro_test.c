// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_nspro.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
int main(void) {
    uint8_t p[49] = {0x30};
    p[7] = p[10] = 8; p[8] = p[11] = 128; // both axes 2048
    s2a_nspro_state s = {0};
    assert(s2a_nspro_decode(p, sizeof p, &s));
    assert(s.buttons == 0);
    for (int i = 0; i < 4; i++) assert(s.axes[i] == 0);
    const unsigned byte[] = {3,3,3,3,4,4,5,3,5,3,4,4,5,5,5,5};
    const unsigned bit[] = {3,2,1,0,3,2,6,6,7,7,1,0,3,1,2,0};
    for (int i = 0; i < 16; i++) {
        p[byte[i]] = 1u << bit[i];
        assert(s2a_nspro_decode(p, sizeof p, &s));
        assert(s.buttons == (1u << i)); p[byte[i]] = 0;
    }
    memset(p + 6, 0, 6); assert(s2a_nspro_decode(p, sizeof p, &s));
    for (int i = 0; i < 4; i++) assert(s.axes[i] == -1);
    memset(p + 6, 255, 6); assert(s2a_nspro_decode(p, sizeof p, &s));
    for (int i = 0; i < 4; i++) assert(s.axes[i] == 1);
    // Mixed axes catch left/right or X/Y swaps, not just all-min/all-max.
    const uint8_t mixed[] = {0, 0xf0, 255, 0, 8, 128};
    memcpy(p + 6, mixed, sizeof mixed);
    assert(s2a_nspro_decode(p, sizeof p, &s));
    assert(s.axes[0] == -1 && s.axes[1] == 1 && s.axes[2] == 0 && s.axes[3] == 0);
    s2a_nspro_state saved = s;
    for (int n = 0; n < 49; n++) assert(!s2a_nspro_decode(p, n, &s));
    p[0] = 0x21; assert(!s2a_nspro_decode(p, sizeof p, &s));
    assert(!s2a_nspro_decode(NULL, sizeof p, &s));
    assert(memcmp(&s, &saved, sizeof s) == 0);
    p[0] = 0x30;
    memset(p + 13, 0x7f, 24); // Older two samples must not leak into the newest.
    const uint8_t imu[] = {0,16,0,240,0,128,0,64,0,192,255,127};
    memcpy(p + 37, imu, 12);
    s2a_nspro_motion m;
    assert(s2a_nspro_decode_motion(p, 49, &m));
    assert(m.acceleration[0] == 1 && m.acceleration[1] == -1 && m.acceleration[2] == -8);
    assert(m.gyro[0] == 1000 && m.gyro[1] == -1000);
    assert(fabsf(m.gyro[2] - 1999.93896484375f) < 0.001f);
    s2a_nspro_motion old = m;
    for (int n = 0; n < 49; n++) assert(!s2a_nspro_decode_motion(p, n, &m));
    p[0] = 0x21; assert(!s2a_nspro_decode_motion(p, 49, &m));
    assert(!s2a_nspro_decode_motion(NULL, 49, &m));
    assert(!s2a_nspro_decode_motion(p, 49, NULL));
    assert(!memcmp(&old, &m, sizeof m));
    puts("NS Pro: 16 buttons, 4 axes, bounds and malformed-report controls passed");
}
