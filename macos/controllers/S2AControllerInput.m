// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "include/S2AControllerInput.h"
#import "include/s2a_nspro.h"
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/IOKitLib.h>
#include <time.h>
#include <pthread.h>
#include <math.h>
#include <float.h>
static double inputTime(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

// Callback-owned mailbox: a detached callback retains only this closed mailbox,
// never the sampler or a new connection. No AppKit/main-queue waits in callbacks.
@interface S2ASystemMotionMailbox : NSObject {
    pthread_mutex_t _lock;
    BOOL _closed;
    S2AControllerMotion _sample;
}
- (void)receive:(GCMotion *)motion;
- (BOOL)read:(S2AControllerMotion *)sample;
- (void)close;
@end
@implementation S2ASystemMotionMailbox
- (instancetype)init { if ((self = [super init])) pthread_mutex_init(&_lock, NULL); return self; }
- (void)receive:(GCMotion *)motion {
    GCAcceleration a = motion.acceleration;
    GCRotationRate g = motion.rotationRate;
    double values[] = {-a.x, -a.y, -a.z, g.x * (180.0 / M_PI), g.y * (180.0 / M_PI), g.z * (180.0 / M_PI)};
    S2AControllerMotion sample = {0};
    BOOL valid = motion.hasRotationRate;
    for (unsigned i = 0; i < 6; i++) if (!isfinite(values[i]) || fabs(values[i]) > FLT_MAX) valid = NO;
    if (valid) {
        sample.timestampUs = (uint64_t)(inputTime() * 1000000);
        for (unsigned i = 0; i < 3; i++) { sample.acceleration[i] = (float)values[i]; sample.gyro[i] = (float)values[i+3]; }
    }
    pthread_mutex_lock(&_lock);
    if (!_closed) _sample = sample;
    pthread_mutex_unlock(&_lock);
}
- (BOOL)read:(S2AControllerMotion *)sample {
    pthread_mutex_lock(&_lock);
    uint64_t now = (uint64_t)(inputTime() * 1000000);
    BOOL valid = !_closed && _sample.timestampUs && now >= _sample.timestampUs && now - _sample.timestampUs <= 250000;
    *sample = valid ? _sample : (S2AControllerMotion){0};
    pthread_mutex_unlock(&_lock);
    return valid;
}
- (void)close { pthread_mutex_lock(&_lock); _closed = YES; _sample = (S2AControllerMotion){0}; pthread_mutex_unlock(&_lock); }
- (void)dealloc { pthread_mutex_destroy(&_lock); }
@end

static NSArray<NSString *> *buttonNames(void) {
    return @[@"east",@"south",@"north",@"west",@"leftStick",@"rightStick",@"leftShoulder",@"rightShoulder",
             @"leftTrigger",@"rightTrigger",@"menu",@"options",@"dpadLeft",@"dpadUp",@"dpadRight",@"dpadDown"];
}
static NSString *gcID(GCController *c) {
    // GC exposes no stable hardware identifier. Do not silently choose among identical models.
    return [NSString stringWithFormat:@"gc:%@:%@", c.productCategory ?: @"", c.vendorName ?: @""];
}
GCExtendedGamepad *s2a_active_system_pad(NSArray *controllers, NSString *selection) {
    GCExtendedGamepad *pad = nil; unsigned matches = 0;
    for (GCController *c in controllers) {
        if (!c.extendedGamepad || (selection.length && ![selection isEqual:gcID(c)])) continue;
        matches++;
        if (!pad || c.extendedGamepad.lastEventTimestamp > pad.lastEventTimestamp) pad = c.extendedGamepad;
    }
    return selection.length && matches != 1 ? nil : pad;
}
NSDictionary<NSString *, NSNumber *> *s2a_system_pad_values(GCExtendedGamepad *pad) {
    if (!pad) return @{};
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    BOOL labelled = NO;
    for (NSString *name in @[pad.controller.productCategory ?: @"", pad.controller.vendorName ?: @""])
        for (NSString *token in @[@"switch pro", @"pro controller", @"joy-con", @"joycon"])
            if ([name rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) labelled = YES;
    NSArray *buttons = @[labelled ? pad.buttonA : pad.buttonB, labelled ? pad.buttonB : pad.buttonA,
        labelled ? pad.buttonX : pad.buttonY, labelled ? pad.buttonY : pad.buttonX,
        pad.leftThumbstickButton ?: NSNull.null, pad.rightThumbstickButton ?: NSNull.null,
        pad.leftShoulder, pad.rightShoulder, pad.leftTrigger, pad.rightTrigger, pad.buttonMenu,
        pad.buttonOptions ?: NSNull.null, pad.dpad.left, pad.dpad.up, pad.dpad.right, pad.dpad.down];
    NSArray *names = buttonNames();
    for (unsigned i = 0; i < 16; i++) values[names[i]] = @([buttons[i] isKindOfClass:GCControllerButtonInput.class] && [buttons[i] isPressed]);
    values[@"leftX"] = @(pad.leftThumbstick.xAxis.value); values[@"leftY"] = @(pad.leftThumbstick.yAxis.value);
    values[@"rightX"] = @(pad.rightThumbstick.xAxis.value); values[@"rightY"] = @(pad.rightThumbstick.yAxis.value);
    return values;
}
static NSString *hidID(IOHIDDeviceRef device) {
    uint64_t entry = 0;
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entry);
    return [NSString stringWithFormat:@"hid:%llu", (unsigned long long)entry];
}
@interface S2AControllerInput () {
    IOHIDManagerRef _manager;
    IOHIDDeviceRef _device;
    uint8_t _report[64];
    s2a_nspro_state _state;
    CFTimeInterval _lastReport;
    NSString *_backend, *_selection, *_status, *_failedDevice;
    BOOL _motionEnabled, _imuEnabled, _imuPending, _imuAttempted;
    uint8_t _packetNumber;
    CFTimeInterval _lastCommand;
    S2AControllerMotion _motion;
    GCMotion *_systemMotion;
    S2ASystemMotionMailbox *_systemMailbox;
    GCMotionValueChangedHandler _systemHandler;
    BOOL _activatedSystemSensors;
}
- (void)detach;
- (void)detachSystemMotion;
- (void)updateSystemMotion:(GCMotion *)motion;
- (void)receive:(uint8_t *)report size:(CFIndex)size;
- (IOReturn)sendSubcommand:(uint8_t)command value:(uint8_t)value;
- (void)updateMotionRequest;
- (void)removedDevice:(IOHIDDeviceRef)device;
@end
static void removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    S2AControllerInput *input = (__bridge S2AControllerInput *)context;
    // Re-evaluate selection after removal; callback runs on the main run loop.
    (void)result; (void)sender; (void)device;
    [input removedDevice:device];
}
static void reportReceived(void *context, IOReturn result, void *sender, IOHIDReportType type,
                           uint32_t reportID, uint8_t *report, CFIndex size) {
    (void)sender;
    if (result == kIOReturnSuccess && type == kIOHIDReportTypeInput && (reportID == 0x30 || reportID == 0x21))
        [(__bridge S2AControllerInput *)context receive:report size:size];
}
@implementation S2AControllerInput
- (instancetype)init {
    if ((self = [super init])) { _backend = @"system"; _selection = @""; _status = @""; }
    return self;
}
- (void)configureBackend:(NSString *)backend device:(NSString *)device {
    if ([_backend isEqual:backend] && [_selection isEqual:device] && (![backend isEqual:@"nspro-hid"] || _manager)) return;
    [self stop]; _failedDevice = nil; _backend = [backend copy]; _selection = [device copy];
    if ([_backend isEqual:@"nspro-hid"]) {
        _manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        IOHIDManagerSetDeviceMatching(_manager, (__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey:@0x057e, @kIOHIDProductIDKey:@0x2009});
        IOHIDManagerRegisterDeviceRemovalCallback(_manager, removed, (__bridge void *)self);
        IOHIDManagerScheduleWithRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOReturn result = IOHIDManagerOpen(_manager, kIOHIDOptionsTypeNone);
        if (result != kIOReturnSuccess) {
            [self stop]; _status = [NSString stringWithFormat:@"HID open failed (0x%x)", result];
        }
    }
}
- (void)removedDevice:(IOHIDDeviceRef)device { if (_device == device) [self detach]; }
- (void)detach {
    if (_device) {
        if (_imuEnabled || _imuPending) [self sendSubcommand:0x40 value:0];
        IOHIDDeviceRegisterInputReportCallback(_device, _report, sizeof _report, NULL, NULL);
        IOHIDDeviceClose(_device, kIOHIDOptionsTypeNone);
        CFRelease(_device); _device = NULL;
    }
    memset(&_state, 0, sizeof _state); _lastReport = 0;
    _motion = (S2AControllerMotion){0};
    _imuEnabled = _imuPending = _imuAttempted = NO;
    _lastCommand = 0; _packetNumber = 0;
}
- (void)stop {
    [self detachSystemMotion];
    [self detach]; _failedDevice = nil;
    if (_manager) {
        IOHIDManagerUnscheduleFromRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDManagerClose(_manager, kIOHIDOptionsTypeNone); CFRelease(_manager); _manager = NULL;
    }
}
- (void)dealloc { [self stop]; }
- (IOReturn)sendSubcommand:(uint8_t)command value:(uint8_t)value {
    uint8_t bytes[49] = {1,0,0,1,0x40,0x40,0,1,0x40,0x40};
    bytes[1] = _packetNumber++ & 15; bytes[10] = command; bytes[11] = value;
    _lastCommand = inputTime();
    return IOHIDDeviceSetReport(_device, kIOHIDReportTypeOutput, 1, bytes, sizeof bytes);
}
- (BOOL)motionEnabled { return _motionEnabled; }
- (void)setMotionEnabled:(BOOL)enabled {
    if (_motionEnabled == enabled) { [self updateMotionRequest]; return; }
    _motionEnabled = enabled;
    if (!enabled) [self detachSystemMotion];
    _motion = (S2AControllerMotion){0};
    // Finish any outstanding command before changing intent: the ACK has no
    // transaction ID. Otherwise a late enable ACK could admit an old sample.
    _imuAttempted = NO;
    [self updateMotionRequest];
}
- (void)updateMotionRequest {
    if (!_device || inputTime() - _lastCommand < 0.05) return;
    if (_imuPending) {
        if (inputTime() - _lastCommand > 0.5) _status = @"NS Pro IMU acknowledgement missing; reconnect to retry";
        return; // Do not guess whether a timed-out command took effect.
    }
    if (_imuEnabled == _motionEnabled || _imuAttempted) return;
    _imuAttempted = YES;
    IOReturn result = [self sendSubcommand:0x40 value:_motionEnabled ? 1 : 0];
    _imuPending = result == kIOReturnSuccess;
    if (!_imuPending) _status = [NSString stringWithFormat:@"NS Pro IMU request failed (0x%x)", result];
}
- (void)receive:(uint8_t *)report size:(CFIndex)size {
    if (!report || size < 0) return;
    if (size >= 15 && report[0] == 0x21 && report[14] == 0x40 && _imuPending) {
        _imuPending = NO;
        if (report[13] & 0x80) {
            _imuEnabled = !_imuEnabled; // Only one transition can be in flight.
            _imuAttempted = NO;
        } else { _status = @"NS Pro IMU request rejected"; }
        _motion = (S2AControllerMotion){0};
        return;
    }
    if (s2a_nspro_decode(report, (size_t)size, &_state)) {
        _lastReport = inputTime();
        s2a_nspro_motion decoded;
        if (_motionEnabled && _imuEnabled && !_imuPending && s2a_nspro_decode_motion(report, (size_t)size, &decoded)) {
            _motion.timestampUs = (uint64_t)(_lastReport * 1000000);
            memcpy(_motion.acceleration, decoded.acceleration, sizeof decoded.acceleration);
            memcpy(_motion.gyro, decoded.gyro, sizeof decoded.gyro);
        }
    }
}
- (void)detachSystemMotion {
    [_systemMailbox close];
    // Do not remove another owner's handler if it changed after our attachment.
    if (_systemMotion.valueChangedHandler == _systemHandler && _systemHandler) {
        _systemMotion.valueChangedHandler = nil;
        if (_activatedSystemSensors) _systemMotion.sensorsActive = NO;
    }
    _systemMotion = nil; _systemMailbox = nil; _systemHandler = nil;
    _activatedSystemSensors = NO;
}
- (void)updateSystemMotion:(GCMotion *)motion {
    if (!_motionEnabled) { [self detachSystemMotion]; return; }
    if (motion == _systemMotion && _systemHandler && motion.valueChangedHandler == _systemHandler) return;
    [self detachSystemMotion];
    if (!motion || !motion.hasRotationRate) { _status = @"Selected system controller does not expose a gyroscope"; return; }
    if (motion.valueChangedHandler) { _status = @"System controller motion is owned by another reader"; return; }
    _systemMotion = motion;
    S2ASystemMotionMailbox *mailbox = [S2ASystemMotionMailbox new];
    _systemMailbox = mailbox;
    _systemHandler = ^(GCMotion *updated) { [mailbox receive:updated]; };
    motion.valueChangedHandler = _systemHandler;
    _activatedSystemSensors = motion.sensorsRequireManualActivation && !motion.sensorsActive;
    if (_activatedSystemSensors) motion.sensorsActive = YES;
    // Never timestamp cached property values as a fresh sensor sample.
    _status = @"Waiting for system controller motion";
}
- (BOOL)readMotion:(S2AControllerMotion *)sample {
    if (!sample) return NO;
    *sample = (S2AControllerMotion){0};
    if (_systemMailbox) {
        if (!_motionEnabled || _systemMotion.valueChangedHandler != _systemHandler) { [self detachSystemMotion]; return NO; }
        return [_systemMailbox read:sample];
    }
    if (!_motionEnabled || !_imuEnabled || _imuPending || !_motion.timestampUs ||
        inputTime() * 1000000 - _motion.timestampUs > 250000) return NO;
    *sample = _motion;
    return YES;
}
- (NSArray<NSDictionary<NSString *, NSString *> *> *)devices {
    NSMutableArray *list = [NSMutableArray array];
    if ([_backend isEqual:@"system"]) {
        NSMutableSet *seen = [NSMutableSet set];
        for (GCController *c in GCController.controllers) if (c.extendedGamepad && ![seen containsObject:gcID(c)]) {
            [seen addObject:gcID(c)];
            [list addObject:@{@"id":gcID(c), @"name":c.vendorName ?: c.productCategory ?: @"GameController"}];
        }
    } else if (_manager) {
        NSSet *set = CFBridgingRelease(IOHIDManagerCopyDevices(_manager));
        for (id obj in set) {
            IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)obj;
            NSString *name = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
            [list addObject:@{@"id":hidID(device), @"name":name ?: @"NS Pro HID"}];
        }
    }
    return [list sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"id"] compare:b[@"id"]]; }];
}
- (NSDictionary<NSString *, NSNumber *> *)snapshot {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    if ([_backend isEqual:@"nspro-hid"]) {
        if (!_manager) return values;
        NSSet *set = CFBridgingRelease(IOHIDManagerCopyDevices(_manager));
        IOHIDDeviceRef chosen = NULL; unsigned matches = 0;
        for (id obj in set) {
            IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)obj;
            if (!_selection.length || [_selection isEqual:hidID(d)]) { chosen = d; matches++; }
        }
        if (matches != 1) { [self detach]; _failedDevice = nil; _status = matches ? @"Select one NS Pro HID device" : @"Selected HID device disconnected"; return values; }
        if (_device != chosen) {
            if ([_failedDevice isEqual:hidID(chosen)]) return values;
            [self detach];
            IOReturn result = IOHIDDeviceOpen(chosen, kIOHIDOptionsTypeNone);
            if (result != kIOReturnSuccess) { _failedDevice = hidID(chosen); _status = [NSString stringWithFormat:@"HID device open failed (0x%x); reconnect or change driver to retry", result]; return values; }
            _device = (IOHIDDeviceRef)CFRetain(chosen);
            IOHIDDeviceRegisterInputReportCallback(_device, _report, sizeof _report, reportReceived, (__bridge void *)self);
            // Switch subcommand 03: request full 0x30 reports; neutral rumble bytes.
            result = [self sendSubcommand:3 value:0x30];
            _status = result == kIOReturnSuccess ? @"Waiting for NS Pro report 0x30" : [NSString stringWithFormat:@"HID report-mode request failed (0x%x)", result];
        }
        [self updateMotionRequest];
        // Full reports are periodic; a silent/broken link must not latch held controls.
        if (!_lastReport || inputTime() - _lastReport > 0.5) {
            if (_lastReport) _status = @"NS Pro reports stopped";
            return values;
        }
        if (!_motionEnabled) _status = @"NS Pro HID · report 0x30";
        else if (_imuEnabled && !_imuPending) _status = @"NS Pro HID · IMU enabled";
        NSArray *names = buttonNames();
        for (unsigned i = 0; i < 16; i++) values[names[i]] = @((_state.buttons >> i) & 1);
        NSArray *axes = @[@"leftX", @"leftY", @"rightX", @"rightY"];
        for (unsigned i = 0; i < 4; i++) values[axes[i]] = @(_state.axes[i]);
    } else if ([_backend isEqual:@"system"]) {
        GCExtendedGamepad *pad = s2a_active_system_pad(GCController.controllers, _selection);
        if (!pad) { [self detachSystemMotion]; _status = @"No unique selected system controller"; return values; }
        [values addEntriesFromDictionary:s2a_system_pad_values(pad)];
        _status = pad.controller.vendorName ?: @"GameController";
        [self updateSystemMotion:pad.controller.motion];
    } else { _status = @"Controller input disabled"; }
    return values;
}
- (NSString *)status { return _status; }
@end
