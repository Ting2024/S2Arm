import Foundation
import XCTest
@testable import S2ArmAppleAdapter

final class UserServiceTests: XCTestCase {
    private static let initial = #"{"schema":1,"revision":0,"nextId":2,"users":[{"id":"01","name":"用户1","accountUid":null}]}"#
    private static let two = #"{"schema":1,"revision":1,"nextId":3,"users":[{"id":"01","name":"用户1","accountUid":null},{"id":"02","name":"Second","accountUid":"11111111111111111111111111111111"}]}"#

    private func response(_ json: String) -> String {
        eventLine("result", state: "succeeded", extra: #","result":"# + json)
    }

    func testListWithoutLibraryKeepsLegacyIdentityUnassigned() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([self.response(Self.initial)], 0, false) }
        let registry = try await UserService(client: client(box, runner, env: box.environment(library: ""))).list()
        XCTAssertEqual(registry.users.map(\.id), ["01"])
        XCTAssertNil(registry.users[0].accountUid)
        XCTAssertEqual(registry.revision, 0)
        XCTAssertEqual(runner.starts.first?.request["operation"] as? String, "users")
        XCTAssertNil(runner.starts.first?.request["gameId"])
    }

    func testCreateAndRenameCarryRevisionAndExactUserId() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([self.response(Self.two)], 0, false) }
        let service = UserService(client: client(box, runner))
        let registry = try await service.create(name: "Second", revision: 0)
        XCTAssertEqual(registry.users.map(\.id), ["01", "02"])
        XCTAssertEqual(runner.starts[0].request["operation"] as? String, "userUpdate")
        XCTAssertEqual(runner.starts[0].request["action"] as? String, "create")
        XCTAssertEqual(runner.starts[0].request["revision"] as? Int, 0)
        _ = try await service.rename(id: "02", name: "Renamed", revision: registry.revision)
        XCTAssertEqual(runner.starts[1].request["userId"] as? String, "02")
        XCTAssertEqual(runner.starts[1].request["name"] as? String, "Renamed")
        XCTAssertEqual(runner.starts[1].request["revision"] as? Int, 1)
        XCTAssertNil(runner.starts[1].request["gameId"])
    }

    func testMalformedResponseNeverFabricatesDefaultOrDropsInvalidUsers() throws {
        let valid = try JSONSerialization.jsonObject(with: Data(Self.two.utf8)) as! [String: Any]
        var documents: [[String: Any]] = [[:], valid.merging(["schema": 2]) { _, b in b },
                                          valid.merging(["revision": true]) { _, b in b }]
        var duplicate = valid
        let rows = valid["users"] as! [[String: Any]]
        duplicate["users"] = rows + [rows[1]]; documents.append(duplicate)
        for change: [String: Any] in [["id": "../02"], ["accountUid": NSNull()],
                                      ["accountUid": "00000000000000010000000000000000"],
                                      ["name": "你好你好你好你好你好你"], ["name": "bad\nname"]] {
            var document = valid
            document["users"] = [rows[0], rows[1].merging(change) { _, b in b }]
            documents.append(document)
        }
        var missingLegacy = valid; missingLegacy["users"] = [rows[1]]; documents.append(missingLegacy)
        for document in documents { XCTAssertThrowsError(try UserRegistry.decode(document)) }
    }

    func testStaleRevisionFailureRemainsFailure() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "failed", message: "用户列表已变化，请刷新后重试。")], 1, false) }
        do {
            _ = try await UserService(client: client(box, runner)).create(name: "Second", revision: 0)
            XCTFail("Must not retry a stale mutation or fabricate a successful registry")
        } catch { XCTAssertTrue(error is JobFailure) }
        XCTAssertEqual(runner.starts.count, 1)
    }
}
