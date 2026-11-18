import Foundation
import XCTest
@testable import S2ArmAppleAdapter

final class HostInstallServiceTests: XCTestCase {
    func testHostActionUsesDistinctJobWithoutResourceRequest() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in
            ([eventLine("result", state: "completed", message: "操作完成", extra: #", "result":{"installed":false,"unchanged":true,"packFiles":0}"#)], 0, false)
        }
        let result = try await InstallService(client: client(box, runner)).installHost(gameId: "0100000000000000")
        XCTAssertEqual(runner.starts.count, 1)
        XCTAssertEqual(runner.starts.first?.request["operation"] as? String, "installHost")
        XCTAssertEqual(runner.starts.first?.request["gameId"] as? String, "0100000000000000")
        XCTAssertNil(runner.starts.first?.request["force"])
        XCTAssertEqual(result.packFiles, 0)
    }
}
