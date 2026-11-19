// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "player_input_sample.h"
#import "controllers/include/S2ASystemControllerSlots.h"
#include "s2a_player_input_buffer.h"
#include <string.h>
@implementation S2AMacPlayerInput {
    S2ASystemControllerSlots *_sampler;
    s2a_input_config _config;
    s2a_player_input_buffer _buffer;
    uint64_t _token;
    BOOL _initialized;
}
- (instancetype)initWithConfig:(const s2a_input_config *)config {
    NSAssert(NSThread.isMainThread, @"Player sampler requires main thread");
    if (!(self = [super init])) return nil;
    if (!s2a_player_mapping_valid(config) || config->players_present != 1) return nil;
    s2a_controller_selection selections[4] = {0};
    for (unsigned i = 0; i < 4; i++) {
        selections[i].backend = config->players[i].backend;
        memcpy(selections[i].device, config->players[i].device, sizeof selections[i].device);
    }
    _sampler = [S2ASystemControllerSlots new];
    if (![_sampler configure:selections] || !s2a_player_buffer_init(&_buffer)) return nil;
    _initialized = YES; _config = *config;
    return self;
}
- (uint64_t)begin {
    NSAssert(NSThread.isMainThread, @"Player sampler requires main thread");
    _token = s2a_player_buffer_begin(&_buffer);
    [_sampler stop];
    return _token;
}
- (BOOL)publishControllers:(NSArray<GCController *> *)controllers token:(uint64_t)token active:(BOOL)active nowUs:(uint64_t)now {
    NSAssert(NSThread.isMainThread, @"Player sampler requires main thread");
    if (!token || token != _token) return NO;
    if (!now) return s2a_player_buffer_publish(&_buffer, token, NULL, now);
    NSArray<NSDictionary *> *values = [_sampler sampleControllers:controllers active:active];
    s2a_player_input_frame frame = {.version=S2A_PLAYER_INPUT_VERSION, .bytes=sizeof frame,
                                  .connected_mask=_sampler.connectedMask, .active=active ? 1u : 0u};
    if (active) for (unsigned i = 0; i < 4; i++) {
        if (!(frame.connected_mask & (1u << i))) continue;
        s2a_player_raw_input raw = {0};
        for (int b = 0; b < 16; b++) if ([values[i][@(s2a_input_pad_name(b))] boolValue]) raw.buttons |= 1u << b;
        for (int a = 0; a < 4; a++) raw.axes[a] = [values[i][@(s2a_input_axis_name(a))] floatValue];
        if (!s2a_player_map(&_config, &raw, &frame.slots[i]))
            return s2a_player_buffer_publish(&_buffer, token, NULL, now);
    }
    return s2a_player_buffer_publish(&_buffer, token, &frame, now);
}
- (void)stop {
    NSAssert(NSThread.isMainThread, @"Player sampler requires main thread");
    s2a_player_buffer_stop(&_buffer); _token = 0;
    [_sampler stop];
}
- (BOOL)readFrame:(s2a_player_input_frame *)frame capacity:(uint32_t)capacity nowUs:(uint64_t)now {
    return s2a_player_buffer_read(&_buffer, frame, capacity, now);
}
- (void)dealloc {
    // Owner must have joined readers; no delayed blocks or native pointers retained.
    if (_initialized) { s2a_player_buffer_stop(&_buffer); s2a_player_buffer_destroy(&_buffer); }
}
@end
