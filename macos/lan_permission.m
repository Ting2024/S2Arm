// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Mac adapter for the shared Apple Bonjour provider. Called on the main queue.
// The OS presents local-network consent using the game bundle's usage string;
// do not copy UIKit's preliminary modal dialog or claim consent was granted.
#import <AppKit/AppKit.h>
#include "../runtime/src/native.h"
#include "../runtime/include/s2a_unattended.h"

void s2a_lan_permission_then(int dev_mode, void (^go)(void)) {
    (void)dev_mode;
    go();
}

void s2a_lan_permission_failed(const char *what, NSDictionary *error) {
    NSInteger code = [error[NSNetServicesErrorCode] integerValue];
    NSInteger domain = [error[NSNetServicesErrorDomain] integerValue];
    LOG("【红】Mac 局域网：%s失败（domain=%ld code=%ld）", what, (long)domain, (long)code);
    static BOOL shown;
    if (shown || s2a_unattended()) return;
    NSWindow *window = NSApp.keyWindow;
    if (!window || window.attachedSheet) return;
    shown = YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"本地联机发现失败";
    alert.informativeText = [NSString stringWithFormat:
        @"无法发布或查找局域网中继（错误 %ld / %ld）。\n\n请确认两台设备在同一局域网，并检查“系统设置 › 隐私与安全性 › 本地网络”是否允许 S2Arm / S2Arm Game，以及防火墙是否允许游戏的入站连接。权限拒绝只是可能原因，不是此错误的唯一解释。\n\n调整后请重新启动游戏，再进入本地联机。",
        (long)domain, (long)code];
    [alert addButtonWithTitle:@"知道了"];
    [alert beginSheetModalForWindow:window completionHandler:nil];
}
