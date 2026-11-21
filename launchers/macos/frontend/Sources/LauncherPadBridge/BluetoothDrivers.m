// SPDX-License-Identifier: Apache-2.0
#import "LauncherPadBridge.h"
#import "../../../../../macos/pad_drivers/device.h"

@implementation S2ABluetoothDrivers
+ (NSArray<NSString *> *)identifiers {
    NSMutableArray *ids = [NSMutableArray array];
    for (size_t i = 0; i < S2A_DRIVER_COUNT; ++i) [ids addObject:@(s2a_drivers[i].id)];
    return ids;
}
+ (NSString *)keyForDevice:(IOHIDDeviceRef)device { return s2a_driver_key(device); }
+ (NSString *)choiceForKey:(NSString *)key { return s2a_driver_choice(key); }
+ (NSString *)resolvedForDevice:(IOHIDDeviceRef)device {
    const s2a_driver *driver = s2a_device_driver(device, s2a_driver_key(device));
    return driver ? @(driver->id) : nil;
}
+ (BOOL)saveChoice:(NSString *)choice forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, [choice isEqual:@"auto"] ? NULL : (__bridge CFStringRef)choice, S2A_DRIVER_DOMAIN);
    return CFPreferencesAppSynchronize(S2A_DRIVER_DOMAIN);
}
@end
