// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class GCExtendedGamepad;
typedef struct {
    uint64_t timestampUs;
    float acceleration[3], gyro[3];
} S2AControllerMotion;
GCExtendedGamepad * _Nullable s2a_active_system_pad(NSArray *controllers, NSString *selection);
// Read one explicitly owned pad; never selects a different controller. Main-thread only.
NSDictionary<NSString *, NSNumber *> *s2a_system_pad_values(GCExtendedGamepad * _Nullable pad);
// Main-thread confined. Never overwrites existing GameController handlers.
// Requested system motion installs an owned handler only when that handler is free.
// HID is opt-in, non-exclusive, and mutually exclusive with GC sampling.
@interface S2AControllerInput : NSObject
- (void)configureBackend:(NSString *)backend device:(NSString *)device;
- (void)stop;
// Main-thread only, just like snapshot. Disabled by default; UI monitors never
// enable the IMU. HID requires an acknowledged enable/fresh report; system
// motion requires a fresh sensor callback, never a timestamped cached poll.
@property(nonatomic) BOOL motionEnabled;
- (BOOL)readMotion:(S2AControllerMotion *)sample;
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *devices;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *snapshot;
@property(nonatomic, readonly) NSString *status;
@end
NS_ASSUME_NONNULL_END
