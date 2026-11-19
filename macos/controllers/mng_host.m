// Host-side service callbacks for the original input runtime. No settings logic.
#import <Foundation/Foundation.h>
#include "mng/runtime.h"
#include "mng_adapter.h"
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
extern uint64_t now_ns(void);
extern void s2a_host_shutdown(const char *);
_Noreturn void runtime_fail(const char *message) {
    fprintf(stderr, "[s2a-input] %s\n", message);
    s2a_host_shutdown("native input failure"); abort();
}
uint64_t runtime_now_ns(void) { return now_ns(); }
// FullKey controller topology, independent of graphics docked/portable mode.
int runtime_handheld_mode(void) { return 0; }
void runtime_keys_clear(void) { s2a_mng_input_keys_clear(); runtime_keyboard_clear(); }
void runtime_input_clear(void) { runtime_keys_clear(); runtime_gamepad_clear(); }
// S2Arm's HID pump observes the connection mask every sample.
void runtime_input_gamepads_changed(void) { s2a_mng_input_keys_clear(); }
int runtime_rumble_enabled(void) { return 1; }
int runtime_gyro_enabled(void) { return 1; }
void runtime_hid_feedback_stats(uint64_t *values, uint64_t *reads) {
    if (values) *values = 0;
    if (reads) *reads = 0;
}
__attribute__((visibility("default"), used))
int s2a_player_input_read_v1(s2a_player_input_frame *out, uint32_t capacity) {
    return s2a_mng_input_read(out, capacity);
}
__attribute__((visibility("default"), used))
uint64_t s2a_pad_rumble_session(void) {
    return s2a_mng_pad_rumble_session();
}
__attribute__((visibility("default"), used))
void s2a_pad_set_player_rumble_pair(uint64_t session, unsigned player, const s2a_pad_vibration values[2]) {
    s2a_mng_pad_set_player_rumble_pair(session, player, values);
}
__attribute__((visibility("default"), used))
void s2a_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]) {
    s2a_mng_pad_set_rumble_pair(session, values);
}
__attribute__((visibility("default"), used))
void s2a_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz) {
    s2a_mng_pad_set_rumble(session, side, low_amp, low_hz, high_amp, high_hz);
}
__attribute__((visibility("default"), used))
void s2a_pad_stop_rumble(uint64_t session) {
    s2a_mng_pad_stop_rumble(session);
}
