// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Developer-created GC snapshots only. No device enumeration, callbacks or IOHID.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import "../../../macos/controllers/include/S2ASystemControllerSlots.h"
#include <math.h>
#include <string.h>
static unsigned checks;
static void check(BOOL ok, const char *message) {
    checks++; if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static s2a_controller_selection selections[4];
static void defaults(void) {
    memset(selections, 0, sizeof selections);
    for (unsigned i = 0; i < 4; i++) selections[i].backend = S2A_CONTROLLER_AUTO;
}
static NSArray *sample(S2ASystemControllerSlots *slots, NSArray *pads) {
    return [slots sampleControllers:pads active:YES];
}
int main(void) { @autoreleasepool {
    check(NSThread.isMainThread, "main-thread fixture");
    S2ASystemControllerSlots *slots = [S2ASystemControllerSlots new];
    NSMutableArray<GCController *> *pads = [NSMutableArray array];
    NSMutableArray *handlers = [NSMutableArray array];
    for (unsigned i = 0; i < 4; i++) {
        GCController *c = [GCController controllerWithExtendedGamepad];
        check(c.isSnapshot, "synthetic controller only");
        c.playerIndex = (GCControllerPlayerIndex)i;
        GCExtendedGamepadValueChangedHandler handler = ^(GCExtendedGamepad *p, GCControllerElement *e) { (void)p; (void)e; };
        c.extendedGamepad.valueChangedHandler = handler;
        [handlers addObject:c.extendedGamepad.valueChangedHandler];
        [c.extendedGamepad.leftThumbstick.xAxis setValue:(i + 1) * .2f];
        [c.extendedGamepad.rightThumbstick.yAxis setValue:-(float)(i + 1) * .2f];
        NSArray *buttons = @[c.extendedGamepad.leftShoulder, c.extendedGamepad.rightShoulder,
                             c.extendedGamepad.leftTrigger, c.extendedGamepad.rightTrigger];
        [buttons[i] setValue:1];
        [pads addObject:c];
    }
    NSArray *values = sample(slots, pads);
    check(slots.connectedMask == 15 && slots.devices.count == 4, "identical snapshots are four devices");
    NSArray *original = slots.assignedDevices;
    check([NSSet setWithArray:original].count == 4, "distinct opaque connection IDs");
    NSMutableArray *slotPads = [NSMutableArray array];
    NSArray *names = @[@"leftShoulder", @"rightShoulder", @"leftTrigger", @"rightTrigger"];
    for (unsigned i = 0; i < 4; i++) {
        unsigned source = (unsigned)lroundf([values[i][@"leftX"] floatValue] / .2f) - 1;
        check(source < 4, "owned axis identifies source");
        [slotPads addObject:pads[source]];
        check(fabsf([values[i][@"rightY"] floatValue] + (source + 1) * .2f) < .001f, "owned negative right axis");
        for (unsigned j = 0; j < 4; j++) check([values[i][names[j]] boolValue] == (source == j), "buttons never mirror");
    }
    for (unsigned i = 0; i < 32; i++) {
        values = sample(slots, pads.reverseObjectEnumerator.allObjects);
        check([slots.assignedDevices isEqual:original], "enumeration reorder preserves ownership");
        defaults(); check([slots configure:selections], "idempotent config");
        check([slots.assignedDevices isEqual:original], "idempotent config preserves ownership");
    }
    values = [slots sampleControllers:pads active:NO];
    check(slots.connectedMask == 15 && [values isEqual:@[@{},@{},@{},@{}]], "focus releases values not topology");
    values = sample(slots, @[slotPads[1],slotPads[3]]);
    check(slots.connectedMask == 10 && [values[0] count] == 0 && [values[2] count] == 0, "holes do not compact");
    check([slots.assignedDevices[1] isEqual:original[1]] && [slots.assignedDevices[3] isEqual:original[3]], "survivors stay assigned");
    sample(slots, pads);
    check(slots.connectedMask == 15, "reconnect fills holes");
    check(![[slots.devices valueForKey:@"id"] containsObject:original[0]], "disconnect retires identity even for reused object");
    check([slots.assignedDevices[1] isEqual:original[1]] && [slots.assignedDevices[3] isEqual:original[3]], "reconnect cannot steal survivors");
    NSArray *reconnected = slots.assignedDevices;
    sample(slots, @[pads[0],pads[0],pads[1],pads[2],pads[3]]);
    check(slots.devices.count == 4 && [slots.assignedDevices isEqual:reconnected], "repeated object cannot occupy two slots");
    defaults();
    strlcpy(selections[2].device, [reconnected[0] UTF8String], sizeof selections[2].device);
    check([slots configure:selections], "explicit connection configuration");
    sample(slots, pads);
    check(slots.connectedMask == 15 && [slots.assignedDevices[2] isEqual:reconnected[0]], "explicit reserves before auto");
    strlcpy(selections[3].device, selections[2].device, sizeof selections[3].device);
    check([slots configure:selections], "duplicate explicit configuration");
    sample(slots, pads);
    check(slots.connectedMask == 3, "duplicate explicit leaves both empty");
    check(![slots.assignedDevices containsObject:reconnected[0]], "contested connection not stolen by auto");
    NSArray *before = slots.assignedDevices;
    selections[0].backend = S2A_CONTROLLER_NSPRO;
    check(![slots configure:selections], "HID cannot silently become system");
    check([slots.assignedDevices isEqual:before] && slots.connectedMask == 3, "invalid configuration leaves ownership");
    defaults(); memset(selections[0].device, 'x', sizeof selections[0].device);
    check(![slots configure:selections], "unterminated selector rejected");
    check(![slots configure:NULL], "null config rejected");
    defaults(); selections[0].backend = 99;
    check(![slots configure:selections], "invalid backend rejected");
    defaults(); selections[0].backend = S2A_CONTROLLER_DISABLED;
    strlcpy(selections[1].device, "missing", sizeof selections[1].device);
    check([slots configure:selections], "disabled and missing selectors"); sample(slots, pads);
    check(slots.connectedMask == 12, "missing explicit never falls back");
    defaults(); check([slots configure:selections], "restore automatic"); sample(slots, pads);
    NSArray *preStop = [slots.devices valueForKey:@"id"];
    [slots stop]; check(slots.connectedMask == 0 && slots.devices.count == 0, "stop clears topology");
    sample(slots, pads);
    for (NSString *old in preStop) check(![[slots.devices valueForKey:@"id"] containsObject:old], "stop retires every token");
    for (unsigned i = 0; i < 4; i++) {
        check(pads[i].playerIndex == (GCControllerPlayerIndex)i, "playerIndex never overwritten");
        check(pads[i].extendedGamepad.valueChangedHandler == handlers[i], "global handlers never stolen");
    }
    GCController *remote = [GCController controllerWithMicroGamepad];
    check(remote.isSnapshot, "synthetic remote"); sample(slots, @[remote]);
    check(slots.devices.count == 0 && slots.connectedMask == 0, "unsupported profile ignored");
    NSMutableArray *overflow = [NSMutableArray array];
    for (unsigned i = 0; i <= S2A_CONTROLLER_MAX_DEVICES; i++) [overflow addObject:[GCController controllerWithExtendedGamepad]];
    values = sample(slots, overflow);
    check(slots.connectedMask == 0 && slots.devices.count == 0 && [values isEqual:@[@{},@{},@{},@{}]], "overflow fails closed");
    sample(slots, pads); check(slots.connectedMask == 15, "recovers from invalid inventory");
    sample(slots, @[]); check(slots.connectedMask == 0 && slots.devices.count == 0, "empty inventory releases all");
    printf("System controller slots: %u checks passed; synthetic GC snapshots only\n", checks);
} }
