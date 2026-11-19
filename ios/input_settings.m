// SPDX-License-Identifier: Apache-2.0
#import "input_settings.h"
#import "input_config.h"
#import <GameController/GameController.h>
#include <TargetConditionals.h>
#include <math.h>
#include <string.h>

@interface S2ALiveInputSettings : UITableViewController
@property(nonatomic) s2a_input_config mapping;
@property(nonatomic, copy) NSString *result;
@property(nonatomic) NSInteger selectedPlayer;
@end
@implementation S2ALiveInputSettings
- (instancetype)init {
#if TARGET_OS_TV
    UITableViewStyle style = UITableViewStyleGrouped;
#else
    UITableViewStyle style = UITableViewStyleInsetGrouped;
#endif
    if ((self = [super initWithStyle:style])) {
        const s2a_input_config *current = s2a_ios_input_config_current();
        if (!current) return nil;
        _mapping = *current;
        if (!_mapping.players_present) {
            _mapping.players_present = 1;
            _mapping.players[0].backend = _mapping.controller_backend;
            memcpy(_mapping.players[0].device, _mapping.controller_device, sizeof _mapping.players[0].device);
            for (int i = 1; i < S2A_INPUT_PLAYER_COUNT; i++) {
                _mapping.players[i].backend = 3; // auto
                _mapping.players[i].device[0] = 0;
            }
        }
        self.title = @"手柄设置 (1P–4P)";
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:s2a_ios_input_config_can_save() ? @"保存并应用" : @"立即应用"
            style:UIBarButtonItemStyleDone target:self action:@selector(apply)];
    }
    return self;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 4 : section == 1 ? S2A_INPUT_TARGET_COUNT : section == 2 ? 8 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"1P–4P 多人手柄分配", @"目标按键 ← 实体按键", @"摇杆轴", @"死区"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"可分别为 1P / 2P / 3P / 4P 独立分配输入源（手柄自动匹配、虚拟手柄、键盘、系统蓝牙手柄、Switch 2 Pro 专有协议或停用该槽位）。虚拟手柄、键盘、手柄互不串线。";
    if (section == 1) return @"系统手柄和蓝牙手柄共用按键映射；不改触屏布局。打开设置时隔离游戏输入，关闭设置后恢复。";
    if (section == 3) return self.result ?: (s2a_ios_input_config_can_save() ? @"保存到本游戏的当前用户，并立即应用到本局，无需重启；与游戏库手柄设置互通。" : @"立即应用到当前游戏会话，无需重启；当前宿主未提供持久化用户范围，仅对本局生效。");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    __weak S2ALiveInputSettings *weakSelf = self;
    if (path.section == 0) {
        int slot = (int)path.row;
        NSArray<NSString *> *slotNames = @[@"1P", @"2P", @"3P", @"4P"];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ 输入源", slotNames[slot]];
        int currentBackend = _mapping.players[slot].backend;
        NSString *currentDev = @(_mapping.players[slot].device);
        NSArray<NSString *> *backendTitles = @[
            @"系统手柄（蓝牙 / MFi）",
            @"Switch 2 Pro（BLE）",
            @"已禁用",
            @"手柄（自动匹配）",
            @"虚拟手柄",
            @"键盘"
        ];
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        int order[6] = {3, 4, 5, 0, 1, 2};
        for (int k = 0; k < 6; k++) {
            int b = order[k];
            UIAction *act = [UIAction actionWithTitle:backendTitles[b] image:nil identifier:nil handler:^(UIAction *unused) {
                S2ALiveInputSettings *owner = weakSelf; if (!owner) return;
                owner->_mapping.players_present = 1;
                if (b == 4 || b == 5) {
                    for (int other = 0; other < S2A_INPUT_PLAYER_COUNT; other++) {
                        if (other != slot && owner->_mapping.players[other].backend == b) {
                            owner->_mapping.players[other].backend = 3;
                            owner->_mapping.players[other].device[0] = 0;
                        }
                    }
                }
                owner->_mapping.players[slot].backend = b;
                owner->_mapping.players[slot].device[0] = 0;
                if (slot == 0) {
                    owner->_mapping.controller_backend = (b == 0 || b == 1 || b == 2) ? b : 0;
                    owner->_mapping.controller_device[0] = 0;
                }
                [owner.tableView reloadData];
            }];
            act.state = (currentBackend == b && currentDev.length == 0) ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:act];
        }
        for (GCController *gc in GCController.controllers) {
            NSString *vname = gc.vendorName.length ? gc.vendorName : @"GameController";
            NSString *title = [NSString stringWithFormat:@"系统手柄 · %@", vname];
            UIAction *act = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *unused) {
                S2ALiveInputSettings *owner = weakSelf; if (!owner) return;
                owner->_mapping.players_present = 1;
                owner->_mapping.players[slot].backend = 0;
                strncpy(owner->_mapping.players[slot].device, vname.UTF8String, sizeof(owner->_mapping.players[slot].device) - 1);
                owner->_mapping.players[slot].device[sizeof(owner->_mapping.players[slot].device) - 1] = 0;
                if (slot == 0) {
                    owner->_mapping.controller_backend = 0;
                    strncpy(owner->_mapping.controller_device, vname.UTF8String, sizeof(owner->_mapping.controller_device) - 1);
                    owner->_mapping.controller_device[sizeof(owner->_mapping.controller_device) - 1] = 0;
                }
                [owner.tableView reloadData];
            }];
            act.state = (currentBackend == 0 && [currentDev isEqualToString:vname]) ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:act];
        }
        UIButton *choose = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *btnTitle = (currentBackend >= 0 && currentBackend < 6) ? backendTitles[currentBackend] : @"手柄（自动匹配）";
        if (currentBackend == 0 && currentDev.length > 0) btnTitle = [NSString stringWithFormat:@"系统手柄 · %@", currentDev];
        [choose setTitle:btnTitle forState:UIControlStateNormal];
        choose.menu = [UIMenu menuWithTitle:@"" children:actions];
        choose.showsMenuAsPrimaryAction = YES;
        choose.accessibilityLabel = cell.textLabel.text;
        choose.accessibilityIdentifier = [NSString stringWithFormat:@"settings.input.player.%@", slotNames[slot]];
        [choose sizeToFit];
        cell.accessoryView = choose;
        return cell;
    }
    if (path.section == 3) {
        cell.textLabel.text = @"死区";
#if TARGET_OS_TV
        NSMutableArray<UIMenuElement *> *dzActions = [NSMutableArray array];
        const int steps[] = {0, 5, 10, 15, 20, 25, 30, 40, 50};
        for (size_t k = 0; k < sizeof(steps) / sizeof(steps[0]); k++) {
            float val = steps[k] / 100.0f;
            NSString *title = [NSString stringWithFormat:@"%.2f", val];
            UIAction *act = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *unused) {
                S2ALiveInputSettings *owner = weakSelf; if (!owner) return;
                owner->_mapping.deadzone = val;
                [owner.tableView reloadData];
            }];
            act.state = fabsf(_mapping.deadzone - val) < 0.005f ? UIMenuElementStateOn : UIMenuElementStateOff;
            [dzActions addObject:act];
        }
        UIButton *choose = [UIButton buttonWithType:UIButtonTypeSystem];
        [choose setTitle:[NSString stringWithFormat:@"%.2f", _mapping.deadzone] forState:UIControlStateNormal];
        choose.menu = [UIMenu menuWithTitle:@"" children:dzActions];
        choose.showsMenuAsPrimaryAction = YES;
        choose.accessibilityLabel = @"手柄死区"; choose.accessibilityIdentifier = @"settings.input.deadzone";
        [choose sizeToFit]; cell.accessoryView = choose; return cell;
#else
        UISlider *slider = [UISlider new]; slider.frame = CGRectMake(0, 0, 200, 44);
        slider.minimumValue = 0; slider.maximumValue = .95; slider.value = _mapping.deadzone;
        slider.accessibilityLabel = @"手柄死区"; slider.accessibilityIdentifier = @"settings.input.deadzone";
        slider.accessibilityValue = [NSString stringWithFormat:@"%.2f", slider.value];
        [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
            S2ALiveInputSettings *owner = weakSelf; if (!owner) return;
            UISlider *value = action.sender;
            owner->_mapping.deadzone = roundf(value.value * 100) / 100;
            value.accessibilityValue = [NSString stringWithFormat:@"%.2f", owner->_mapping.deadzone];
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider; return cell;
#endif
    }
    NSInteger index = path.section == 1 ? path.row : path.row / 2;
    NSArray *axisNames = @[@"LX", @"LY", @"RX", @"RY"];
    if (path.section == 2 && path.row % 2) {
        cell.textLabel.text = [axisNames[index] stringByAppendingString:@" 反向"];
#if TARGET_OS_TV
        UIButton *toggle = [UIButton buttonWithType:UIButtonTypeSystem];
        [toggle setTitle:_mapping.axes[index].invert ? @"开启" : @"关闭" forState:UIControlStateNormal];
        toggle.accessibilityLabel = cell.textLabel.text;
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            (void)action;
            S2ALiveInputSettings *owner = weakSelf; if (!owner) return;
            owner->_mapping.axes[index].invert = !owner->_mapping.axes[index].invert;
            [owner.tableView reloadData];
        }] forControlEvents:UIControlEventPrimaryActionTriggered];
        [toggle sizeToFit]; cell.accessoryView = toggle; return cell;
#else
        UISwitch *control = [UISwitch new]; control.on = _mapping.axes[index].invert;
        control.accessibilityLabel = cell.textLabel.text;
        [control addAction:[UIAction actionWithHandler:^(UIAction *action) {
            S2ALiveInputSettings *owner = weakSelf; if (!owner) return;
            owner->_mapping.axes[index].invert = ((UISwitch *)action.sender).on;
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = control; return cell;
#endif
    }
    BOOL buttonRow = path.section == 1;
    cell.textLabel.text = buttonRow ? @(s2a_input_target_name((int)index)) : axisNames[index];
    int selected = buttonRow ? _mapping.gamepad[index] : _mapping.axes[index].source;
    NSMutableArray *actions = [NSMutableArray new];
    for (int source = -1; source < (buttonRow ? 16 : 4); source++) {
        NSString *title = source < 0 ? @"未绑定" : buttonRow ? @(s2a_input_pad_name(source)) : @(s2a_input_axis_name(source));
        UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *unused) {
            S2ALiveInputSettings *owner = weakSelf; if (!owner) return;
            if (buttonRow) owner->_mapping.gamepad[index] = source;
            else owner->_mapping.axes[index].source = source;
            [owner.tableView reloadData];
        }];
        action.state = source == selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    UIButton *choose = [UIButton buttonWithType:UIButtonTypeSystem];
    [choose setTitle:selected < 0 ? @"未绑定" : buttonRow ? @(s2a_input_pad_name(selected)) : @(s2a_input_axis_name(selected)) forState:UIControlStateNormal];
    choose.menu = [UIMenu menuWithTitle:@"" children:actions]; choose.showsMenuAsPrimaryAction = YES;
    choose.accessibilityLabel = cell.textLabel.text;
    choose.accessibilityIdentifier = [@"settings.input." stringByAppendingString:cell.textLabel.text];
    [choose sizeToFit]; cell.accessoryView = choose; return cell;
}
- (void)apply {
    // Serialize the complete schema, retaining keyboard/mouse fields even though
    // this mobile panel edits physical controllers only. The shared parser is
    // authoritative for duplicate bindings and limits before publication.
    const s2a_input_config *c = &_mapping;
    NSMutableDictionary *keyboard = [NSMutableDictionary new], *mouse = [NSMutableDictionary new];
    NSMutableDictionary *pad = [NSMutableDictionary new], *axes = [NSMutableDictionary new];
    for (int i = 0; i < S2A_INPUT_TARGET_COUNT; i++) {
        NSString *name = @(s2a_input_target_name(i));
        if (c->keyboard[i].code >= 0) keyboard[name] = @{@"code": @(c->keyboard[i].code), @"modifiers": @(c->keyboard[i].modifiers)};
        if (c->mouse[i] >= 0) mouse[name] = @(c->mouse[i]);
        if (c->gamepad[i] >= 0) pad[name] = @(s2a_input_pad_name(c->gamepad[i]));
    }
    NSArray *names = @[@"LX", @"LY", @"RX", @"RY"];
    for (int i = 0; i < 4; i++) if (c->axes[i].source >= 0)
        axes[names[i]] = @{@"source": @(s2a_input_axis_name(c->axes[i].source)), @"invert": @((BOOL)c->axes[i].invert)};
    NSArray<NSString *> *backendKeys = @[@"system", @"nspro-hid", @"disabled", @"auto", @"touch", @"keyboard"];
    NSMutableDictionary *players = [NSMutableDictionary new];
    for (int i = 0; i < S2A_INPUT_PLAYER_COUNT; i++) {
        int b = c->players[i].backend;
        if (b < 0 || b > 5) b = 3;
        players[[NSString stringWithFormat:@"%d", i + 1]] = @{
            @"backend": backendKeys[b],
            @"device": @(c->players[i].device),
        };
    }
    NSDictionary *object = @{
        @"players": players,
        @"schema": @1, @"keyboard": keyboard, @"mouse": mouse, @"gamepad": pad, @"axes": axes,
        @"deadzone": @(c->deadzone), @"mouseOptions": @{@"mode": c->mouse_camera ? @"camera" : @"off",
        @"sensitivityX": @(c->sensitivity_x), @"sensitivityY": @(c->sensitivity_y), @"invertX": @((BOOL)c->invert_x),
        @"invertY": @((BOOL)c->invert_y), @"recenter": @((BOOL)c->recenter)}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    BOOL persist = s2a_ios_input_config_can_save();
    int error = !data ? S2A_INPUT_CONFIG_JSON : persist ?
        s2a_ios_input_config_apply_saved(data.bytes, data.length, NSUserDefaults.standardUserDefaults) :
        s2a_ios_input_config_apply(data.bytes, data.length);
    self.result = error == S2A_INPUT_CONFIG_DUPLICATE ? @"未应用：同一实体按键或轴不能重复绑定，请先解除原绑定。" :
        error ? @"未应用：配置无效或保存失败，本局原配置保持不变。" : persist ?
        @"已保存并应用到本局。关闭设置即可使用；本游戏的当前用户下次启动继续使用此配置。" :
        @"已应用到本局。关闭设置即可使用，无需重启；下次启动仍使用原有配置。";
    if (!error) {
        const char *gid = getenv("S2A_LAUNCH_GAME_ID");
        if (!gid || !*gid) gid = getenv("S2A_GAME_ID");
        NSUserDefaults *gameSuite = (gid && *gid) ? [[NSUserDefaults alloc] initWithSuiteName:[@"S2AGame." stringByAppendingString:@(gid).uppercaseString]] : nil;
        for (int i = 0; i < S2A_INPUT_PLAYER_COUNT; i++) {
            int b = c->players[i].backend;
            if (b < 0 || b > 5) b = 3;
            NSString *k = [NSString stringWithFormat:@"S2Arm.PlayerSource.%d", i + 1];
            [NSUserDefaults.standardUserDefaults setObject:backendKeys[b] forKey:k];
            if (gameSuite) [gameSuite setObject:backendKeys[b] forKey:k];
        }
    }
    [self.tableView reloadData];
}
@end
UIViewController *s2a_ios_input_settings_controller(void) { return [S2ALiveInputSettings new]; }
