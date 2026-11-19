// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define S2A_CONTROLLER_SLOTS 4
#define S2A_CONTROLLER_ID_BYTES 256
#define S2A_CONTROLLER_MAX_DEVICES 64
// Values preserve the existing schema-1 controller backend ABI.
enum { S2A_CONTROLLER_SYSTEM = 0, S2A_CONTROLLER_NSPRO = 1,
       S2A_CONTROLLER_DISABLED = 2, S2A_CONTROLLER_AUTO = 3 };
typedef struct {
    int backend;
    char device[S2A_CONTROLLER_ID_BYTES]; // empty = automatic device assignment
} s2a_controller_selection;
typedef struct {
    int backend; // concrete SYSTEM / NSPRO, never AUTO
    char device[S2A_CONTROLLER_ID_BYTES]; // driver-facing selection ID
    char physical[S2A_CONTROLLER_ID_BYTES]; // one connection identity across driver aliases
} s2a_controller_candidate;
typedef struct {
    int backend; // DISABLED when vacant (never a fallback to another player)
    char device[S2A_CONTROLLER_ID_BYTES];
    char physical[S2A_CONTROLLER_ID_BYTES];
} s2a_controller_assignment;
// Pure planning, no handles, HID requests or global callbacks. A platform must
// supply stable connection identities and coalesce driver aliases before use.
// Explicit selections reserve devices before automatic slots. Duplicate explicit
// claims or ambiguous selector IDs stay vacant. Automatic assignments are sticky
// until disconnect/configuration change, then fill in stable physical-ID order.
// AUTO prefers SYSTEM for a new assignment; it never labels a VID/PID as Betop.
// Invalid input returns 0, leaving out untouched. previous may be NULL or out.
int s2a_controller_assign(const s2a_controller_selection slots[S2A_CONTROLLER_SLOTS],
                          const s2a_controller_candidate *devices, size_t count,
                          const s2a_controller_assignment previous[S2A_CONTROLLER_SLOTS],
                          s2a_controller_assignment out[S2A_CONTROLLER_SLOTS]);
#ifdef __cplusplus
}
#endif
