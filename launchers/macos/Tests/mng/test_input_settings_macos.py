"""Exercise the production AppKit settings view with isolated in-memory APIs.
No game, formal configuration or save is opened; windows are never ordered front.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[4]
PROBE=r'''
#import <Cocoa/Cocoa.h>
#include <assert.h>
static NSWindow *window;
static int sources[4], failSource, failBinding;
#include "input_source.h"
#define INPUT_MOTION_PLAYERS 1
static int runtime_input_source_allows(int slot,unsigned device){return (input_source_mask(sources[slot])&device)!=0;}
static int runtime_input_source(int slot) { return sources[slot]; }
static int runtime_input_source_set(int slot,int source) { if(failSource)return 0; sources[slot]=source; return 1; }
static int suspended, mouseMode, keyboardSlot=-1, types[4], maps[4][22], keys[4][24];
static int runtime_gamepad_slot_count(void) { return 4; }
static void runtime_input_settings_suspend(int value) { suspended=value; }
static void front_mouse_update(void) {}
static int runtime_gamepad_slot_type(int port) { return types[port]; }
static int runtime_gamepad_slot_type_set(int port,int type) { types[port]=type; return 1; }
static int runtime_input_binding_get(int port,int group,int target){
 int found=-1;for(int i=group?17:0;i<(group?22:17);i++)if(maps[port][i]==target){if(found>=0)return -2;found=i;}return found;
}
static int runtime_input_binding_set(int port,int group,int target,int physical){
 for(int i=group?17:0;i<(group?22:17);i++)if(maps[port][i]==target)maps[port][i]=-1;
 if(physical>=0)maps[port][physical]=target;return 1;
}
static int runtime_input_binding_reset(int port,int group){(void)port;(void)group;return 1;}
static int sticks[4][2],mouseStick=2,gyros[4];
static int runtime_input_gyro_get(int slot){return gyros[slot];}
static int runtime_input_gyro_set(int slot,int source){gyros[slot]=source;return 1;}
static int runtime_input_stick_get(int slot,int target){return sticks[slot][target];}
static int runtime_input_stick_set(int slot,int target,int source){sticks[slot][target]=source;return 1;}
static int runtime_input_mouse_stick_get(void){return mouseStick;}
static int runtime_input_mouse_stick_set(int target){mouseStick=target;return 1;}
static int runtime_keyboard_slot(void) { return keyboardSlot; }
static int runtime_keyboard_bind(int port) { if(failBinding)return 0; keyboardSlot=port; return 1; }
static int runtime_keyboard_mapping_get(int port,int action) { return keys[port][action]; }
static int runtime_keyboard_mapping_set(int port,int action,int key) { keys[port][action]=key; return 1; }
static int runtime_keyboard_mapping_reset(int port) { (void)port; return 1; }
static int runtime_mouse_enabled(void) { return mouseMode; }
static int runtime_mouse_toggle(void) { return mouseMode^=1; }
static NSString *deviceBinding=@"auto";
static NSArray *runtime_gamepad_devices(void) { return @[@{@"id":@"pad-a",@"name":@"Xbox"},@{@"id":@"pad-b",@"name":@"Switch"}]; }
static NSString *runtime_gamepad_device_binding(int slot) { (void)slot; return deviceBinding; }
static NSString *runtime_gamepad_device_label(int slot) { (void)slot; return @"离线设备"; }
static int runtime_gamepad_device_bind(int slot,NSString *key) { (void)slot; deviceBinding=key; return 1; }
static int physicalEnabled;
static NSString *physicalBinding=@"none";
static int runtime_keyboard_physical_enable(int enabled) { physicalEnabled=enabled; return 1; }
static int runtime_keyboard_physical_enabled(void) { return physicalEnabled; }
static NSString *runtime_keyboard_physical_status(void) { return @"独立键盘测试状态"; }
static NSArray *runtime_keyboard_physical_devices(void) { return @[@{@"id":@"keyboard-a",@"name":@"USB Keyboard"}]; }
static NSString *runtime_keyboard_physical_binding(int slot) { (void)slot; return physicalBinding; }
static NSString *runtime_keyboard_physical_label(int slot) { (void)slot; return @"离线键盘"; }
static int runtime_keyboard_physical_bind(int slot,NSString *key) { (void)slot; physicalBinding=key; return 1; }
// Intercept only the modal response; all production view logic remains real.
static void (^pendingConfirmation)(NSModalResponse);
@interface TestInputAlert : NSAlert @end
@implementation TestInputAlert
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler {
    (void)window; pendingConfirmation = [handler copy];
}
@end
#define NSAlert TestInputAlert
#include "input_settings_macos.inc"
#undef NSAlert
#include "input_settings_shortcut_macos.h"
static NSPopUpButton *findPopup(NSView *view, SEL action, int tag) {
    for (NSView *child in view.subviews) {
        if ([child isKindOfClass:NSPopUpButton.class]) {
            NSPopUpButton *p=(NSPopUpButton *)child;
            if (p.action==action && (tag==-999 || p.tag==tag)) return p;
        }
        NSPopUpButton *found=findPopup(child,action,tag); if(found)return found;
    }
    return nil;
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    inputSettingsWindow=[D3InputSettings new];
    D3InputSettings *ui=inputSettingsWindow;
    [ui rebuild]; assert(!ui.window.visible);
    assert([ui.window isKindOfClass:NSPanel.class]);
    assert(ui.window.collectionBehavior & NSWindowCollectionBehaviorFullScreenAuxiliary);
    for(int mode=0;mode<5;mode++) {
        NSEventModifierFlags flags=mode==0?0:NSEventModifierFlagCommand;
        if(mode==2)flags|=NSEventModifierFlagShift;
        NSEvent *event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:flags timestamp:0 windowNumber:0 context:nil
            characters:mode==3?@"，":mode==4?@"x":@"," charactersIgnoringModifiers:mode==3?@"，":mode==4?@"x":@","
            isARepeat:NO keyCode:mode==4?7:43];
        assert(d3_input_settings_shortcut(event)==(mode==1||mode==3));
    }
    NSPopUpButton *players=findPopup(ui.window.contentView,@selector(player:),-999);
    assert(players.numberOfItems==4); [players selectItemAtIndex:1]; [ui player:players];
    assert(ui.port==1);
    NSPopUpButton *source=findPopup(ui.window.contentView,@selector(sourceChanged:),-999);
    assert(![source itemAtIndex:3].enabled && ![source itemAtIndex:4].enabled);
    [source selectItemAtIndex:2]; [ui sourceChanged:source]; assert(sources[1]==2 && sources[0]==0 && keyboardSlot==1);
    failBinding=1; keyboardSlot=0;
    source=findPopup(ui.window.contentView,@selector(sourceChanged:),-999);
    [source selectItemAtIndex:2];[ui sourceChanged:source];
    assert(keyboardSlot==0 && [ui.status.stringValue containsString:@"归属保存失败"]);
    failBinding=0;[ui sourceChanged:source];assert(keyboardSlot==1);
    physicalEnabled=1;keyboardSlot=0;
    source=findPopup(ui.window.contentView,@selector(sourceChanged:),-999);
    [source selectItemAtIndex:2];[ui sourceChanged:source];assert(keyboardSlot==0);
    assert([ui.status.stringValue containsString:@"物理键盘"]);physicalEnabled=0;
    NSPopUpButton *type=findPopup(ui.window.contentView,@selector(typeChanged:),-999);
    assert([type itemAtIndex:4].enabled);
    [type selectItemAtIndex:3]; [ui typeChanged:type];
    assert(types[1]==3 && types[0]==0);
    type=findPopup(ui.window.contentView,@selector(typeChanged:),-999);
    [type selectItemAtIndex:4]; [ui typeChanged:type]; assert(pendingConfirmation);
    // A later selection must not redirect the pending action to player one.
    ui.port=0; pendingConfirmation(NSAlertFirstButtonReturn); pendingConfirmation=nil;
    assert(ui.port==1 && types[1]==4 && types[0]==0);
    assert([ui.status.stringValue containsString:@"2P"]);
    type=findPopup(ui.window.contentView,@selector(typeChanged:),-999);
    [type selectItemAtIndex:4]; [ui typeChanged:type];
    pendingConfirmation(NSAlertSecondButtonReturn); pendingConfirmation=nil;
    assert(ui.port==1 && types[1]==4 && types[0]==0);

    NSPopUpButton *button=findPopup(ui.window.contentView,@selector(buttonChanged:),0);
    [button selectItemAtIndex:8]; [ui buttonChanged:button];
    assert(maps[1][7]==0 && maps[0][7]==0);
    ui.page=2;[ui rebuild];assert(!findPopup(ui.window.contentView,@selector(buttonChanged:),0).enabled);
    ui.page=1; keys[1][0]=250; [ui rebuild];
    NSPopUpButton *key=findPopup(ui.window.contentView,@selector(keyChanged:),0);
    assert([key.selectedItem.representedObject intValue]==250);
    NSInteger shift=-1;
    for (NSInteger i=0;i<key.numberOfItems;++i)
        if ([[key itemAtIndex:i].representedObject intValue]==229) shift=i;
    assert(shift>=0); [key selectItemAtIndex:shift]; [ui keyChanged:key];
    assert(keys[1][0]==229 && keys[0][0]==0);
    NSPopUpButton *binding=findPopup(ui.window.contentView,@selector(bindChanged:),-999);
    [binding selectItemAtIndex:2]; [ui bindChanged:binding]; assert(keyboardSlot==1 && sources[1]==2);
    NSPopUpButton *device=findPopup(ui.window.contentView,@selector(deviceChanged:),-999);
    assert(device.numberOfItems==4); [device selectItemAtIndex:3]; [ui deviceChanged:device];
    // 2P alone keeps the global HID backend active: reject without changing source/binding.
    assert(![deviceBinding isEqual:@"pad-b"] && sources[1]==2);
    assert([ui.status.stringValue containsString:@"所有"]);
    types[1]=3; [ui rebuild];
    device=findPopup(ui.window.contentView,@selector(deviceChanged:),-999);
    [device selectItemAtIndex:3]; [ui deviceChanged:device];
    assert([deviceBinding isEqual:@"pad-b"] && sources[1]==1);
    assert(keyboardSlot==1 && [ui.status.stringValue containsString:@"仅保留"]);
    binding=findPopup(ui.window.contentView,@selector(bindChanged:),-999);
    assert([binding.selectedItem.title containsString:@"来源未启用"]);
    deviceBinding=@"offline"; [ui rebuild];
    device=findPopup(ui.window.contentView,@selector(deviceChanged:),-999);
    assert([device.selectedItem.representedObject isEqual:@"offline"] && !device.selectedItem.enabled);
    [ui physicalEnable:nil]; assert(physicalEnabled);
    NSPopUpButton *physical=findPopup(ui.window.contentView,@selector(physicalChanged:),-999);
    assert(physical.enabled && physical.numberOfItems==2);
    [physical selectItemAtIndex:1]; [ui physicalChanged:physical]; assert([physicalBinding isEqual:@"keyboard-a"] && sources[1]==2);
    assert(!findPopup(ui.window.contentView,@selector(bindChanged:),-999).enabled);
    [ui physicalEnable:nil]; assert(!physicalEnabled);
    sources[1]=1; failSource=1;
    binding=findPopup(ui.window.contentView,@selector(bindChanged:),-999);
    [binding selectItemAtIndex:2]; [ui bindChanged:binding];
    assert(sources[1]==1 && [ui.status.stringValue containsString:@"input-sources.plist"]);
    failSource=0; failBinding=1; keyboardSlot=0;
    [ui bindChanged:binding];
    assert(sources[1]==2 && keyboardSlot==0 && [ui.status.stringValue containsString:@"归属保存失败"]);
    failBinding=0;

    ui.port=0;ui.page=0;[ui rebuild];
    NSPopUpButton *stick=findPopup(ui.window.contentView,@selector(stickChanged:),0);
    [stick selectItemAtIndex:2];[ui stickChanged:stick];assert(sticks[0][0]==2 && sticks[1][0]==0);
    ui.page=2;[ui rebuild];
    NSPopUpButton *mouseStickPopup=findPopup(ui.window.contentView,@selector(mouseStickChanged:),-999);
    [mouseStickPopup selectItemAtIndex:1];[ui mouseStickChanged:mouseStickPopup];assert(mouseStick==1);
    NSPopUpButton *gyro=findPopup(ui.window.contentView,@selector(gyroChanged:),-999);
    [gyro selectItemAtIndex:3];[ui gyroChanged:gyro];assert(gyros[0]==3);
    ui.page=1;[ui rebuild];
    MNGKeyBindingButton *capture=nil;
    for(NSView *v in ui.window.contentView.subviews)if([v isKindOfClass:MNGKeyBindingButton.class] && v.tag==0)capture=(id)v;
    assert(capture);[ui captureKey:capture];assert(capture.waiting);
    NSEvent *j=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"j" charactersIgnoringModifiers:@"j" isARepeat:NO keyCode:38];
    [capture keyDown:j];assert(keys[0][0]==13 && keys[1][0]==229);
    const char *preview=getenv("MNG_INPUT_PREVIEW");
    if(preview)for(int page=0;page<3;page++) {
        ui.page=page;[ui rebuild];[ui.window orderFront:nil];
        [ui.window.contentView layoutSubtreeIfNeeded];[ui.window display];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        NSView *v=ui.window.contentView;NSBitmapImageRep *image=[v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:image];
        NSString *path=[@(preview) stringByAppendingPathComponent:[NSString stringWithFormat:@"input-%d.png",page]];
        assert([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]);
    }
    [ui result:0]; assert([ui.status.stringValue containsString:@"失败"]);
    [ui mouseChanged:nil]; assert(mouseMode==1);
    suspended=1; [ui windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:ui.window]]; assert(!suspended);
    puts("PASS native settings view, independent player actions, keyboard codes and failure status");
} }
'''
class MacSettingsTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin' and shutil.which('clang'),'requires macOS')
    def test_production_view(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'probe.m'; source.write_text(PROBE); exe=Path(tmp)/'probe'
            build=subprocess.run(['clang','-fobjc-arc','-Wall','-Wextra','-Werror',
                '-I'+str(ROOT/'macos/controllers/mng'),str(source),'-framework','Cocoa','-o',str(exe)],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            # Fresh process snapshot before the isolated native UI probe, never a game launch.
            subprocess.run(['ps','-axo','pid,comm'],check=True,stdout=subprocess.DEVNULL)
            run=subprocess.run([exe],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('PASS',run.stdout)

