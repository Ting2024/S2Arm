// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#include "input_config.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include <math.h>
static pthread_mutex_t config_mu = PTHREAD_MUTEX_INITIALIZER;
static s2a_input_config current_config;
static int current_valid;
static NSString *preference_key;
int s2a_ios_input_config_read(const char *path, s2a_input_config *out) {
    if (!out) return S2A_INPUT_CONFIG_JSON;
    if (!path) { s2a_input_config_default(out); return S2A_INPUT_CONFIG_OK; }
    @try {
        NSString *name = [[NSString alloc] initWithUTF8String:path];
        if (!name) return S2A_INPUT_CONFIG_IO;
        if (!name.isAbsolutePath) {
            char docs[1024]; s2a_docs_root(docs, sizeof docs);
            NSString *root = [[NSString alloc] initWithUTF8String:docs];
            if (!root) return S2A_INPUT_CONFIG_IO;
            name = [root stringByAppendingPathComponent:name];
        }
        NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:name];
        if (!file) return S2A_INPUT_CONFIG_IO;
        NSData *data = [file readDataUpToLength:S2A_INPUT_CONFIG_MAX_BYTES + 1 error:NULL]; [file closeFile];
        if (!data) return S2A_INPUT_CONFIG_IO;
        s2a_input_config next;
        int error = s2a_input_config_parse(data.bytes, data.length, &next);
        if (error) return error;
#if !TARGET_OS_IPHONE
        if (next.players_present) return S2A_INPUT_CONFIG_PLAYERS_UNSUPPORTED;
#endif
        *out = next;
        return S2A_INPUT_CONFIG_OK;
    } @catch (NSException *exception) { (void)exception; return S2A_INPUT_CONFIG_IO; }
}
static NSString *current_game_id(void) {
    const char *game = getenv("S2A_LAUNCH_GAME_ID");
    if (!game || !*game) game = getenv("S2A_GAME_ID");
    if (!game || strlen(game) != 16) return nil;
    for (int i = 0; i < 16; i++) if (!strchr("0123456789abcdefABCDEF", game[i])) return nil;
    return @(game).uppercaseString;
}
static int backend_from_source_string(NSString *src, int fallback) {
    if ([src isEqualToString:@"system"]) return 0;
    if ([src isEqualToString:@"nspro-hid"]) return 1;
    if ([src isEqualToString:@"disabled"]) return 2;
    if ([src isEqualToString:@"auto"]) return 3;
    if ([src isEqualToString:@"touch"]) return 4;
    if ([src isEqualToString:@"keyboard"]) return 5;
    return fallback;
}
static NSString *source_string_from_backend(int backend) {
    switch (backend) {
        case 0: return @"system";
        case 1: return @"nspro-hid";
        case 2: return @"disabled";
        case 4: return @"touch";
        case 5: return @"keyboard";
        default: return @"auto";
    }
}
static void sync_player_sources_from_defaults(NSUserDefaults *defaults, s2a_input_config *cfg) {
    NSString *gid = (defaults == NSUserDefaults.standardUserDefaults) ? current_game_id() : nil;
    NSUserDefaults *gameSuite = gid ? [[NSUserDefaults alloc] initWithSuiteName:[@"S2AGame." stringByAppendingString:gid]] : nil;
    BOOL any = NO;
    for (int p = 0; p < S2A_INPUT_PLAYER_COUNT; p++) {
        NSString *k = [NSString stringWithFormat:@"S2Arm.PlayerSource.%d", p + 1];
        NSString *src = [gameSuite stringForKey:k] ?: [defaults stringForKey:k];
        if (src.length) {
            any = YES;
            int prev = cfg->players_present ? cfg->players[p].backend : (p == 0 ? cfg->controller_backend : 3);
            int next = backend_from_source_string(src, prev);
            cfg->players[p].backend = next;
            if (next != 0 && next != 3) cfg->players[p].device[0] = 0;
        } else if (!cfg->players_present) {
            cfg->players[p].backend = (p == 0 ? cfg->controller_backend : 3);
            cfg->players[p].device[0] = 0;
        }
    }
    if (any || !cfg->players_present) cfg->players_present = 1;
}
static void persist_player_sources_to_defaults(NSUserDefaults *defaults, const s2a_input_config *cfg) {
    if (!cfg->players_present || defaults != NSUserDefaults.standardUserDefaults) return;
    NSString *gid = current_game_id();
    NSUserDefaults *gameSuite = gid ? [[NSUserDefaults alloc] initWithSuiteName:[@"S2AGame." stringByAppendingString:gid]] : nil;
    for (int p = 0; p < S2A_INPUT_PLAYER_COUNT; p++) {
        NSString *k = [NSString stringWithFormat:@"S2Arm.PlayerSource.%d", p + 1];
        NSString *val = source_string_from_backend(cfg->players[p].backend);
        [defaults setObject:val forKey:k];
        if (gameSuite) [gameSuite setObject:val forKey:k];
    }
}
static NSString *session_preference_key(void) {
    const char *root = getenv("S2A_RYU_DATA");
    NSString *gid = current_game_id();
    if (!root || root[0] != '/' || !gid) return nil;
    NSString *state = [[NSString alloc] initWithUTF8String:root];
    if (!state) return nil;
    // Root is frozen by native launch admission. Distinct users/games never
    // share this key; no registry names, mutable selection or global default.
    return [NSString stringWithFormat:@"S2Arm.Input.v1.%@.%@", gid, state];
}
int s2a_ios_input_config_load(void) {
    return s2a_ios_input_config_load_preferences(NSUserDefaults.standardUserDefaults);
}
int s2a_ios_input_config_load_preferences(NSUserDefaults *defaults) {
    s2a_input_config next;
    NSString *key = session_preference_key();
    id saved = key ? [defaults objectForKey:key] : nil;
    int error;
    if (saved) {
        error = [saved isKindOfClass:NSData.class] ? s2a_input_config_parse([saved bytes], [saved length], &next) : S2A_INPUT_CONFIG_JSON;
        if (!error) sync_player_sources_from_defaults(defaults, &next);
    } else {
        error = s2a_ios_input_config_read(getenv("S2A_INPUT_CONFIG"), &next);
        if (!error) sync_player_sources_from_defaults(defaults, &next);
    }
    if (error) s2a_input_config_default(&next);   // 读不懂（11-17 维护者：校验不过不再拒启）：这局用默认键位，调用方黄字说明
    pthread_mutex_lock(&config_mu);
    current_config = next;
    current_valid = 1;
    preference_key = !error ? key : nil;
    s2a_pad_session_reset();
    pthread_mutex_unlock(&config_mu);
    return error;
}
const s2a_input_config *s2a_ios_input_config_current(void) {
    static _Thread_local s2a_input_config copy;
    pthread_mutex_lock(&config_mu);
    int valid = current_valid;
    if (valid) copy = current_config;
    pthread_mutex_unlock(&config_mu);
    return valid ? &copy : NULL;
}
int s2a_ios_input_config_apply(const char *json, size_t bytes) {
    s2a_input_config next;
    int error = s2a_input_config_parse(json, bytes, &next);
    if (error) return error;
    pthread_mutex_lock(&config_mu);
    current_config = next; current_valid = 1;
    // Drop short-press latches and advance the epoch before exposing the new
    // table. Samplers publish canonical physical state, never a stale mapping.
    s2a_pad_session_reset();
    pthread_mutex_unlock(&config_mu);
    return S2A_INPUT_CONFIG_OK;
}
int s2a_ios_input_config_can_save(void) {
    pthread_mutex_lock(&config_mu);
    int available = current_valid && preference_key != nil;
    pthread_mutex_unlock(&config_mu);
    return available;
}
int s2a_ios_input_config_apply_saved(const char *json, size_t bytes, NSUserDefaults *defaults) {
    // UI-only persistence. HID threads never touch preferences or file I/O.
    if (!NSThread.isMainThread || !defaults) return S2A_INPUT_CONFIG_IO;
    s2a_input_config next;
    int error = s2a_input_config_parse(json, bytes, &next);
    if (error) return error;
    pthread_mutex_lock(&config_mu);
    if (!current_valid || !preference_key) { pthread_mutex_unlock(&config_mu); return S2A_INPUT_CONFIG_IO; }
    id previous = nil;
    BOOL attempted = NO;
    @try {
        NSData *data = [NSData dataWithBytes:json length:bytes];
        previous = [defaults objectForKey:preference_key];
        attempted = YES;
        [defaults setObject:data forKey:preference_key];
        if (![defaults synchronize]) error = S2A_INPUT_CONFIG_IO;
        else {
            current_config = next;
            persist_player_sources_to_defaults(defaults, &next);
            s2a_pad_session_reset();
        }
    } @catch (NSException *exception) {
        (void)exception; error = S2A_INPUT_CONFIG_IO;
    } @finally {
        if (error && attempted) {
            @try {
                if (previous) [defaults setObject:previous forKey:preference_key];
                else [defaults removeObjectForKey:preference_key];
                [defaults synchronize];
            } @catch (NSException *exception) { (void)exception; }
        }
        pthread_mutex_unlock(&config_mu);
    }
    return error;
}

static void map_physical_locked(const s2a_input_config *c, uint32_t raw, const int32_t raw_axes[4], uint32_t *out_buttons, int32_t out_axes[4]) {
    uint32_t buttons = 0;
    int32_t axes[4] = {0};
    for (int i = 0; i < S2A_INPUT_TARGET_COUNT; i++) {
        int source = c->gamepad[i];
        if (source < 0 || source >= 16 || !(raw & (1u << source))) continue;
        if (i < 16) buttons |= 1u << i;
        else {
            int direction = (i - 16) % 4, stick = (i - 16) / 4;
            axes[stick * 2 + (direction % 2)] += direction < 2 ?
                (direction == 0 ? -32767 : 32767) : (direction == 2 ? 32767 : -32767);
        }
    }
    for (int i = 0; i < 4; i++) {
        int source = c->axes[i].source;
        if (raw_axes && source >= 0 && source < 4) {
            int32_t v = raw_axes[source];
            v = v < -32767 ? -32767 : v > 32767 ? 32767 : v;
            if (fabs((double)v) > c->deadzone * 32767) axes[i] += c->axes[i].invert ? -v : v;
        }
        axes[i] = axes[i] < -32767 ? -32767 : axes[i] > 32767 ? 32767 : axes[i];
    }
    if (out_buttons) *out_buttons = buttons;
    if (out_axes) memcpy(out_axes, axes, sizeof axes);
}

void s2a_ios_input_map_physical(uint32_t raw_buttons, const int32_t raw_axes[4], uint32_t *out_buttons, int32_t out_axes[4]) {
    pthread_mutex_lock(&config_mu);
    if (current_valid) {
        map_physical_locked(&current_config, raw_buttons, raw_axes, out_buttons, out_axes);
    } else {
        if (out_buttons) *out_buttons = raw_buttons;
        if (out_axes) {
            if (raw_axes) memcpy(out_axes, raw_axes, 4 * sizeof(int32_t));
            else memset(out_axes, 0, 4 * sizeof(int32_t));
        }
    }
    pthread_mutex_unlock(&config_mu);
}

void s2a_ios_input_map_keyboard(const uint8_t mac_keys[128], unsigned modifiers, uint32_t *out_buttons, int32_t out_axes[4]) {
    uint32_t buttons = 0;
    int32_t axes[4] = {0};
    if (mac_keys) {
        pthread_mutex_lock(&config_mu);
        if (current_valid) {
            const s2a_input_config *c = &current_config;
            for (int i = 0; i < S2A_INPUT_TARGET_COUNT; i++) {
                int code = c->keyboard[i].code;
                unsigned req_mod = c->keyboard[i].modifiers;
                if (code < 0 || code >= 128 || !mac_keys[code]) continue;
                if (req_mod && (modifiers & req_mod) != req_mod) continue;
                if (i < 16) buttons |= 1u << i;
                else {
                    int direction = (i - 16) % 4, stick = (i - 16) / 4;
                    axes[stick * 2 + (direction % 2)] += direction < 2 ?
                        (direction == 0 ? -32767 : 32767) : (direction == 2 ? 32767 : -32767);
                }
            }
            for (int i = 0; i < 4; i++) {
                axes[i] = axes[i] < -32767 ? -32767 : axes[i] > 32767 ? 32767 : axes[i];
            }
        }
        pthread_mutex_unlock(&config_mu);
    }
    if (out_buttons) *out_buttons = buttons;
    if (out_axes) memcpy(out_axes, axes, sizeof axes);
}

void s2a_ios_input_read(s2a_pad_snapshot *out) {
    if (!out) return;
    pthread_mutex_lock(&config_mu);
    s2a_pad_read_ex(out);
    if (current_valid && out->source != S2A_PAD_TOUCH) {
        uint32_t buttons = 0;
        int32_t axes[4] = {0};
        map_physical_locked(&current_config, out->buttons, out->axes, &buttons, axes);
        out->buttons = buttons; memcpy(out->axes, axes, sizeof axes);
    }
    pthread_mutex_unlock(&config_mu);
}
