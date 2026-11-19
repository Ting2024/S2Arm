# Mac ↔ iOS 局域网发现修复（2026-11-09，待双设备验收）

## 已确认的原因

本机已安装宿主和暗黑 3 本次日志交叉确认：

- 游戏初始化 LDN 的模式是 `Disabled`。
- Mac 提示 `局域网发现不可用（原因位 1）`，含义是未登记发现 provider。
- 已安装 Mac 宿主的 `_s2a_ldn_lan_provider` 只有 `mov x0, #0; ret`。
- Mac 游戏宿主与游戏当前副本的 Info.plist 都没有 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`。
- 源码中 iOS 编译 `ios/ldn_lan.m`，Mac 前端构建没有这个文件，使用 host_main.c 的空 provider。

Mac 没有发布/浏览，且共享服务据此保持联机禁用，足以造成双方互相搜不到。
这不是旧项目的「已进房后掉线」问题；不据此排除网络隔离、权限、防火墙、版本不一致等其他条件。

## 修复

- `launchers/macos/build.mk` 在有主线程 run loop 的 Mac 游戏前端链接现有 `ios/ldn_lan.m`。
  不复制发现协议，不改 iOS 选举规则，不为某款游戏特判。
- `macos/lan_permission.m` 提供 AppKit 适配：继续系统本地网络授权流程；失败记录数值域/代码，
  用非阻塞 sheet 提醒检查权限/防火墙。不把所有 Bonjour 错误说成权限拒绝。
- `pack/jobs/build.py` 给新构建的游戏宿主写用途说明和 `_s2arm-ldn._tcp` 声明。
- `launchers/macos/build_app.py` 给可能承担子进程权限归属的启动器加相同声明。
- 无 Mac 前端的命令行宿主仍不宣称支持 Bonjour，避免没有主 run loop 时假成功。

## 验证及限制

全部使用合成 fixture；无游戏启动、无正式配置/存档写入、无 App 安装、无 git 提交。

| 检查 | 结果 |
| --- | --- |
| 构建接线和游戏包声明修复前 | 各 1 项失败，日志在 `build/macos/lan-tests/*-red.log` |
| Mac 构建/启动器声明 | 3/3 通过（Make 解析 + 源码声明检查） |
| 真实临时签名 App 生成及宿主缓存 | 6/6 通过 |
| 真实 provider + Mac 权限适配链接 | 通过：ABI、端口、重复 start、busy、stop/restart、旧队列回调不复活 |
| 链接负对照 | 去掉 provider、保留宿主弱占位，断言失败（exit -6） |
| Apple 选举委托 / 平台无关选举 | 原有测试通过 |
| iOS 权限模式回归 | 正向/负对照及原有源码约束通过；非 UIKit 真机验证 |
| Objective-C 编译检查 | provider 与 Mac 适配 `-Wall -Wextra -Werror` 通过 |
| 完整游戏宿主 | 已完成：.NET 10.0.403、NativeAOT、Metal/NVN/GL/翻译库完整链接，最低 macOS 15.0 |
| Mac↔iOS 真机互搜、进房 | 未执行 |

用户随后授权下载依赖并提供临时代理，已完成完整构建：

- SDK 安装在忽略的 `build/toolchains/dotnet`，没有改系统 .NET / 代理设置。
- NativeAOT 服务库成功编译；VPX、dav1d 使用已安装签名 S2Arm 自带的预编库，
  经项目原有流程核对构建键和 SHA-256，不跳过校验。尝试补装 Meson/ripgrep 被工具权限拒绝，未继续安装。
- 完整候选包：`build/macos/lan-package/tools/mac-host/lan-fix/S2ArmGame.app`。
  通过原有 `compile_host` 包装逻辑生成；使用本机已有 Apple Development 身份签名，
  App 和地址护栏 dylib 均通过 `codesign --verify --strict`，没有新增账户或修改描述文件。
- 已验证成品中实际定义了 `s2a_ldn_lan_provider`、`S2ALdnLan`、`S2A_LdnSetServer`、`S2A_Init`；
  主程序 SHA-256 为 `f2f4e5b9cd35f586972d2fa9d04179b2ff245036eb8cdb223e600fc583a10d7b`。
- 动态库依赖只有系统框架/系统库和包内 `libs2a_vaguard.dylib`；没有依赖构建目录内的动态库。
- 服务层 7 个独立测试模式通过：provider lifecycle、synthetic application（17/17）、
  shutdown guest/process、room count、IP wrap、proxy wake。均为合成测试及临时端口，未使用正式存档。
- 构建存在原有编译告警，以及 NativeAOT 合并对象清理后 dSYM 找不到中间对象的告警；
  这影响相应调试信息完整性，不是宿主链接失败。
- 成品检查记录在 `build/macos/lan-tests/host-artifact.json`，各阶段日志同目录。
  未安装候选包、未启动游戏、未执行 Mac↔iOS 双设备验收。

`contrib_check.sh` 要求已提交的干净工作树，与用户不提交要求冲突，未宣称完整门禁通过。

## 验收与部署边界

修复必须进 **游戏宿主二进制及其签名包**，仅更新启动器界面无效；库内已经发布的游戏副本也不会自动变成新宿主。
发布构建会按源码指纹生成新的宿主，不能只给旧二进制添加 plist 就宣称修好。

后续先在独立测试副本使用复制存档/缓存，允许系统本地网络权限；两端同一游戏版本，进入本地联机菜单。
期望 Mac 不再出现原因位 1，出现发布/浏览与选中中继事件，然后验证双向建房、搜房、加入。
若仍搜不到，按发布/解析错误、所选中继及共享服务连接日志分层定位；不延长超时或关闭校验掩盖失败。
