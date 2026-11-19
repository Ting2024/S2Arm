// S2Arm boundary for the unmodified MacNativeGames input stack.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <pthread.h>
#include <stdatomic.h>
_Noreturn void runtime_fail(const char *message);
uint64_t runtime_now_ns(void);
int runtime_handheld_mode(void);
void runtime_input_clear(void);
void runtime_keys_clear(void);
#define RUNTIME_MAX_GAMEPADS 4
typedef struct { uint64_t buttons; int32_t lx,ly,rx,ry; int connected; } RuntimeGamepadState;
void runtime_gamepad_start(void);
void runtime_gamepad_read(RuntimeGamepadState *out);
void runtime_gamepad_read_index(unsigned index, RuntimeGamepadState *out);
unsigned runtime_gamepad_count(void);
void runtime_input_gamepads_changed(void);   /* a pad was attached or removed; tell the game on its next read */
/* Forget held buttons and sticks: macOS stops delivering controller events (including releases) while the app is in
   the background, so a button held at focus loss would otherwise stay pressed for the game. */
void runtime_gamepad_clear(void);
int runtime_gamepad_type_cycle(void);
int runtime_gamepad_type_set(int type);
int runtime_gamepad_type(int *detected);
int runtime_mouse_toggle(void);
int runtime_mouse_enabled(void);
void runtime_mouse_set_hook(void (*hook)(void));
void runtime_mouse_move(double dx, double dy);
void runtime_mouse_button(int button, int down);
void runtime_mouse_release(void);

/* iOS settings, main queue only. Targets are Switch bit indices, -1 = disabled.
   Save succeeds before the live layout changes. Reset affects only the 16 pad buttons. */
/* Per-port configuration, main queue only, on both platforms. */
int runtime_gamepad_slot_count(void);
int runtime_gamepad_slot_type(int slot);
int runtime_gamepad_slot_type_set(int slot, int type);
int runtime_gamepad_slot_mapping_get(int slot, int physical);
int runtime_gamepad_slot_mapping_set(int slot, int physical, int target);
int runtime_gamepad_slot_mapping_reset(int slot);
/* Target-first editor: group 0 = controller, 1 = mouse. -2 means multiple
   existing inputs; opening the editor must not collapse them. */
int runtime_input_binding_get(int slot, int group, int target);
int runtime_input_binding_set(int slot, int group, int target, int physical);
int runtime_input_binding_reset(int slot, int group);
/* Analog output binding: target 0/1 = NS left/right stick; source 0 = off,
   1 = physical left stick, 2 = physical right stick. Mouse target is 0/off,
   1/left, 2/right, 3/both and is available only on player 1. */
int runtime_input_stick_get(int slot, int target);
int runtime_input_stick_set(int slot, int target, int source);
int runtime_input_mouse_stick_get(void);
int runtime_input_mouse_stick_set(int target);
#define INPUT_MOTION_PLAYERS 1
/* Six-axis source: 0 automatic (existing behavior), 1 controller, 2 mouse, 3 off. */
int runtime_input_gyro_get(int slot);
int runtime_input_gyro_set(int slot, int source);
int runtime_input_motion_allowed(int slot);


int runtime_gamepad_connected(unsigned index); /* does not consume button edges */
int runtime_gamepad_mapping_get(int physical);
int runtime_gamepad_mapping_set(int physical, int target);
int runtime_gamepad_mapping_reset(void);
/* iOS coalesced keyboard configuration (main queue); 0 key means unbound.
   Slot selection is zero-based, -1 disables; key codes are USB HID usages. */
int runtime_keyboard_slot(void);
int runtime_keyboard_slot_count(void);
int runtime_keyboard_bind(int slot);
int runtime_keyboard_mapping_get(int slot, int action);
int runtime_keyboard_mapping_set(int slot, int action, int key);
int runtime_keyboard_mapping_reset(int slot);
void runtime_keyboard_suspend(int suspended);


void runtime_touch_pad_set(const RuntimeGamepadState *state);   /* on-screen touch controls (iOS) */
/* Controller rumble and motion (opt-in TOTK_RUMBLE=1 / TOTK_GYRO=1): the game's hid side in runtime/hid_feedback.c, the
   Mac controller's haptics and motion sensors in runtime/gamepad_feedback.m. */
#define RUNTIME_MOTION_MAX 32
typedef struct { uint64_t sampling, delta_ns; float acc[3], gyro[3], angle[3], dir[9]; } RuntimeMotionState;   /* G, rev/s, rev, 3 axes */
int runtime_rumble_enabled(void);
int runtime_gyro_enabled(void);
void *runtime_hid_feedback_override(const char *name);
int runtime_hid_feedback_flag(const char *name, int v);   /* "flag rumble|gyro 0|1"; 0 = not one of these names */
void runtime_hid_feedback_stats(uint64_t *values, uint64_t *motion_reads);
void runtime_rumble_set(unsigned side, float amp_low, float freq_low, float amp_high, float freq_high);   /* side 0 left, 1 right */
int runtime_motion_read(RuntimeMotionState *out, int max);   /* newest first; 0 = no motion now */
void runtime_motion_start(void);   /* the game (re)started its sensor: angle and direction start over */
void runtime_motion_feed(const double acc_g[3], const double gyro_rad_s[3], uint64_t now_ns);   /* runtime/motion_fusion.c */
int runtime_motion_axes(const char *spec);   /* TOTK_GYRO_AXES ("-x,y,-z"): 1 set, 0 unset, -1 malformed */
void runtime_motion_deadzone_default(double deg_s);   /* when TOTK_GYRO_DEADZONE is unset: 1.2 for HID motion, else 0 */
void runtime_motion_live(int on);   /* a controller with motion attached (1) / detached (0) */
void runtime_motion_mouse(int on);
void runtime_motion_feed_mouse(const double acc_g[3], const double gyro_rad_s[3], uint64_t now_ns);
void runtime_feedback_quiet(void);   /* focus lost: stop rumbling */
#ifdef __OBJC__
@class GCController;
void runtime_feedback_attach(GCController *controller);
void runtime_feedback_detach(GCController *controller);
void runtime_feedback_set_slot(GCController *controller, int slot);
#endif

/* Main-queue settings lifecycle; keyboard_mac_key consumes configured AppKit input. */
void runtime_input_settings_suspend(int suspended);
int runtime_keyboard_mac_key(unsigned code, int down);
void runtime_keyboard_clear(void);
int runtime_input_settings_active(void);

#ifdef __OBJC__
@class NSArray, NSDictionary, NSString;
/* Main queue. Device IDs are opaque connection tokens, not persisted hardware IDs. */
NSArray *runtime_gamepad_devices(void);
NSString *runtime_gamepad_device_binding(int slot);
NSString *runtime_gamepad_device_label(int slot);
int runtime_gamepad_device_bind(int slot, NSString *identity);
#endif

/* macOS only, explicit opt-in; no permission request during normal startup. */
int runtime_keyboard_physical_enable(int enabled);
int runtime_keyboard_physical_enabled(void);
void runtime_keyboard_physical_focus(int focused);
#ifdef __OBJC__
NSString *runtime_keyboard_physical_status(void);
NSArray *runtime_keyboard_physical_devices(void);
NSString *runtime_keyboard_physical_binding(int slot);
NSString *runtime_keyboard_physical_label(int slot);
int runtime_keyboard_physical_bind(int slot, NSString *identity);
#endif

#include "input_source.h"
int runtime_input_source(int slot); /* lock-free, available to guest threads */
int runtime_input_source_allows(int slot, unsigned device);
int runtime_input_source_set(int slot, int source); /* main queue, persist before apply */
void runtime_mouse_refresh_source(void);
