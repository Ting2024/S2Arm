// S2Arm（不是上游文件）：键位设置（InputSettingsSheet）的数据与读写。键位格式同旧启动器 Models.swift 的 InputConfig
// （作业层 pack/jobs/library.py validate_input 的契约：schema 1、keyboard / mouse / gamepad / axes / mouseOptions / deadzone），
// 按玩家保存（键位设置里选玩家 1–4）：玩家 1 读这款文件夹里的 input.json → 私有目录 default-input.json → 标准键位（同起局 build.py 的取法）；
// 玩家 2–4 读这款文件夹里的 input-pN.json → 标准键位；同时支持按用户读取 mappings/<id>.json / mappings/users/<uid>/<id>.json 与 MNG 1P–4P 状态。
// 写：saveInput 作业（作业层校验后原子写），下次开始游戏时生效。
import Foundation
import CryptoKit
import S2ArmAppleAdapter

struct KeyBinding: Codable, Equatable { var code: Int; var modifiers: Int = 0 }
struct AxisBinding: Codable, Equatable { var source: String; var invert: Bool = false }
struct MouseOptions: Codable, Equatable {
    var mode = "camera"; var sensitivityX = 1.0; var sensitivityY = 1.0; var invertX = false; var invertY = false; var recenter = true
}
// 契约允许省略 modifiers / invert 等：按宿主的缺省解，不悄悄换成别的键位。
extension KeyBinding {
    enum CodingKeys: String, CodingKey { case code, modifiers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(Int.self, forKey: .code); modifiers = try c.decodeIfPresent(Int.self, forKey: .modifiers) ?? 0
    }
}
extension AxisBinding {
    enum CodingKeys: String, CodingKey { case source, invert }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source); invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}
extension MouseOptions {
    enum CodingKeys: String, CodingKey { case mode, sensitivityX, sensitivityY, invertX, invertY, recenter }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(String.self, forKey: .mode); sensitivityX = try c.decode(Double.self, forKey: .sensitivityX); sensitivityY = try c.decode(Double.self, forKey: .sensitivityY)
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? false; invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false; recenter = try c.decodeIfPresent(Bool.self, forKey: .recenter) ?? true
    }
}

struct ControllerSelection: Codable, Equatable {
    var backend = "system"
    var device = ""
    var type: Int? = nil
    var source: Int? = nil
}
struct InputConfig: Codable, Equatable {
    // Optional keeps existing schema-1 files readable without migration.
    var controller: ControllerSelection? = nil
    var players: [String: ControllerSelection]? = nil
    var schema = 1; var keyboard: [String: KeyBinding]; var mouse: [String: Int]; var gamepad: [String: String]; var axes: [String: AxisBinding]
    var mouseOptions: MouseOptions = .init(); var deadzone = 0.15
    var backButtons: [String: String]?
    static let targets = ["A","B","X","Y","LS","RS","L","R","ZL","ZR","PLUS","MINUS","LEFT","UP","RIGHT","DOWN","LS_UP","LS_DOWN","LS_LEFT","LS_RIGHT","RS_UP","RS_DOWN","RS_LEFT","RS_RIGHT"]
    static let padCodes = ["east","south","north","west","leftStick","rightStick","leftShoulder","rightShoulder","leftTrigger","rightTrigger","menu","options","dpadLeft","dpadUp","dpadRight","dpadDown"]
    static let axisTargets = ["LX","LY","RX","RY"]
    static let axisSources = ["leftX","leftY","rightX","rightY"]
    static var standard: InputConfig {
        let keys = ["A":14,"B":56,"X":49,"L":12,"R":5,"ZR":15,"LS":59,"RS":8,"PLUS":48,"MINUS":46,"LEFT":123,"UP":126,"RIGHT":124,"DOWN":125,"LS_UP":13,"LS_DOWN":1,"LS_LEFT":0,"LS_RIGHT":2]
        return .init(keyboard: keys.mapValues { KeyBinding(code: $0) }, mouse: ["Y":0,"ZL":1],
                     gamepad: Dictionary(uniqueKeysWithValues: zip(targets.prefix(16), padCodes).map { ($0, $1) }),
                     axes: ["LX":.init(source:"leftX"),"LY":.init(source:"leftY"),"RX":.init(source:"rightX"),"RY":.init(source:"rightY")])
    }
    /// 三类玩法预设（同旧启动器 F06）：都以标准键位为底，只改这类玩法最常用的键，其余照旧；套用后仍可逐项改再保存。
    enum Preset: String, CaseIterable { case action, racing, turnBased }
    static func preset(_ p: Preset) -> InputConfig {
        var c = standard
        switch p {
        case .action:   // 2 主攻击、空格闪避、E 交互、Q 道具、T / 6 肩键、Ctrl 蹲、C 锁定；右键视角、左键 ZL、中键 ZR
            c.keyboard.merge(["A":.init(code:19),"B":.init(code:49),"X":.init(code:14),"Y":.init(code:12),"L":.init(code:17),"R":.init(code:22),
                              "LS":.init(code:59),"RS":.init(code:8)], uniquingKeysWith: { $1 })
            c.mouse = ["Y":0, "ZL":1, "ZR":2]
            c.mouseOptions.mode = "camera"; c.mouseOptions.sensitivityX = 1.2; c.mouseOptions.sensitivityY = 1.2; c.mouseOptions.recenter = true; c.deadzone = 0.15
        case .racing:   // 空格加速、Shift 刹车、3 道具、E 备用油门、T / 6 换挡、C 换视角；视角灵敏度低、不回中
            c.keyboard.merge(["A":.init(code:49),"B":.init(code:56),"X":.init(code:20),"ZR":.init(code:14),"L":.init(code:17),"R":.init(code:22),
                              "RS":.init(code:8)], uniquingKeysWith: { $1 })
            c.mouse = ["Y":0]
            c.mouseOptions.mode = "camera"; c.mouseOptions.sensitivityX = 0.6; c.mouseOptions.sensitivityY = 0.6; c.mouseOptions.recenter = false; c.deadzone = 0.2
        case .turnBased:   // Return 确认、Esc 取消、Tab 菜单、删除返回、6 快捷栏、2 / 3 翻页、空格换单位；鼠标不转视角
            c.keyboard.merge(["A":.init(code:36),"B":.init(code:53),"PLUS":.init(code:48),"MINUS":.init(code:51),"X":.init(code:22),"L":.init(code:19),
                              "R":.init(code:20),"LS":.init(code:49)], uniquingKeysWith: { $1 })
            c.mouse = [:]
            c.mouseOptions.mode = "off"; c.deadzone = 0.25
        }
        return c
    }

    /// 一处重复绑定：哪类输入（keyboard / mouse / gamepad / axes）、哪两个键。作业层 validate_input 同样拒收重复。
    struct Conflict: Equatable { let kind: String; let first: String; let second: String }
    var conflicts: [Conflict] {
        func dupes<V: Hashable>(_ kind: String, _ map: [String: V]) -> [Conflict] {
            var seen: [V: String] = [:]; var out: [Conflict] = []
            for target in map.keys.sorted() {
                let v = map[target]!
                if let old = seen[v] { out.append(.init(kind: kind, first: old, second: target)) } else { seen[v] = target }
            }
            return out
        }
        return dupes("keyboard", keyboard.mapValues { "\($0.code):\($0.modifiers)" }) + dupes("mouse", mouse) + dupes("gamepad", gamepad)
            + dupes("axes", axes.mapValues(\.source))
    }
    var conflictingTargets: Set<String> { Set(conflicts.filter { $0.kind != "axes" }.flatMap { [$0.first, $0.second] }) }

    mutating func restoreTarget(_ target: String, from original: InputConfig) {
        keyboard[target] = original.keyboard[target]; mouse[target] = original.mouse[target]; gamepad[target] = original.gamepad[target]
    }
}

/// 读到的键位与出处：读不懂已存的文件时 problem 为真（先显示默认键位，保存会覆盖它）；
///   inherited 为真是玩家 2–4 没存过自己的键位、沿用玩家 1 的那份（与起局一致，保存后单独生效）。
///   revision 覆盖 JSON 与原生输入文件快照，防止并发改动或损坏快照被覆盖。
struct LoadedInput {
    let config: InputConfig
    let problem: Bool
    var inherited = false
    var revision: [String: String]? = nil
}

extension S2ArmLauncherModel {
    /// 这款现在的键位：玩家 1 = 这款文件夹里的 input.json，没有就用私有目录的 default-input.json，再没有用标准键位（同起局 build.py 的取法）；
    ///   玩家 2–4 = 这款文件夹里的 input-pN.json（键位设置按玩家保存），没存过 / 存坏了就沿用玩家 1 的键位——
    ///   起局时这几位没存就是照玩家 1 的那份进游戏（build.py 不带、宿主落回全局映射），弹窗显示要跟实际玩的一致。
    /// 游戏库结构 v3 起键位在每款自己的文件夹（作业层 layout 把旧的 mappings/<号>.json 搬进去了）；原先还读 mappings/ 永远读不到，存过的键位重开显示成默认
    func loadInput(gameID: String, player: Int) -> LoadedInput {
        let env = provider.client.environment
        var problem = false
        let file = player == 1 ? "input.json" : "input-p\(player).json"
        if let path = games.first(where: { $0.id == gameID })?.location.file(file) {
            if let data = try? Data(contentsOf: path) {
                if let config = try? JSONDecoder().decode(InputConfig.self, from: data) { return LoadedInput(config: config, problem: false) }
                problem = true
            }
        }
        if player == 1, !env.library.isEmpty {
            let mappingPath = URL(fileURLWithPath: env.library).appendingPathComponent("mappings/\(gameID).json")
            if let data = try? Data(contentsOf: mappingPath) {
                if let config = try? JSONDecoder().decode(InputConfig.self, from: data) { return LoadedInput(config: config, problem: problem) }
                problem = true
            }
        }
        if player > 1 { return LoadedInput(config: loadInput(gameID: gameID, player: 1).config, problem: problem, inherited: true) }
        if let data = try? Data(contentsOf: env.privateRoot.appendingPathComponent("default-input.json")),
           let config = try? JSONDecoder().decode(InputConfig.self, from: data) { return LoadedInput(config: config, problem: problem) }
        return LoadedInput(config: .standard, problem: problem)
    }

    private func normalizedInputConfig(_ config: InputConfig) -> InputConfig {
        var normalized = config
        if var players = normalized.players {
            for k in ["1", "2", "3", "4"] where players[k] == nil {
                players[k] = k == "1" ? (normalized.controller ?? ControllerSelection(backend: "system", device: "")) : ControllerSelection(backend: "disabled", device: "")
            }
            normalized.players = players
            normalized.controller = nil
        }
        return normalized
    }

    /// 存这款的键位（saveInput 作业，player 1–4：1 = input.json，2–4 = input-pN.json，作业层校验后原子写）。
    /// 没配游戏库不起作业；作业层拒收抛 JobFailure，message 是作业层原句。
    func saveInput(_ config: InputConfig, gameID: String, player: Int) async throws {
        guard !provider.client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        let normalized = normalizedInputConfig(config)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(normalized))
        _ = try await provider.client.perform("saveInput", extra: ["config": object, "gameId": gameID, "player": player])
    }

    private func inputRevision(gameID: String, user: String) throws -> [String: String] {
        let env = provider.client.environment
        let prefix = user == "01" ? "mappings" : "mappings/users/\(user)"
        let library = URL(fileURLWithPath: env.library)
        let root = library.appendingPathComponent("\(prefix)/mng/\(gameID)")
        var paths = ["game": library.appendingPathComponent("\(prefix)/\(gameID).json"),
                     "default": env.privateRoot.appendingPathComponent("default-input.json")]
        // Matches users.MNG_INPUT_FILES; changes to non-visible mappings also invalidate a stale panel.
        for name in ["controls.txt", "controller-type.txt", "mouse.txt", "controller-slots.plist",
                     "controller-devices.plist", "input-sources.plist", "keyboard-slots.plist",
                     "physical-keyboards.plist", "stick-bindings.plist"] {
            paths[name] = root.appendingPathComponent(name)
        }
        return try paths.mapValues { path in
            do { return SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined() }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return "missing"
            }
        }
    }

    private func isAdmittedInputUser(_ user: String) -> Bool {
        if let registry = userRegistry {
            return registry.users.contains { $0.id == user }
        }
        return usersError == nil && user == "01"
    }

    /// 捕获用户的游戏键位；不借用另一用户的游戏映射，并同步读取游戏内 MNG 1P–4P 状态。
    func loadInput(gameID: String, userID: String? = nil) -> LoadedInput {
        let user = userID ?? selectedUserID
        guard isAdmittedInputUser(user) else {
            return LoadedInput(config: .standard, problem: true)
        }
        let env = provider.client.environment
        let revision = try? inputRevision(gameID: gameID, user: user)
        var problem = revision == nil
        var baseConfig: InputConfig?
        if !env.library.isEmpty {
            let relative = user == "01" ? "mappings/\(gameID).json" : "mappings/users/\(user)/\(gameID).json"
            let path = URL(fileURLWithPath: env.library).appendingPathComponent(relative)
            if let data = try? Data(contentsOf: path) {
                if let config = try? JSONDecoder().decode(InputConfig.self, from: data) {
                    baseConfig = config
                } else {
                    problem = true
                }
            }
        }
        if baseConfig == nil, user == "01",
           let path = games.first(where: { $0.id == gameID })?.location.file("input.json"),
           let data = try? Data(contentsOf: path),
           let config = try? JSONDecoder().decode(InputConfig.self, from: data) {
            baseConfig = config
        }
        if baseConfig == nil,
           let data = try? Data(contentsOf: env.privateRoot.appendingPathComponent("default-input.json")),
           let config = try? JSONDecoder().decode(InputConfig.self, from: data) {
            baseConfig = config
        }
        var result = baseConfig ?? .standard
        if !env.library.isEmpty {
            let mngRel = user == "01" ? "mappings/mng/\(gameID)" : "mappings/users/\(user)/mng/\(gameID)"
            let mngDir = URL(fileURLWithPath: env.library).appendingPathComponent(mngRel)
            let srcURL = mngDir.appendingPathComponent("input-sources.plist")
            let devURL = mngDir.appendingPathComponent("controller-devices.plist")
            func document(_ url: URL, field: String) -> [Any]? {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                guard let doc = NSDictionary(contentsOf: url), doc["version"] as? Int == 1,
                      let values = doc[field] as? [Any], values.count == 4 else {
                    problem = true; return nil
                }
                return values
            }
            func integer(_ value: Any?) -> Int? {
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue == Double(n.intValue) else { return nil }
                return n.intValue
            }
            let rawSources = document(srcURL, field: "sources")
            let rawPorts = document(devURL, field: "ports")
            let rawSlots = document(mngDir.appendingPathComponent("controller-slots.plist"), field: "ports")
            let sources = rawSources?.compactMap { integer($0) }
            let ports = rawPorts as? [[String: Any]]
            let slots = rawSlots as? [[String: Any]]
            if let sources, sources.count != 4 || !sources.enumerated().allSatisfy({
                ($0.offset == 0 ? [0, 1, 2, 3, 5] : [0, 1, 2, 5]).contains($0.element)
            }) { problem = true }
            if rawPorts != nil {
                if let ports {
                    var reserved = Set<String>()
                    for port in ports {
                        guard let id = port["id"] as? String, let name = port["name"] as? String,
                              name.count <= 512 else { problem = true; continue }
                        if id != "auto" && id != "none" {
                            if !id.hasPrefix("session:") || UUID(uuidString: String(id.dropFirst(8))) == nil ||
                                !reserved.insert(id.lowercased()).inserted { problem = true }
                        }
                    }
                } else { problem = true }
            }
            if rawSlots != nil && (slots == nil || !slots!.allSatisfy({
                guard let type = integer($0["type"]) else { return false }
                return (0...4).contains(type) && $0["layout"] is String
            })) { problem = true }
            // Never overlay partially validated documents or invent missing devices.
            if !problem && (sources != nil || ports != nil || slots != nil) {
                var players = result.players ?? [
                    "1": result.controller ?? ControllerSelection(backend: "system", device: ""),
                    "2": ControllerSelection(backend: "disabled", device: ""),
                    "3": ControllerSelection(backend: "disabled", device: ""),
                    "4": ControllerSelection(backend: "disabled", device: "")
                ]
                for i in 0..<4 {
                    let key = "\(i + 1)"
                    var selection = players[key] ?? ControllerSelection(backend: i == 0 ? "system" : "disabled")
                    let source = sources?[i] ?? selection.source ?? (selection.backend == "disabled" ? (i == 0 ? 2 : 5) : (i == 0 ? 0 : 1))
                    let type = slots.flatMap { integer($0[i]["type"]) }
                        ?? selection.type ?? (selection.backend == "nspro-hid" ? 4 : 0)
                    selection.type = type
                    selection.source = source
                    selection.backend = type == 4 ? "nspro-hid" : "system"
                    if let id = ports?[i]["id"] as? String { selection.device = id == "auto" ? "" : id }
                    players[key] = selection
                }
                result.players = players
                result.controller = players["1"]
            }
        }
        if revision != (try? inputRevision(gameID: gameID, user: user)) { problem = true }
        return LoadedInput(config: result, problem: problem, revision: revision)
    }

    /// 存这款的键位（saveInput 作业）。没配游戏库不起作业；作业层拒收抛 JobFailure，message 是作业层原句。
    func saveInput(_ config: InputConfig, gameID: String, userID: String? = nil, revision: [String: String]? = nil) async throws {
        let user = userID ?? selectedUserID
        guard isAdmittedInputUser(user) else {
            throw JobClientError("所选用户不存在，请刷新用户列表。")
        }
        guard !provider.client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        let normalized = normalizedInputConfig(config)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(normalized))
        var extra: [String: Any] = ["config": object, "gameId": gameID, "userId": user]
        if let revision { extra["inputRevision"] = revision }
        _ = try await provider.client.perform("saveInput", extra: extra)
    }
}
