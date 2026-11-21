// SPDX-License-Identifier: Apache-2.0
#pragma once
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
@interface S2ABluetoothDrivers : NSObject
+ (NSArray<NSString *> * _Nonnull)identifiers;
+ (NSString * _Nullable)keyForDevice:(IOHIDDeviceRef _Nonnull)device;
+ (NSString * _Nonnull)choiceForKey:(NSString * _Nonnull)key;
+ (NSString * _Nullable)resolvedForDevice:(IOHIDDeviceRef _Nonnull)device;
+ (BOOL)saveChoice:(NSString * _Nonnull)choice forKey:(NSString * _Nonnull)key;
@end
