// Adapter only: mapping, persistence, device ownership and sampling remain MNG.
#import <Foundation/Foundation.h>
#include "mng_adapter.h"
#include "mng/runtime.h"
#include "mng/input_source.h"
#include <fcntl.h>
#include <math.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
static _Atomic int prepared;
static _Atomic int controller_active = 1;
static int owner_fd = -1;
static char frozen_root[4096];

void s2a_mng_set_controller_active(int active) {
    atomic_store(&controller_active, !!active);
    if (!active && prepared) runtime_feedback_quiet();
}

// Legacy unassigned-keyboard fallback extracted from MNG runtime/input.c.
// The source file is retained verbatim in mng/input.c; guest nn::hid exports
// and game-specific automation/graphics shortcuts are not linked into S2Arm.
static pthread_mutex_t legacy_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned char legacy_keys[128];
static uint64_t legacy_pending;
static uint64_t legacy_button(unsigned code){switch(code){case 38:return 1;case 40:case 49:return 2;case 34:return 4;case 32:return 8;case 6:return 16;case 8:return 32;case 12:return 64;case 14:return 128;case 58:return 256;case 56:return 512;case 36:return 1024;case 48:case 53:return 2048;case 3:return 4096;case 17:return 8192;case 4:return 16384;case 5:return 32768;default:return 0;}}
void s2a_mng_input_keys_clear(void) {
    pthread_mutex_lock(&legacy_lock);
    memset(legacy_keys, 0, sizeof legacy_keys); legacy_pending = 0;
    pthread_mutex_unlock(&legacy_lock);
}
void s2a_mng_input_key(unsigned code, int down) {
    if (runtime_input_settings_active()) return;
    if (runtime_keyboard_mac_key(code, down)) return;
    // A saved inactive reservation must never fall back into player 1.
    if (runtime_keyboard_slot() >= 0 ||
        !runtime_input_source_allows(0, INPUT_DEVICE_KEYBOARD) || code >= 128) return;
    pthread_mutex_lock(&legacy_lock);
    if (down && !legacy_keys[code]) legacy_pending |= legacy_button(code);
    legacy_keys[code] = !!down;
    pthread_mutex_unlock(&legacy_lock);
}
static void legacy_merge(RuntimeGamepadState *out) {
    // Configuration lives on the main thread. The original settings callbacks
    // clear this fallback on transitions; the read path uses atomic source flags.
    if (!runtime_input_source_allows(0, INPUT_DEVICE_KEYBOARD) || runtime_input_settings_active()) return;
    pthread_mutex_lock(&legacy_lock);
    for (unsigned i = 0; i < 128; i++) if (legacy_keys[i]) out->buttons |= legacy_button(i);
    out->buttons |= legacy_pending; legacy_pending = 0;
    int32_t lx = 32767 * ((int)legacy_keys[2] - legacy_keys[0]);
    int32_t ly = 32767 * ((int)legacy_keys[13] - legacy_keys[1]);
    int32_t rx = 32767 * ((int)legacy_keys[124] - legacy_keys[123]);
    int32_t ry = 32767 * ((int)legacy_keys[126] - legacy_keys[125]);
    if (abs(lx) > abs(out->lx)) out->lx = lx;
    if (abs(ly) > abs(out->ly)) out->ly = ly;
    if (abs(rx) > abs(out->rx)) out->rx = rx;
    if (abs(ry) > abs(out->ry)) out->ry = ry;
    pthread_mutex_unlock(&legacy_lock);
}

int s2a_mng_input_prepare(const char *root) {
    if (!NSThread.isMainThread || prepared || !root || root[0] != '/' || strlen(root) >= sizeof frozen_root) return 0;
    // Caller creates the scoped directory. Require a canonical path and reject
    // a linked managed leaf. This is admission, not ancestor replacement protection.
    char canonical[4096];
    if (!realpath(root, canonical) || strcmp(root, canonical)) return 0;
    int fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) || st.st_uid != getuid() || (st.st_mode & 0022)) { close(fd); return 0; }
    close(fd);
    // Original kernel-held ownership primitive. Do not replace lock inodes.
    extern int s2a_mng_config_lock(const char *);
    int lock = s2a_mng_config_lock(root);
    if (lock < 0) return 0;
    // Original settings files must not redirect writes outside the scoped root.
    NSArray *leaves = @[@"controls.txt", @"controller-type.txt", @"mouse.txt", @"controller-slots.plist",
        @"controller-devices.plist", @"input-sources.plist", @"keyboard-slots.plist", @"physical-keyboards.plist", @"stick-bindings.plist"];
    for (NSString *leaf in leaves) {
        NSString *path = [@(root) stringByAppendingPathComponent:leaf];
        if (!lstat(path.fileSystemRepresentation, &st)) {
            if (!S_ISREG(st.st_mode) || st.st_nlink != 1) { close(lock); return 0; }
        } else if (errno != ENOENT) { close(lock); return 0; }
    }
    NSString *controls = [@(root) stringByAppendingPathComponent:@"controls.txt"];
    if (setenv("TOTK_CONTROLS", controls.fileSystemRepresentation, 1)) { close(lock); return 0; }
    strcpy(frozen_root, root); owner_fd = lock; prepared = 1;
    return 1;
}
void s2a_mng_input_start(void) {
    if (!NSThread.isMainThread || !prepared) runtime_fail("input session not prepared");
    runtime_gamepad_start();
}
int s2a_mng_input_read(s2a_player_input_frame *out, uint32_t capacity) {
    if (!prepared || !out || capacity < sizeof *out) return 0;
    int active = atomic_load(&controller_active);
    s2a_player_input_frame frame = {.version = S2A_PLAYER_INPUT_VERSION, .bytes = sizeof frame, .active = 1};
    for (unsigned s = 0; s < S2A_PLAYER_INPUT_COUNT; s++) {
        RuntimeGamepadState state;
        runtime_gamepad_read_index(s, &state);
        if (!s) legacy_merge(&state);
        if (!state.connected && !runtime_gamepad_connected(s)) continue;
        frame.connected_mask |= 1u << s;
        if (active) {
            frame.slots[s] = (s2a_player_input_slot){(uint32_t)state.buttons, state.lx, state.ly, state.rx, state.ry};
        }
    }
    *out = frame; return 1;
}

enum { MNG_RUMBLE_SESSION = 1 };
static _Atomic int mng_motion_enabled;
static pthread_mutex_t mng_motion_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t mng_last_sampling;
static uint64_t mng_last_timestamp_us;

static uint64_t mng_monotonic_us(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000ull + (uint64_t)t.tv_nsec / 1000ull;
}
static s2a_pad_vibration sanitize_vibration(s2a_pad_vibration v) {
    if (!isfinite(v.low_amp) || !isfinite(v.low_hz) || !isfinite(v.high_amp) || !isfinite(v.high_hz))
        return (s2a_pad_vibration){0, 160, 0, 320};
    return v;
}
uint64_t s2a_mng_pad_rumble_session(void) {
    return prepared && runtime_rumble_enabled() ? MNG_RUMBLE_SESSION : 0;
}
void s2a_mng_pad_set_player_rumble_pair(uint64_t session, unsigned player, const s2a_pad_vibration values[2]) {
    if (session != MNG_RUMBLE_SESSION || !values || player >= S2A_PLAYER_INPUT_COUNT || !s2a_mng_pad_rumble_session()) return;
    for (unsigned i = 0; i < 2; i++) {
        s2a_pad_vibration v = sanitize_vibration(values[i]);
        runtime_rumble_set(player * 2u + i, v.low_amp, v.low_hz, v.high_amp, v.high_hz);
    }
}
void s2a_mng_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]) {
    s2a_mng_pad_set_player_rumble_pair(session, 0, values);
}
void s2a_mng_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz) {
    if (session != MNG_RUMBLE_SESSION || side >= S2A_PLAYER_INPUT_COUNT * 2u || !s2a_mng_pad_rumble_session()) return;
    s2a_pad_vibration v = sanitize_vibration((s2a_pad_vibration){low_amp, low_hz, high_amp, high_hz});
    runtime_rumble_set(side, v.low_amp, v.low_hz, v.high_amp, v.high_hz);
}
void s2a_mng_pad_stop_rumble(uint64_t session) {
    if (session != MNG_RUMBLE_SESSION && session != 0) return;
    runtime_feedback_quiet();
}
void s2a_mng_pad_set_motion_enabled(int enabled) {
    int next = !!enabled;
    int prev = atomic_exchange(&mng_motion_enabled, next);
    if (next != prev) {
        pthread_mutex_lock(&mng_motion_lock);
        mng_last_sampling = 0; mng_last_timestamp_us = 0;
        pthread_mutex_unlock(&mng_motion_lock);
        if (next) runtime_motion_start();
    }
}
int s2a_mng_pad_read_motion(s2a_pad_motion *out) {
    if (!out) return 0;
    *out = (s2a_pad_motion){0};
    if (!prepared || !atomic_load(&mng_motion_enabled) || !runtime_gyro_enabled() || !runtime_input_motion_allowed(0)) return 0;
    RuntimeMotionState m = {0};
    if (runtime_motion_read(&m, 1) <= 0) return 0;
    uint64_t now = mng_monotonic_us();
    if (!now) now = 1;
    pthread_mutex_lock(&mng_motion_lock);
    if (m.sampling != mng_last_sampling || !mng_last_timestamp_us) {
        mng_last_sampling = m.sampling;
        mng_last_timestamp_us = now <= mng_last_timestamp_us ? mng_last_timestamp_us + 1 : now;
    }
    uint64_t ts = mng_last_timestamp_us;
    pthread_mutex_unlock(&mng_motion_lock);
    // MNG motion_fusion outputs acc in G (face up z = -1) and gyro in rev/s.
    // S2Arm MotionInput negates acc (`Accelerometer = -accel`) and expects gyro in deg/s.
    *out = (s2a_pad_motion){
        .host_timestamp_us = ts,
        .acceleration_x = -m.acc[0], .acceleration_y = -m.acc[1], .acceleration_z = -m.acc[2],
        .gyro_x = m.gyro[0] * 360.0f, .gyro_y = m.gyro[1] * 360.0f, .gyro_z = m.gyro[2] * 360.0f,
    };
    return 1;
}
