// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#include "s2a_player_input_map.h"
@class GCController;
NS_ASSUME_NONNULL_BEGIN
// Preparation adapter, no production reader export. Main-thread ownership for
// creation/begin/publish/stop. Only readFrame may run on the HID thread.
// The caller must stop and join readers BEFORE releasing this object.
@interface S2AMacPlayerInput : NSObject
// Captures validated mappings and four-slot system/auto/disabled selections.
// No files, discovery, timers, handlers, keyboard/mouse or HID commands.
- (nullable instancetype)initWithConfig:(const s2a_input_config *)config;
- (instancetype)init NS_UNAVAILABLE;
// Fresh token required by every queued publication; old callbacks cannot change
// inventory, ownership or new-session data. Begin retires previous connections.
- (uint64_t)begin;
- (BOOL)publishControllers:(NSArray<GCController *> *)controllers token:(uint64_t)token
                   active:(BOOL)active nowUs:(uint64_t)now;
- (void)stop;
- (BOOL)readFrame:(s2a_player_input_frame *)frame capacity:(uint32_t)capacity nowUs:(uint64_t)now;
@end
NS_ASSUME_NONNULL_END
