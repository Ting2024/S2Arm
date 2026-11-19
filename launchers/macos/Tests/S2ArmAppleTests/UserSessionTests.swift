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
