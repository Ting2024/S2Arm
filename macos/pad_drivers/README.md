# macOS 蓝牙手柄驱动

在启动器手柄面板的「蓝牙」区找到已连接的实体手柄。默认「自动识别」按注册顺序采用第一条匹配规则。「系统默认」始终使用 S2Arm 原有路径。若北通宙斯以普通 Pro Controller 名称出现，可手选「北通宙斯（NS 模式）」，然后启动游戏或重连手柄。游戏宿主也需要包含此改动。

## 添加使用现有协议的设备

1. 在本目录添加品牌或型号的头文件，实现一个纯 C 匹配函数。参数依次是厂商名、产品名、VID、PID，缺失的名称为空字符串。匹配应能区分同品牌的其他模式和使用相同 VID/PID 的其他手柄。无法区分时可以始终返回 0，由玩家手选。
2. 在 [registry.h](registry.h) 引入头文件并登记一项，填写稳定的驱动 ID、输入协议、匹配函数。ID 会写入玩家偏好，须唯一；`auto` 和 `standard` 为保留值。蓝牙菜单和游戏宿主共用此表。北通示例见 [betop_ns.h](betop_ns.h)。
3. 在启动器六种语言的 `launchers/macos/frontend/l10n/*.json` 添加 `s2arm.controller.driver.<ID>` 名称。
4. 在 `runtime/tests/t_hid_generic.c` 加入正例和易混淆的反例。运行 `make native-test-hid_generic`、`bash tests/macos_native_input_test.sh`、`bash tests/macos_swift_build_test.sh`。实机验收时记录模式、系统报告的名称与 VID/PID，测试按键、摇杆、重连、玩家数及设备支持的体感。

| 输入协议 | 游戏宿主读取方式 |
| --- | --- |
| `S2A_DRIVER_SWITCH_PRO` | 复用 Switch Pro 初始化、完整报告、摇杆校准和六轴解析。 |
| `S2A_DRIVER_GENERIC_HID` | 使用现有 HID 元素与通用键位映射，首次按键后加入。 |

全新报文格式需要在宿主实现协议解析和测试，再将该协议提供给注册表。注册项只描述设备与协议的对应关系。

## 设备身份与多人

设置按 VID、PID 与设备标识保存，优先使用序列号，其次使用非零 LocationID。两者都缺失时使用本次连接的 I/O Registry 条目号，这种设备重连后可能需要重选。

游戏按接入时的设置选择输入源。仅有 HID 的手柄使用 HID 玩家槽；找到唯一对应的系统手柄时在原位置替换输入源，保留顺序表名称。两只同名手柄都选了扩展驱动时，各自的 HID 报告供给一个玩家，系统枚举未完成的手柄也可以加入。若同名组内混用系统和扩展驱动，且无法判定对应关系，则保留系统输入。验收时若看到重复玩家，应同时记录 HID 产品名和 GameController 的名称、类别以便核对。
