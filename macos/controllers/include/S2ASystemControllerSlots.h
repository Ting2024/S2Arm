// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#import "s2a_controller_slots.h"
@class GCController;
NS_ASSUME_NONNULL_BEGIN
// System-only preparation layer, not a production four-player capability.
// Main-thread confined. Inject the current inventory; this object never discovers
// hardware, installs handlers, changes playerIndex or opens HID devices.
@interface S2ASystemControllerSlots : NSObject
// Defaults to four AUTO/empty slots. NSPRO is rejected, not silently substituted.
// Invalid configuration leaves current configuration/ownership untouched.
- (BOOL)configure:(const s2a_controller_selection * _Nullable)selections;
// Caller may pass GCController.controllers in production. Tests pass snapshots.
// Each result is raw named controls, BEFORE user mapping/deadzone. Inactive slots
// return empty dictionaries while retaining topology. No keyboard/mouse mixing.
- (NSArray<NSDictionary<NSString *, NSNumber *> *> *)sampleControllers:(NSArray<GCController *> *)controllers
                                                               active:(BOOL)active;
@property(nonatomic, readonly) uint32_t connectedMask;
// IDs are opaque connection tokens, NOT persistent hardware identities. Two
// identical models have different IDs. Disconnect/stop retires tokens; never
// persist them in user configuration or infer system/HID aliases from them.
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *devices;
@property(nonatomic, readonly) NSArray<NSString *> *assignedDevices;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
