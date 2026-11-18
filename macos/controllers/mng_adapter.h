// S2Arm ABI boundary; implementation uses the original MacNativeGames stack.
#pragma once
#include "../../runtime/include/s2a_pad.h"
#include "../../runtime/include/s2a_player_input.h"
// Main thread, once, before starting native controller discovery.
// root must be a caller-owned, captured game/user input directory.
int s2a_mng_input_prepare(const char *root);
void s2a_mng_input_start(void);
int s2a_mng_input_read(s2a_player_input_frame *out, uint32_t capacity);

// Main-thread window events; fallback is the original unassigned P1 keyboard.
void s2a_mng_input_key(unsigned code, int down);
void s2a_mng_input_keys_clear(void);
void s2a_mng_set_controller_active(int active);

// Original MNG rumble (1P-4P) and motion (1P) bridged to S2Arm pad feedback ABI.
uint64_t s2a_mng_pad_rumble_session(void);
void s2a_mng_pad_set_player_rumble_pair(uint64_t session, unsigned player, const s2a_pad_vibration values[2]);
void s2a_mng_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]);
void s2a_mng_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz);
void s2a_mng_pad_stop_rumble(uint64_t session);
void s2a_mng_pad_set_motion_enabled(int enabled);
int s2a_mng_pad_read_motion(s2a_pad_motion *out);
