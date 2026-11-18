// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "include/S2ASystemControllerSlots.h"
#import "include/S2AControllerInput.h"
#import <GameController/GameController.h>
#include <string.h>

@implementation S2ASystemControllerSlots {
    NSMapTable<GCController *, NSString *> *_connections;
    s2a_controller_selection _selections[4];
    s2a_controller_assignment _assignments[4];
    uint32_t _connectedMask;
    NSArray *_devices;
    NSArray *_assignedDevices;
}
- (instancetype)init {
    if ((self = [super init])) {
        _connections = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                           valueOptions:NSPointerFunctionsStrongMemory];
        for (unsigned i = 0; i < 4; i++) _selections[i].backend = S2A_CONTROLLER_AUTO;
        [self stop];
    }
    return self;
}
- (BOOL)configure:(const s2a_controller_selection *)selections {
    NSAssert(NSThread.isMainThread, @"Controller slots require main thread");
    if (!selections) return NO;
    s2a_controller_assignment checked[4];
    if (!s2a_controller_assign(selections, NULL, 0, NULL, checked)) return NO;
    for (unsigned i = 0; i < 4; i++) if (selections[i].backend == S2A_CONTROLLER_NSPRO) return NO;
    BOOL changed = NO;
    for (unsigned i = 0; i < 4; i++)
        if (selections[i].backend != _selections[i].backend || strcmp(selections[i].device, _selections[i].device)) changed = YES;
    if (changed) {
        memcpy(_selections, selections, sizeof _selections);
        memset(_assignments, 0, sizeof _assignments);
        _connectedMask = 0;
        _assignedDevices = @[@"", @"", @"", @""];
    }
    return YES;
}
- (NSArray<NSDictionary<NSString *, NSNumber *> *> *)sampleControllers:(NSArray<GCController *> *)controllers active:(BOOL)active {
    NSAssert(NSThread.isMainThread, @"Controller slots require main thread");
    NSArray *empty = @[@{}, @{}, @{}, @{}];
    NSHashTable *present = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray<GCController *> *supported = [NSMutableArray array];
    for (GCController *controller in controllers) {
        if (!controller.extendedGamepad || [present containsObject:controller]) continue;
        [present addObject:controller];
        [supported addObject:controller];
    }
    if (supported.count > S2A_CONTROLLER_MAX_DEVICES) { [self stop]; return empty; }
    for (GCController *old in _connections.keyEnumerator.allObjects)
        if (![present containsObject:old]) [_connections removeObjectForKey:old];
    s2a_controller_candidate candidates[S2A_CONTROLLER_MAX_DEVICES] = {0};
    NSMutableDictionary<NSString *, GCController *> *byID = [NSMutableDictionary dictionary];
    NSMutableArray *devices = [NSMutableArray array];
    unsigned index = 0;
    for (GCController *controller in supported) {
        NSString *identity = [_connections objectForKey:controller];
        if (!identity) {
            identity = [@"gc-connection:" stringByAppendingString:NSUUID.UUID.UUIDString];
            [_connections setObject:identity forKey:controller];
        }
        s2a_controller_candidate *candidate = &candidates[index++];
        candidate->backend = S2A_CONTROLLER_SYSTEM;
        strlcpy(candidate->device, identity.UTF8String, sizeof candidate->device);
        strlcpy(candidate->physical, identity.UTF8String, sizeof candidate->physical);
        byID[identity] = controller;
        [devices addObject:@{@"id":identity, @"name":controller.vendorName ?: controller.productCategory ?: @"GameController"}];
    }
    _devices = [devices sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"id"] compare:b[@"id"]];
    }];
    if (!s2a_controller_assign(_selections, candidates, index, _assignments, _assignments)) {
        [self stop]; return empty;
    }
    _connectedMask = 0;
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:4];
    NSMutableArray *assigned = [NSMutableArray arrayWithCapacity:4];
    for (unsigned i = 0; i < 4; i++) {
        NSString *identity = [NSString stringWithUTF8String:_assignments[i].device];
        GCController *controller = byID[identity];
        // Capture only the assigned object. No latest-event fallback or handler ownership.
        GCExtendedGamepad *pad = controller ? controller.capture.extendedGamepad : nil;
        if (pad) _connectedMask |= 1u << i;
        [assigned addObject:pad ? identity : @""];
        [values addObject:active && pad ? s2a_system_pad_values(pad) : @{}];
    }
    _assignedDevices = [assigned copy];
    return values;
}
- (uint32_t)connectedMask { return _connectedMask; }
- (NSArray *)devices { return _devices; }
- (NSArray *)assignedDevices { return _assignedDevices; }
- (void)stop {
    NSAssert(NSThread.isMainThread, @"Controller slots require main thread");
    [_connections removeAllObjects];
    memset(_assignments, 0, sizeof _assignments);
    _connectedMask = 0;
    _devices = @[];
    _assignedDevices = @[@"", @"", @"", @""];
}
@end
