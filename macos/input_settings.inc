// MacNativeGames-style independent in-game panel, adapted to S2Arm schema 1.
// Uses the running process's captured mapping, never rewrites the launch request
// or another user's configuration. Four-player UI waits for the real sampler.
@interface S2AMacInputSettings : NSWindowController <NSWindowDelegate>
@property(copy) NSDictionary *(^readMapping)(void);
@property(copy) NSArray *(^readDevices)(void);
@property(copy) NSString *(^applyMapping)(NSDictionary *);
@property(copy) void (^editing)(BOOL);
@property(strong) NSPopUpButton *backend, *device;
@property(strong) NSMutableArray<NSPopUpButton *> *buttons, *axes;
@property(strong) NSMutableArray<NSButton *> *invert;
@property(strong) NSTextField *deadzone, *status;
@property(strong) NSDictionary *base;
- (void)open:(id)sender;
@end
@implementation S2AMacInputSettings
- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 760, 660)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:panel])) {
        panel.title = @"玩家输入设置 · 本局";
        panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
        panel.hidesOnDeactivate = NO; panel.releasedWhenClosed = NO; panel.delegate = self;
    }
    return self;
}
- (void)label:(NSString *)text x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = NSMakeRect(x, y, width, 24); [self.window.contentView addSubview:label];
}
- (NSPopUpButton *)popup:(NSArray<NSString *> *)names x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, y, width, 26) pullsDown:NO];
    [p addItemsWithTitles:names]; [self.window.contentView addSubview:p]; return p;
}
- (void)rebuild {
    self.base = self.readMapping();
    self.window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 660)];
    [self label:@"当前支持1P：应用后立即生效，不改其他运行中的游戏或用户。" x:20 y:624 width:720];
    [self label:@"本局设置不写回启动器；永久配置仍在启动器保存。2–4P待接入。" x:20 y:596 width:720];
    self.backend = [self popup:@[@"系统手柄", @"北通宙斯NS模式", @"禁用"] x:20 y:554 width:180];
    NSArray *backends = @[@"system", @"nspro-hid", @"disabled"];
    NSUInteger backend = [backends indexOfObject:self.base[@"controller"][@"backend"] ?: @"system"];
    [self.backend selectItemAtIndex:backend == NSNotFound ? 0 : backend];
    self.backend.target = self; self.backend.action = @selector(backendChanged:);
    self.device = [self popup:@[@"自动选择（当前后端）"] x:220 y:554 width:520];
    self.device.itemArray[0].representedObject = @"";
    NSString *selected = self.base[@"controller"][@"device"] ?: @"";
    for (NSDictionary *d in self.readDevices()) {
        NSString *identifier = d[@"id"];
        if (!identifier.length) continue;
        [self.device addItemWithTitle:d[@"name"] ?: identifier];
        self.device.lastItem.representedObject = identifier;
        if ([selected isEqual:identifier]) [self.device selectItem:self.device.lastItem];
    }
    if (selected.length && self.device.indexOfSelectedItem == 0) {
        [self.device addItemWithTitle:@"原绑定设备（当前离线）"];
        self.device.lastItem.representedObject = selected; [self.device selectItem:self.device.lastItem];
    }
    self.buttons = [NSMutableArray new];
    NSMutableArray *sources = [NSMutableArray arrayWithObject:@"未绑定"];
    for (int i = 0; i < 16; i++) [sources addObject:@(s2a_input_pad_name(i))];
    for (int i = 0; i < 16; i++) {
        CGFloat x = 20 + (i / 8) * 370, y = 510 - (i % 8) * 36;
        NSString *target = @(s2a_input_target_name(i));
        [self label:target x:x y:y width:65];
        NSPopUpButton *p = [self popup:sources x:x+70 y:y width:260];
        NSUInteger index = [sources indexOfObject:self.base[@"gamepad"][target]];
        [p selectItemAtIndex:index == NSNotFound ? 0 : index]; [self.buttons addObject:p];
    }
    self.axes = [NSMutableArray new]; self.invert = [NSMutableArray new];
    NSArray *axisTargets = @[@"LX", @"LY", @"RX", @"RY"];
    NSArray *axisSources = @[@"未绑定", @"leftX", @"leftY", @"rightX", @"rightY"];
    for (int i = 0; i < 4; i++) {
        CGFloat x = 20 + (i / 2) * 370, y = 200 - (i % 2) * 36;
        [self label:axisTargets[i] x:x y:y width:45];
        NSPopUpButton *p = [self popup:axisSources x:x+45 y:y width:200];
        NSDictionary *binding = self.base[@"axes"][axisTargets[i]];
        NSUInteger index = [axisSources indexOfObject:binding[@"source"]];
        [p selectItemAtIndex:index == NSNotFound ? 0 : index]; [self.axes addObject:p];
        NSButton *invert = [NSButton checkboxWithTitle:@"反向" target:nil action:NULL];
        invert.frame = NSMakeRect(x+255, y, 75, 26); invert.state = [binding[@"invert"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [self.window.contentView addSubview:invert]; [self.invert addObject:invert];
    }
    [self label:@"死区（0–0.95）" x:20 y:120 width:140];
    self.deadzone = [[NSTextField alloc] initWithFrame:NSMakeRect(160,120,90,24)];
    self.deadzone.stringValue = [NSString stringWithFormat:@"%.2f", [self.base[@"deadzone"] doubleValue]];
    [self.window.contentView addSubview:self.deadzone];
    NSButton *apply = [NSButton buttonWithTitle:@"应用到本局" target:self action:@selector(apply:)];
    apply.frame = NSMakeRect(570, 112, 170, 36); [self.window.contentView addSubview:apply];
    self.status = [NSTextField wrappingLabelWithString:@"设置期间暂停向游戏传入按键；游戏继续运行。关闭后恢复输入。"];
    self.status.frame = NSMakeRect(20, 20, 720, 70); [self.window.contentView addSubview:self.status];
}
- (void)backendChanged:(id)sender { (void)sender; [self.device selectItemAtIndex:0]; }
- (void)apply:(id)sender {
    (void)sender;
    double deadzone; NSScanner *scanner = [NSScanner scannerWithString:self.deadzone.stringValue];
    if (![scanner scanDouble:&deadzone] || !scanner.isAtEnd || !isfinite(deadzone)) {
        self.status.stringValue = @"未更改：死区必须是有效数字。"; return;
    }
    NSMutableDictionary *next = [self.base mutableCopy];
    NSMutableDictionary *pad = [self.base[@"gamepad"] mutableCopy];
    for (int i = 0; i < 16; i++) {
        NSString *target = @(s2a_input_target_name(i)); NSInteger index = self.buttons[i].indexOfSelectedItem;
        if (index > 0) pad[target] = @(s2a_input_pad_name((int)index-1)); else [pad removeObjectForKey:target];
    }
    NSMutableDictionary *axes = [NSMutableDictionary new]; NSArray *names = @[@"LX", @"LY", @"RX", @"RY"];
    for (int i = 0; i < 4; i++) if (self.axes[i].indexOfSelectedItem > 0)
        axes[names[i]] = @{@"source": @(s2a_input_axis_name((int)self.axes[i].indexOfSelectedItem-1)), @"invert": @((BOOL)(self.invert[i].state == NSControlStateValueOn))};
    next[@"gamepad"] = pad; next[@"axes"] = axes; next[@"deadzone"] = @(deadzone);
    next[@"controller"] = @{@"backend": @[@"system", @"nspro-hid", @"disabled"][self.backend.indexOfSelectedItem],
                            @"device": self.device.selectedItem.representedObject ?: @""};
    NSString *error = self.applyMapping(next);
    if (error) self.status.stringValue = [@"未更改：" stringByAppendingString:error];
    else { [self rebuild]; self.status.stringValue = @"已应用到本局。关闭此窗口恢复输入；下次启动仍用启动器保存的配置。"; }
}
- (void)open:(id)sender {
    (void)sender; self.editing(YES); [self rebuild]; [self.window center]; [self.window makeKeyAndOrderFront:nil];
}
- (void)windowWillClose:(NSNotification *)note { (void)note; self.editing(NO); }
@end
