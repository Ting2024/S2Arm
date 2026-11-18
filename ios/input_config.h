// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include "s2a_input_config.h"
#include "s2a_pad.h"
// File access stays in the Apple shell. Relative import paths are under
// S2A_DOCS or the app Documents directory. No keyboard/mouse sampling here.
int s2a_ios_input_config_read(const char *path, s2a_input_config *out);
// Main thread, before starting host/input threads. A failed load exposes no
// current table; the caller must refuse this startup rather than use old input.
// Stored settings for the frozen game/user take precedence over launch defaults.
int s2a_ios_input_config_load(void);
// Thread-local copy, valid until the next current() call on this thread.
const s2a_input_config *s2a_ios_input_config_current(void);

// A rejected live change preserves the previous mapping and held input.
int s2a_ios_input_config_apply(const char *json, size_t bytes);
// Read + map under the same publication lock as live updates. Touch stays
// untouched; physical controllers use schema-1 Nintendo-canonical sources.
void s2a_ios_input_read(s2a_pad_snapshot *out);
void s2a_ios_input_map_physical(uint32_t raw_buttons, const int32_t raw_axes[4], uint32_t *out_buttons, int32_t out_axes[4]);
void s2a_ios_input_map_keyboard(const uint8_t mac_keys[128], unsigned modifiers, uint32_t *out_buttons, int32_t out_axes[4]);
#ifdef __OBJC__
@class NSUserDefaults;
// Scoped preference store. Production uses standardUserDefaults; tests supply
// a private suite. Scope is frozen at startup, never inferred from a UI label.
int s2a_ios_input_config_load_preferences(NSUserDefaults *defaults);
int s2a_ios_input_config_apply_saved(const char *json, size_t bytes, NSUserDefaults *defaults);
int s2a_ios_input_config_can_save(void);
#endif
