import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

private final class UserSessionRunner: JobProcessRunner {
    final class Handle: JobProcessHandle {
        var stops = 0
        func terminate() { stops += 1 }
    }
    struct Job {
        let request: [String: Any]
        let handle: Handle
        let line: (Data) -> Void
        let exit: (Int32) -> Void
        func finish(_ result: [String: Any] = [:], state: String = "completed") {
            line(try! JSONSerialization.data(withJSONObject: ["schema": 1, "taskId": request["taskId"]!, "type": "result", "state": state, "result": result]))
            exit(state == "cancelled" ? 130 : 0)
        }
    }
    var jobs: [Job] = []
    var registry: [String: Any] = ["schema": 1, "revision": 1, "nextId": 3,
        "users": [["id": "01", "name": "用户1", "accountUid": NSNull()],
                  ["id": "02", "name": "Second", "accountUid": String(repeating: "1", count: 32)]]]
    var heldOperations: Set<String> = []
    var saveResult: [String: Any] = ["hasSave": false]
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments.last!))) as! [String: Any]
        let job = Job(request: request, handle: Handle(), line: onLine, exit: onExit)
        jobs.append(job)
        if heldOperations.contains(request["operation"] as? String ?? "") { return job.handle }
        switch request["operation"] as? String {
        case "launch": break // only explicit synthetic exit releases the pair
        case "users", "userUpdate": job.finish(registry)
        case "installCheck": job.finish(["ready": true, "items": []])
        case "saveStatus", "saveBackup", "saveInspect", "saveRestore": job.finish(saveResult)
        default: job.finish()
        }
        return job.handle
    }
}

@MainActor final class UserSessionTests: XCTestCase {
    private var root: URL!
    private var runner: UserSessionRunner!
    private var model: S2ArmLauncherModel!
    private var suite: String!
    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-users-" + UUID().uuidString)
        let python = root.appendingPathComponent("Runtime/python/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        runner = UserSessionRunner()
        suite = "s2arm-user-test-" + UUID().uuidString
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path), runner: runner))
    }
    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func drain() async {
        // Provider finish -> model ingestion -> library refresh -> perform completion.
        for _ in 0..<8 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
    }
    private var launches: [UserSessionRunner.Job] { runner.jobs.filter { $0.request["operation"] as? String == "launch" } }

    func testInputMappingsReadAndSaveCapturedUserNotCurrentSelection() async throws {
        await model.loadUsers()
        let game = "010000000000000A"
        let legacy = root.appendingPathComponent("lib/mappings/\(game).json")
        let second = root.appendingPathComponent("lib/mappings/users/02/\(game).json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        var one = InputConfig.standard; one.deadzone = 0.21
        var two = InputConfig.standard; two.deadzone = 0.32
        try JSONEncoder().encode(one).write(to: legacy)
        try JSONEncoder().encode(two).write(to: second)
        model.selectedUserID = "02"
        XCTAssertEqual(model.loadInput(gameID: game).config.deadzone, 0.32)
        XCTAssertEqual(model.loadInput(gameID: game, userID: "01").config.deadzone, 0.21)
        model.selectedUserID = "01"
        try await model.saveInput(two, gameID: game, userID: "02")
        let saved = try XCTUnwrap(runner.jobs.last { $0.request["operation"] as? String == "saveInput" })
        XCTAssertEqual(saved.request["userId"] as? String, "02")
        XCTAssertEqual(saved.request["gameId"] as? String, game)
        XCTAssertEqual(try JSONDecoder().decode(InputConfig.self, from: Data(contentsOf: legacy)), one)
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(model.loadInput(gameID: game, userID: "02").config, .standard)
        let before = runner.jobs.count
        do { try await model.saveInput(two, gameID: game, userID: "03"); XCTFail("missing user") }
        catch { XCTAssertEqual(runner.jobs.count, before) }
    }

    func testMNGTypesAreReadPerPlayerWithoutLosingHIDSelection() async throws {
        let game = "010000000000000A"
        let dir = root.appendingPathComponent("lib/mappings/mng/\(game)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ value: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent(name))
        }
        try write("input-sources.plist", ["version": 1, "sources": [0, 1, 1, 1]])
        try write("controller-devices.plist", ["version": 1, "ports": (0..<4).map { _ in ["id": "auto", "name": ""] }])
        try write("controller-slots.plist", ["version": 1, "ports": [0, 4, 2, 3].map { ["type": $0, "layout": ""] as [String: Any] }])
        // Works for default user "01" even before loadUsers() is called (LocalPlayers mode).
        XCTAssertNil(model.userRegistry)
        let loadedBeforeRegistry = model.loadInput(gameID: game, userID: "01").config
        XCTAssertEqual(["1", "2", "3", "4"].map { loadedBeforeRegistry.players?[$0]?.type }, [0, 4, 2, 3])
        try await model.saveInput(loadedBeforeRegistry, gameID: game, player: 1)
        let savedPlayer1 = try XCTUnwrap(runner.jobs.last { $0.request["operation"] as? String == "saveInput" })
        let p1Config = try XCTUnwrap(savedPlayer1.request["config"] as? [String: Any])
        XCTAssertNil(p1Config["controller"])
        await model.loadUsers()
        let loaded = model.loadInput(gameID: game, userID: "01").config
        XCTAssertEqual(loaded.players?["2"]?.backend, "nspro-hid")
        XCTAssertEqual(["1", "2", "3", "4"].map { loaded.players?[$0]?.type }, [0, 4, 2, 3])
        XCTAssertEqual(model.loadInput(gameID: game, userID: "02").config, .standard)
        try await model.saveInput(loaded, gameID: game, userID: "01")
        let saved = try XCTUnwrap(runner.jobs.last { $0.request["operation"] as? String == "saveInput" })
        let config = try XCTUnwrap(saved.request["config"] as? [String: Any])
        XCTAssertNil(config["controller"])
        let players = try XCTUnwrap(config["players"] as? [String: [String: Any]])
        XCTAssertEqual(players["2"]?["type"] as? Int, 4)
    }

    func testMNGSourcesAndReservationsSurviveTypeEdit() async throws {
        await model.loadUsers()
        let game = "010000000000000A"
        let dir = root.appendingPathComponent("lib/mappings/mng/\(game)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let token = "session:12345678-1234-1234-1234-123456789ABC"
        let sources = [3, 2, 0, 5]
        let devices = ["auto", "none", "auto", token]
        for (name, doc) in [
            ("input-sources.plist", ["version": 1, "sources": sources] as [String: Any]),
            ("controller-devices.plist", ["version": 1, "ports": devices.map { ["id": $0, "name": ""] }])
        ] {
            try PropertyListSerialization.data(fromPropertyList: doc, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent(name))
        }
        var loaded = model.loadInput(gameID: game, userID: "01").config
        XCTAssertEqual(["1", "2", "3", "4"].map { loaded.players?[$0]?.source }, sources)
        XCTAssertEqual(loaded.players?["2"]?.device, "none")
        XCTAssertEqual(loaded.players?["4"]?.device, token)
        loaded.players?["2"]?.type = 2
        try await model.saveInput(loaded, gameID: game, userID: "01")
        let request = try XCTUnwrap(runner.jobs.last { $0.request["operation"] as? String == "saveInput" })
        let config = try XCTUnwrap(request.request["config"] as? [String: Any])
        let players = try XCTUnwrap(config["players"] as? [String: [String: Any]])
        XCTAssertEqual(["1", "2", "3", "4"].map { players[$0]?["source"] as? Int }, sources)
        XCTAssertEqual(players["4"]?["device"] as? String, token)
    }

    func testPartialMNGSlotsPreserveJSONDeviceAndReportBrokenSources() async throws {
        await model.loadUsers()
        let game = "010000000000000A"
        let dir = root.appendingPathComponent("lib/mappings/mng/\(game)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = InputConfig.standard
        let token = "session:12345678-1234-1234-1234-123456789ABC"
        config.players = ["1": ControllerSelection(device: token, source: 2)]
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent("lib/mappings/\(game).json"))
        let doc: [String: Any] = ["version": 1, "ports": (0..<4).map { _ in ["type": 2, "layout": ""] as [String: Any] }]
        try PropertyListSerialization.data(fromPropertyList: doc, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("controller-slots.plist"))
        let loaded = model.loadInput(gameID: game, userID: "01")
        XCTAssertFalse(loaded.problem)
        XCTAssertEqual(loaded.config.players?["1"]?.device, token)
        XCTAssertEqual(loaded.config.players?["1"]?.source, 2)
        XCTAssertEqual(loaded.config.players?["2"]?.source, 5)
        try Data("broken preferences".utf8).write(to: dir.appendingPathComponent("input-sources.plist"))
        XCTAssertTrue(model.loadInput(gameID: game, userID: "01").problem)
    }

    func testInputRevisionCapturesMissingAndChangedFilesAndTravelsWithSave() async throws {
        await model.loadUsers()
        let game = "010000000000000A"
        let dir = root.appendingPathComponent("lib/mappings/mng/\(game)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = model.loadInput(gameID: game, userID: "01")
        XCTAssertFalse(original.problem)
        XCTAssertEqual(original.revision?.count, 11)
        XCTAssertEqual(original.revision?["controls.txt"], "missing")
        try Data("abc".utf8).write(to: dir.appendingPathComponent("controls.txt"))
        let changed = model.loadInput(gameID: game, userID: "01")
        XCTAssertEqual(changed.revision?["controls.txt"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNotEqual(original.revision, changed.revision)
        XCTAssertEqual(model.loadInput(gameID: game, userID: "02").revision?["controls.txt"], "missing")
        try await model.saveInput(original.config, gameID: game, userID: "01", revision: original.revision)
        let request = try XCTUnwrap(runner.jobs.last { $0.request["operation"] as? String == "saveInput" })
        // The original snapshot is sent, never a fresh revision that would authorize stale edits.
        XCTAssertEqual(request.request["inputRevision"] as? [String: String], original.revision)
    }

    func testUserPairsKeepIndependentUIResultsAndStopWaitsForOwnedExit() async throws {
        await model.loadUsers()
        XCTAssertEqual(model.selectedUserID, "01")
        let game = GameSummary(id: "0100A", name: "Fixture")
        model.play(game, uiLanguage: "en")
        model.selectedUserID = "02"
        model.play(game, uiLanguage: "en")
        XCTAssertEqual(launches.map { $0.request["userId"] as? String }, ["01", "02"])
        XCTAssertEqual(model.playSessions.map(\.user.id), ["01", "02"])
        XCTAssertNil(model.playSession)
        model.play(game, uiLanguage: "en")
        XCTAssertEqual(launches.count, 2)
        XCTAssertNotNil(model.actionError(for: game.id))
        let first = model.playSessions[0].id
        model.stopPlay(id: first)
        XCTAssertEqual(launches.map(\.handle.stops), [1, 0])
        XCTAssertTrue(model.isPlaying(gameID: game.id, userID: "01"))
        launches[0].finish(state: "cancelled")
        await drain()
        XCTAssertFalse(model.isPlaying(gameID: game.id, userID: "01"))
        XCTAssertTrue(model.isPlaying(gameID: game.id, userID: "02"))
        XCTAssertTrue(model.hasRunningGames)
        model.dismissPlayResult(id: first)
        model.selectedUserID = "01"
        model.play(game, uiLanguage: nil)
        XCTAssertEqual(launches.count, 3)
        XCTAssertFalse(model.stopPlay(taskID: launches[0].request["taskId"] as! String))
        XCTAssertEqual(launches[2].handle.stops, 0)
        launches[1].finish(); launches[2].finish()
        await drain()
        XCTAssertFalse(model.hasRunningGames)
        XCTAssertEqual(model.playSessions.count, 2)
    }

    func testSaveRequestsStayWithCapturedUserAfterSelectionAndRename() async throws {
        await model.loadUsers()
        model.selectedUserID = "02"
        let target = SaveTarget(gameID: "0100A", user: try XCTUnwrap(model.selectedUser))
        model.selectedUserID = "01"
        _ = try await model.saveStatus(target.gameID, userID: target.user.id)
        _ = try await model.saveBackup(target.gameID, userID: target.user.id, to: root.appendingPathComponent("fixture.s2asave"))
        let binding = String(repeating: "a", count: 64)
        runner.saveResult = ["manifest": ["game": ["name": "Fixture", "version": 1]], "archiveSha256": "sha", "targetFingerprint": "fingerprint", "previewLibraryId": "fixture", "previewUserBinding": binding]
        let preview = try await model.saveInspect(target.gameID, userID: target.user.id, source: root.appendingPathComponent("synthetic.zip"))
        await model.updateUser(id: "02", name: "Renamed")
        _ = try await model.saveRestore(target.gameID, userID: target.user.id, preview: preview)
        let saves = runner.jobs.filter { ($0.request["operation"] as? String)?.hasPrefix("save") == true }
        XCTAssertEqual(saves.count, 4)
        XCTAssertEqual(saves.compactMap { $0.request["userId"] as? String }, Array(repeating: "02", count: 4))
        XCTAssertEqual(saves.last?.request["previewUserBinding"] as? String, binding)
        XCTAssertEqual(target.user.name, "Second")
        let rename = try XCTUnwrap(runner.jobs.first { $0.request["operation"] as? String == "userUpdate" })
        XCTAssertEqual(rename.request["revision"] as? Int, 1)
        XCTAssertEqual(rename.request["userId"] as? String, "02")
    }

    func testControlCancelsExactTaskAndReportsAllSessions() async throws {
        await model.loadUsers()
        let game = GameSummary(id: "0100A", name: "Fixture")
        model.play(game, uiLanguage: nil, userID: "01")
        model.play(game, uiLanguage: nil, userID: "02")
        let control = try S2ArmControl(model: model) { XCTFail($0) }
        defer { control.stop() }
        let state = control.state()
        let sessions = try XCTUnwrap(state["playSessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.compactMap { $0["userId"] as? String }, ["01", "02"])
        XCTAssertTrue(state["playSession"] is NSNull)
        let unknown = await control.handle(ControlRequest(method: "POST", path: "/cancel", headers: [:], body: ["taskId": "stale"]))
        XCTAssertEqual(unknown.code, 400)
        XCTAssertEqual(launches.map(\.handle.stops), [0, 0])
        let secondID = launches[1].request["taskId"] as! String
        let reply = await control.handle(ControlRequest(method: "POST", path: "/cancel", headers: [:], body: ["taskId": secondID]))
        XCTAssertEqual(reply.code, 200)
        XCTAssertEqual(launches.map(\.handle.stops), [0, 1])
        XCTAssertTrue(model.hasRunningGames)
        launches[0].finish(); launches[1].finish(state: "cancelled")
        await drain()
    }

    func testMobileTaskAllowsLocalPlayAndSaveWithoutLosingTaskOrCancelTarget() async throws {
        await model.loadUsers()
        let game = GameSummary(id: "0100A", name: "Fixture")
        runner.heldOperations = ["install"]
        model.checkInstall(game.id)
        for _ in 0..<100 where !model.installAllowed(game.id) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.installAllowed(game.id))
        model.install(game)
        await drain()
        for _ in 0..<100 where !runner.jobs.contains(where: { $0.request["operation"] as? String == "install" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let mobile = try XCTUnwrap(runner.jobs.first { $0.request["operation"] as? String == "install" }, model.phoneSession?.message ?? model.actionError(for: game.id) ?? "no session")
        XCTAssertTrue(model.phoneBusy)
        XCTAssertFalse(model.mainBusy)
        model.goToLibrary()
        XCTAssertFalse(model.localStateBlocked(gameID: game.id, userID: "01"))
        _ = try await model.saveStatus(game.id, userID: "01")
        XCTAssertEqual(model.phoneSession?.kind, .install)
        model.play(game, uiLanguage: nil, userID: "01")
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(model.localStateBlocked(gameID: game.id, userID: "01", save: true))
        XCTAssertFalse(model.localStateBlocked(gameID: game.id, userID: "02", save: true))
        _ = try await model.saveStatus(game.id, userID: "02")
        XCTAssertEqual(mobile.handle.stops, 0)
        XCTAssertEqual(launches[0].handle.stops, 0)
        model.stopPhone()
        await drain()
        XCTAssertEqual(mobile.handle.stops, 1)
        XCTAssertEqual(launches[0].handle.stops, 0)
        XCTAssertTrue(model.phoneBusy) // cancellation isn't proof that worker exited
        mobile.finish(state: "cancelled"); launches[0].finish()
        await drain()
        XCTAssertFalse(model.phoneBusy)
        XCTAssertFalse(model.busy)
    }

    func testPhoneQueueRunsSequentiallyAndAllowsParallelExportOfOtherGame() async throws {
        await model.loadUsers()
        let gameA = GameSummary(id: "0100A", name: "Game A")
        let gameB = GameSummary(id: "0100B", name: "Game B")
        runner.heldOperations = ["install", "installRemove"]
        model.checkInstall(gameA.id)
        for _ in 0..<100 where !model.installAllowed(gameA.id) { try await Task.sleep(nanoseconds: 10_000_000) }
        model.install(gameA)
        await drain()
        for _ in 0..<100 where !runner.jobs.contains(where: { $0.request["operation"] as? String == "install" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.phoneBusy)
        XCTAssertFalse(model.mainBusy)
        XCTAssertTrue(model.isPhoneJobActive(gameID: gameA.id))
        XCTAssertFalse(model.phoneOperationBlocked(kind: .removeFromPhone, gameID: gameB.id))

        model.removeFromPhone(gameB)
        await drain()
        XCTAssertEqual(model.phoneQueue.count, 1)
        XCTAssertEqual(model.phoneQueue.first?.game.id, gameB.id)
        XCTAssertTrue(model.isPhoneJobQueued(gameID: gameB.id))

        let first = try XCTUnwrap(runner.jobs.first { $0.request["operation"] as? String == "install" })
        first.finish()
        await drain()
        for _ in 0..<100 where !runner.jobs.contains(where: { $0.request["operation"] as? String == "installRemove" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.phoneQueue.isEmpty)
        XCTAssertEqual(model.phoneSession?.gameID, gameB.id)
        XCTAssertEqual(model.phoneSession?.kind, .installRemove)
        let second = try XCTUnwrap(runner.jobs.first { $0.request["operation"] as? String == "installRemove" })
        second.finish()
        await drain()
        XCTAssertFalse(model.phoneBusy)
    }

    func testSaveReservationBlocksOnlySamePairAndSurvivesUserSwitch() async throws {
        await model.loadUsers()
        let game = GameSummary(id: "0100A", name: "Fixture")
        runner.heldOperations = ["saveStatus"]
        let pending = Task { try await model.saveStatus(game.id, userID: "01") }
        await drain()
        XCTAssertEqual(model.saveOperations.count, 1)
        XCTAssertTrue(model.localStateBlocked(gameID: game.id, userID: "01"))
        model.play(game, uiLanguage: nil, userID: "01")
        XCTAssertTrue(launches.isEmpty)
        model.play(game, uiLanguage: nil, userID: "02")
        XCTAssertEqual(launches.count, 1)
        model.selectedUserID = "02"
        let save = try XCTUnwrap(runner.jobs.first { $0.request["operation"] as? String == "saveStatus" })
        save.finish(["hasSave": false])
        _ = try await pending.value
        XCTAssertTrue(model.saveOperations.isEmpty)
        launches[0].finish(); await drain()
    }

    private func heldVerify(_ game: GameSummary) async throws -> UserSessionRunner.Job {
        let previousCount = runner.jobs.filter { $0.request["operation"] as? String == "verify" }.count
        runner.heldOperations.insert("verify")
        model.verifyGame(game)
        for _ in 0..<100 {
            let jobs = runner.jobs.filter { $0.request["operation"] as? String == "verify" }
            if jobs.count > previousCount { return jobs.last! }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw XCTUnwrapError.missingWorker
    }

    private enum XCTUnwrapError: Error { case missingWorker }

    func testBackgroundResultDoesNotReleaseOwnershipBeforeExit() async throws {
        let game = GameSummary(id: "0100A", name: "Fixture")
        let job = try await heldVerify(game)
        let owner = try XCTUnwrap(model.session?.id)
        let taskID = try XCTUnwrap(job.request["taskId"] as? String)
        job.line(try JSONSerialization.data(withJSONObject: ["schema": 1, "taskId": taskID, "type": "stage", "message": "working"]))
        await drain()
        job.line(try JSONSerialization.data(withJSONObject: ["schema": 1, "taskId": taskID, "type": "result", "state": "completed", "result": [:]]))
        await drain()
        model.goToLibrary()
        XCTAssertTrue(model.busy)
        XCTAssertNotNil(model.backgroundOperations[owner])
        XCTAssertEqual(model.session?.taskID, taskID)
        XCTAssertTrue(model.localStateBlocked(gameID: game.id, userID: "01"))
        XCTAssertTrue(model.stopBackground(taskID: taskID))
        XCTAssertTrue(model.stopBackground(id: owner)) // repeated cancel is idempotent
        await drain()
        XCTAssertEqual(job.handle.stops, 1)
        XCTAssertTrue(model.busy)
        job.exit(0)
        await drain()
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.backgroundOperations.isEmpty)
        XCTAssertFalse(model.stopBackground(id: owner))
    }

    func testStaleBackgroundEventsAndCancelCannotAffectReplacement() async throws {
        let game = GameSummary(id: "0100A", name: "Fixture")
        let first = try await heldVerify(game)
        let oldOwner = try XCTUnwrap(model.session?.id)
        let oldTask = try XCTUnwrap(first.request["taskId"] as? String)
        first.finish()
        await drain()
        let second = try await heldVerify(GameSummary(id: "0100B", name: "Second"))
        let newOwner = try XCTUnwrap(model.session?.id)
        XCTAssertNotEqual(oldOwner, newOwner)
        let before = model.session
        // Simulate a delayed producer callback from the retired operation.
        first.line(try JSONSerialization.data(withJSONObject: ["schema": 1, "taskId": oldTask, "type": "stage", "message": "stale"]))
        await drain()
        XCTAssertEqual(model.session, before)
        XCTAssertFalse(model.stopBackground(id: oldOwner))
        XCTAssertFalse(model.stopBackground(taskID: oldTask))
        XCTAssertEqual(second.handle.stops, 0)
        XCTAssertEqual(Set(model.backgroundOperations.keys), [newOwner])
        XCTAssertFalse(model.localStateBlocked(gameID: "0100A", userID: "01"))
        XCTAssertTrue(model.localStateBlocked(gameID: "0100B", userID: "01"))
        XCTAssertTrue(model.stopBackground(id: newOwner))
        await drain()
        second.finish(state: "cancelled")
        await drain()
        XCTAssertFalse(model.busy)
    }

    func testInvalidRegistryCannotInventFallbackUserOrLaunch() async {
        runner.registry = [:]
        await model.loadUsers()
        XCTAssertNil(model.selectedUser)
        XCTAssertNotNil(model.usersError)
        model.play(GameSummary(id: "0100A", name: "Fixture"), uiLanguage: nil)
        XCTAssertTrue(launches.isEmpty)
        XCTAssertTrue(model.playSessions.isEmpty)
    }
}
