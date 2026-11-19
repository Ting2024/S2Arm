import Foundation
import XCTest
@testable import S2ArmAppleAdapter

private final class RegistrationRunner: JobProcessRunner {
    final class Handle: JobProcessHandle {
        var stops = 0
        func terminate() { stops += 1 }
    }
    let handle = Handle()
    var beforeReturn: (([String: Any], @escaping (Int32) -> Void) throws -> Void)?
    var exit: ((Int32) -> Void)?
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments.last!))) as! [String: Any]
        exit = onExit
        try beforeReturn?(request, onExit)
        return handle
    }
}

final class PlayOwnershipTests: XCTestCase {
    func testFinishBeforeRegistrationNeverResurrectsAndPairCanBeReused() throws {
        let box = try Sandbox(); defer { box.remove() }
        let queue = DispatchQueue(label: "play.early-exit")
        let runner = RegistrationRunner()
        let play = PlayService(client: JobClient(environment: box.environment(), runner: runner, callbackQueue: queue))
        runner.beforeReturn = { _, exit in exit(0); queue.sync {} }
        _ = try play.play(gameId: "0100A", userId: "02")
        XCTAssertFalse(play.isRunning)
        runner.beforeReturn = nil
        let next = try play.play(gameId: "0100A", userId: "02")
        XCTAssertEqual(play.sessions.map(\.taskId), [next.id])
        runner.exit?(0); queue.sync {}
        XCTAssertFalse(play.isRunning)
    }

    func testCancelBeforeRegistrationWaitsForExitAndIsIdempotent() throws {
        let box = try Sandbox(); defer { box.remove() }
        let queue = DispatchQueue(label: "play.early-stop")
        let runner = RegistrationRunner()
        let play = PlayService(client: JobClient(environment: box.environment(), runner: runner, callbackQueue: queue))
        runner.beforeReturn = { request, _ in
            let task = request["taskId"] as! String
            play.stop(taskId: task)
            play.stop(taskId: task)
            XCTAssertThrowsError(try play.play(gameId: "0100a", userId: "02"))
        }
        let handle = try play.play(gameId: "0100A", userId: "02")
        XCTAssertEqual(runner.handle.stops, 1)
        play.stop(taskId: handle.id)
        XCTAssertEqual(runner.handle.stops, 1)
        XCTAssertTrue(play.isRunning)
        XCTAssertThrowsError(try play.play(gameId: "0100A", userId: "02"))
        runner.exit?(130); queue.sync {}
        XCTAssertFalse(play.isRunning)
    }

    func testRunnerThrowReleasesReservedPair() throws {
        let box = try Sandbox(); defer { box.remove() }
        let queue = DispatchQueue(label: "play.failed-start")
        let runner = RegistrationRunner()
        let play = PlayService(client: JobClient(environment: box.environment(), runner: runner, callbackQueue: queue))
        runner.beforeReturn = { _, _ in throw JobClientError("synthetic start failure") }
        XCTAssertThrowsError(try play.play(gameId: "0100A", userId: "02"))
        XCTAssertFalse(play.isRunning)
        runner.beforeReturn = nil
        _ = try play.play(gameId: "0100A", userId: "02")
        XCTAssertTrue(play.isRunning)
        runner.exit?(0); queue.sync {}
        XCTAssertFalse(play.isRunning)
    }

    func testDifferentGamesCoexistAndEnvelopeCannotOverrideOwnership() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner(); runner.script = { _ in ([], 0, true) }
        let play = PlayService(client: client(box, runner))
        let done = expectation(description: "both exit"); done.expectedFulfillmentCount = 2
        let a = try play.play(gameId: "0100A", onFinish: { _ in done.fulfill() })
        let b = try play.play(gameId: "0100B", onFinish: { _ in done.fulfill() })
        XCTAssertEqual(play.sessions.count, 2)
        for extra: [String: Any] in [["userId": "02"], ["operation": "delete"], ["taskId": "other"]] {
            XCTAssertThrowsError(try play.play(gameId: "0100C", arguments: extra))
        }
        play.stop(taskId: a.id); play.stop(taskId: b.id)
        wait(for: [done], timeout: 3)
    }
}
