// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define S2A_INPUT_CONFIG_MAX_BYTES (1u << 20)
#define S2A_INPUT_TARGET_COUNT 24
#define S2A_INPUT_AXIS_COUNT 4
#define S2A_INPUT_PLAYER_COUNT 4
typedef struct { int backend; char device[256]; } s2a_input_controller;
// schema 1 key codes remain Mac virtual key codes. Device samplers translate
// their physical key identifiers at the platform boundary, not in this parser.
typedef struct { int code; unsigned modifiers; } s2a_input_key;
typedef struct { int source, invert; } s2a_input_axis;
typedef struct {
    s2a_input_key keyboard[S2A_INPUT_TARGET_COUNT]; // code -1 = unbound
    int mouse[S2A_INPUT_TARGET_COUNT];              // button -1 = unbound
    int gamepad[S2A_INPUT_TARGET_COUNT];            // source -1 = unbound
    s2a_input_axis axes[S2A_INPUT_AXIS_COUNT];       // source -1 = unbound
    double deadzone, sensitivity_x, sensitivity_y;
    int mouse_camera, invert_x, invert_y, recenter;
    int back_buttons[2]; // GL / GR -> physical pad source; -1 = unbound
    // Optional Mac selection: 0 system (legacy), 1 NS Pro raw HID, 2 disabled.
    int controller_backend;
    char controller_device[256];
    // Optional schema-1 players object: exactly "1".."4". Backend values
    // 0 system, 1 NS Pro, 2 disabled, 3 auto, 4 touch, 5 keyboard. Legacy controller and players
    // are mutually exclusive. No file migration or implicit legacy rewrite.
    int players_present;
    s2a_input_controller players[S2A_INPUT_PLAYER_COUNT];
} s2a_input_config;
enum s2a_input_config_error {
    S2A_INPUT_CONFIG_OK = 0,
    S2A_INPUT_CONFIG_JSON = 1,
    S2A_INPUT_CONFIG_SCHEMA = 2,
    S2A_INPUT_CONFIG_FIELDS = 3,
    S2A_INPUT_CONFIG_TARGET = 4,
    S2A_INPUT_CONFIG_BINDING = 5,
    S2A_INPUT_CONFIG_DUPLICATE = 6,
    S2A_INPUT_CONFIG_RANGE = 7,
    S2A_INPUT_CONFIG_IO = 8,
    S2A_INPUT_CONFIG_PLAYERS_UNSUPPORTED = 9
};
// No file I/O, Apple headers or retained pointers into JSON. Failure leaves out
// unchanged. Optional modifiers/invert/recenter keep schema 1 defaults 0/0/1.
int s2a_input_config_parse(const char *json, size_t bytes, s2a_input_config *out);
void s2a_input_config_default(s2a_input_config *out);
const char *s2a_input_config_error_message(int error);
const char *s2a_input_target_name(int index);
const char *s2a_input_pad_name(int index);
const char *s2a_input_axis_name(int index);
#ifdef __cplusplus
}
#endif
