// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include "s2a_input_config.h"
#include "s2a_player_input.h"
// Raw sampler order is s2a_input_pad_name / s2a_input_axis_name. No keyboard,
// mouse, feedback or device selection: this maps exactly one owned controller.
typedef struct { uint32_t buttons; float axes[4]; } s2a_player_raw_input;
int s2a_player_mapping_valid(const s2a_input_config *config);
// Output cleared on error. Axes are clamped before conversion, nonfinite sensor
// values become neutral. Deadzone is applied once, without rescaling, matching
// schema 1 Mac semantics. Digital stick bindings add before final saturation.
int s2a_player_map(const s2a_input_config *config, const s2a_player_raw_input *raw,
                   s2a_player_input_slot *out);
