// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stddef.h>
#include <stdint.h>
// Switch full input report, including report ID. Axes are normalized, up positive.
// No deadzone here: the user's mapping applies it once, after decoding.
typedef struct { uint32_t buttons; float axes[4]; } s2a_nspro_state;
static inline int s2a_nspro_decode(const uint8_t *p, size_t size, s2a_nspro_state *out) {
    if (!p || !out || size < 49 || p[0] != 0x30) return 0;
    s2a_nspro_state s = {0};
    const unsigned byte[] = {3,3,3,3,4,4,5,3,5,3,4,4,5,5,5,5};
    const unsigned bit[] = {3,2,1,0,3,2,6,6,7,7,1,0,3,1,2,0};
    for (unsigned i = 0; i < 16; i++) if (p[byte[i]] & (1u << bit[i])) s.buttons |= 1u << i;
    unsigned raw[] = {p[6] | (p[7] & 15) << 8, p[7] >> 4 | p[8] << 4,
                      p[9] | (p[10] & 15) << 8, p[10] >> 4 | p[11] << 4};
    for (unsigned i = 0; i < 4; i++) {
        int v = (int)raw[i] - 2048;
        s.axes[i] = (float)v / (v < 0 ? 2048 : 2047);
    }
    *out = s;
    return 1;
}

// Full report 0x30 contains three chronological 12-byte IMU samples at 13/25/37.
// Use the newest sample, signed little-endian; default Switch ranges are ±8 g
// and ±2000 degrees/s. Factory/user bias calibration is not applied here.
typedef struct { float acceleration[3], gyro[3]; } s2a_nspro_motion;
static inline int s2a_nspro_signed16(const uint8_t *p) {
    unsigned value = (unsigned)p[0] | (unsigned)p[1] << 8;
    return value >= 32768 ? (int)value - 65536 : (int)value;
}
static inline int s2a_nspro_decode_motion(const uint8_t *p, size_t size, s2a_nspro_motion *out) {
    if (!p || !out || size < 49 || p[0] != 0x30) return 0;
    s2a_nspro_motion sample;
    for (unsigned i = 0; i < 3; i++) {
        sample.acceleration[i] = s2a_nspro_signed16(p + 37 + i * 2) / 4096.0f;
        sample.gyro[i] = s2a_nspro_signed16(p + 43 + i * 2) * (2000.0f / 32768.0f);
    }
    *out = sample;
    return 1;
}
