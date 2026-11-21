// SPDX-License-Identifier: Apache-2.0
#pragma once
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/IOKitLib.h>
#include "registry.h"

static inline id s2a_driver_prop(IOHIDDeviceRef device, CFStringRef key) {
    return (__bridge id)IOHIDDeviceGetProperty(device, key);
}

// Only physical Bluetooth gamepads from the manager's joystick/gamepad match list.
static inline NSString *s2a_driver_key(IOHIDDeviceRef device) {
    NSString *transport = s2a_driver_prop(device, CFSTR(kIOHIDTransportKey));
    if (![transport.lowercaseString hasPrefix:@"bluetooth"] ||
        [s2a_driver_prop(device, CFSTR("GCSyntheticDevice")) boolValue]) return nil;
    NSString *serial = s2a_driver_prop(device, CFSTR(kIOHIDSerialNumberKey));
    NSNumber *location = s2a_driver_prop(device, CFSTR(kIOHIDLocationIDKey));
    NSString *unit;
    if ([serial isKindOfClass:NSString.class] && serial.length) unit = [@"serial-" stringByAppendingString:serial];
    else if (location.unsignedIntValue) unit = [NSString stringWithFormat:@"loc-%x", location.unsignedIntValue];
    else {
        uint64_t entry = 0;
        if (IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entry) != KERN_SUCCESS) return nil;
        unit = [NSString stringWithFormat:@"entry-%llu", entry];
    }
    return [NSString stringWithFormat:@"%@-%@-%@", s2a_driver_prop(device, CFSTR(kIOHIDVendorIDKey)),
            s2a_driver_prop(device, CFSTR(kIOHIDProductIDKey)), unit];
}

#define S2A_DRIVER_DOMAIN CFSTR("org.s2arm.bluetooth-pad-drivers")
static inline NSString *s2a_driver_choice(NSString *key) {
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, S2A_DRIVER_DOMAIN));
    return [value isKindOfClass:NSString.class] ? value : @"auto";
}
static inline const s2a_driver *s2a_device_driver(IOHIDDeviceRef device, NSString *key) {
    if (!key) return NULL;
    CFPreferencesAppSynchronize(S2A_DRIVER_DOMAIN);
    NSString *maker = s2a_driver_prop(device, CFSTR(kIOHIDManufacturerKey));
    NSString *name = s2a_driver_prop(device, CFSTR(kIOHIDProductKey));
    return s2a_driver_resolve(s2a_driver_choice(key).UTF8String, maker.UTF8String ?: "", name.UTF8String ?: "",
        [s2a_driver_prop(device, CFSTR(kIOHIDVendorIDKey)) intValue], [s2a_driver_prop(device, CFSTR(kIOHIDProductIDKey)) intValue]);
}
