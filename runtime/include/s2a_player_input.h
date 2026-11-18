// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stdint.h>
// Versioned coherent four-player snapshot. Native owns synchronization; the HID
// thread never accesses platform objects. Buttons use the existing low 16 bits,
// sticks use [-32767,32767]. Disconnected slots must never mirror another slot.
#define S2A_PLAYER_INPUT_VERSION 1u
#define S2A_PLAYER_INPUT_COUNT 4u
typedef struct {
    uint32_t buttons;
    int32_t lx, ly, rx, ry;
} s2a_player_input_slot;
typedef struct {
    uint32_t version, bytes, connected_mask, active;
    s2a_player_input_slot slots[S2A_PLAYER_INPUT_COUNT];
} s2a_player_input_frame;
// Optional symbol: s2a_player_input_read_v1(frame*, capacity). Returns 1 only
// after writing a full coherent frame; 0 means unavailable (release all input).
// Export this only when the platform really implements independent sampling.
// Its presence selects this path for the entire session, never a per-frame
// fallback to the old primary/mirrored input path. No pointers retained.

#if defined(__cplusplus)
static_assert(sizeof(s2a_player_input_slot) == 20, "player slot ABI");
static_assert(sizeof(s2a_player_input_frame) == 96, "player frame ABI");
#else
_Static_assert(sizeof(s2a_player_input_slot) == 20, "player slot ABI");
_Static_assert(sizeof(s2a_player_input_frame) == 96, "player frame ABI");
#endif
