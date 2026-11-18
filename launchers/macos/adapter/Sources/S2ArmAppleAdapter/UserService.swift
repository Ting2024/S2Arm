import Foundation

/// Launcher ID is not a Horizon account UID. User 01 retains each game's legacy
/// identity; newly created users carry their own stable account UID.
public struct LauncherUser: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let accountUid: String?

    public init(id: String, name: String, accountUid: String? = nil) {
        self.id = id
        self.name = name
        self.accountUid = accountUid
    }
}

public struct UserRegistry: Codable, Equatable, Sendable {
    public let schema: Int
    public let revision: Int
    public let nextId: Int
    public let users: [LauncherUser]

    static func decode(_ result: [String: Any]) throws -> UserRegistry {
        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            let registry = try JSONDecoder().decode(Self.self, from: data)
            guard registry.schema == 1, registry.revision >= 0,
                  (2...1_000_000).contains(registry.nextId),
                  (1...100).contains(registry.users.count) else { throw InvalidRegistry() }
            var ids = Set<String>(), uids = Set<String>()
            for user in registry.users {
                guard user.id.range(of: #"^(?:0[1-9]|[1-9][0-9]{1,5})$"#, options: .regularExpression) != nil,
                      let number = Int(user.id), number < registry.nextId,
                      ids.insert(user.id).inserted, !user.name.isEmpty,
                      user.name == user.name.trimmingCharacters(in: .whitespacesAndNewlines),
                      user.name.utf8.count <= 32,
                      !user.name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw InvalidRegistry() }
                if user.id == "01" {
                    guard user.accountUid == nil else { throw InvalidRegistry() }
                } else {
                    guard let uid = user.accountUid,
                          uid.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
                          uid != String(repeating: "0", count: 32),
                          uid != "00000000000000010000000000000000",
                          uids.insert(uid).inserted else { throw InvalidRegistry() }
                }
            }
            guard ids.contains("01") else { throw InvalidRegistry() }
            return registry
        } catch {
            // Never fabricate user 01 on malformed response: that would retarget saves.
            throw JobClientError("用户资料无效，请刷新用户列表；没有更改所选用户。")
        }
    }
    private struct InvalidRegistry: Error {}
}

/// No library or game selection is required. All mutations use the displayed
/// revision, so two management windows cannot overwrite each other's changes.
public final class UserService {
    private let client: JobClient
    public init(client: JobClient) { self.client = client }

    public func list() async throws -> UserRegistry {
        try UserRegistry.decode(await client.perform("users").result)
    }

    public func create(name: String, revision: Int) async throws -> UserRegistry {
        try await update(["action": "create", "name": name, "revision": revision])
    }

    public func rename(id: String, name: String, revision: Int) async throws -> UserRegistry {
        try await update(["action": "rename", "userId": id, "name": name, "revision": revision])
    }

    private func update(_ request: [String: Any]) async throws -> UserRegistry {
        try UserRegistry.decode(await client.perform("userUpdate", extra: request).result)
    }
}
