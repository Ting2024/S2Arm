import Foundation

/// Resource-scoped admission, not a global "anything is running" flag.
/// Symmetric intersection of claims: read/read coexists; any writer conflicts.
/// Unknown scope is a wildcard, never evidence that two targets are different.
struct OperationClaim: Equatable {
    enum Resource { case library, toolchain, game, userState, device, buildProducts }
    enum Access { case read, write }
    let resource: Resource
    let scope: String?
    let access: Access

    func conflicts(with other: Self) -> Bool {
        resource == other.resource && (scope == nil || other.scope == nil || scope == other.scope) &&
            (access == .write || other.access == .write)
    }
}

struct OperationIntent {
    enum Kind: CaseIterable {
        case browse, play, saves, build, verify, importGames, deleteGame
        case transfer, installHost, removeFromPhone, changeLibrary, changeTools
    }
    let kind: Kind
    var gameID: String? = nil
    var userID: String? = nil
    var deviceID: String? = nil

    var claims: [OperationClaim] {
        typealias C = OperationClaim
        let game = gameID?.lowercased()
        let pair = game.flatMap { g in userID.map { g + ":" + $0 } }
        let libraryRead = C(resource: .library, scope: nil, access: .read)
        let toolsRead = C(resource: .toolchain, scope: nil, access: .read)
        switch kind {
        case .browse: return []
        case .play, .saves:
            return [libraryRead, toolsRead, C(resource: .game, scope: game, access: .read),
                    C(resource: .userState, scope: pair, access: .write)]
        case .build:
            return [libraryRead, toolsRead, C(resource: .game, scope: game, access: .write),
                    C(resource: .buildProducts, scope: game, access: .write)]
        case .verify:
            // Verification may recover state / inspect mutable outputs. Keep
            // exclusive game ownership until a strictly read-only path is audited.
            return [libraryRead, toolsRead, C(resource: .game, scope: game, access: .write)]
        case .transfer, .installHost, .removeFromPhone:
            // Mobile operations read already-packaged iPhone outputs and write
            // only to the connected device (or a private staging dir / container).
            // They do not conflict with building/exporting another game.
            return [libraryRead, toolsRead, C(resource: .game, scope: game, access: .read),
                    C(resource: .buildProducts, scope: game, access: .read),
                    C(resource: .device, scope: deviceID, access: .write)]
        case .importGames, .deleteGame, .changeLibrary:
            // Backend currently holds exclusive execution during mutations.
            // Do not promise per-game concurrency until that lock is narrowed.
            return [C(resource: .library, scope: nil, access: .write)]
        case .changeTools:
            return [C(resource: .toolchain, scope: nil, access: .write)]
        }
    }
    func conflicts(with other: Self) -> Bool {
        claims.contains { a in other.claims.contains { a.conflicts(with: $0) } }
    }
}

extension JobSession {
    var conflictIntent: OperationIntent {
        let operation: OperationIntent.Kind
        switch kind {
        case .play: operation = .play
        case .export, .prepare: operation = .build
        case .install, .installRestore, .installUpdate, .installTV, .exportTV, .pushSelected: operation = .transfer
        case .installHost: operation = .installHost
        case .installRemove: operation = .removeFromPhone
        case .verify: operation = .verify
        case .importGames: operation = .importGames
        case .delete, .moveGame, .clearCache: operation = .deleteGame
        case .downloadMetal, .downloadIosPlatform, .installDotnet: operation = .changeTools
        case .setupLibrary, .keys, .diagnostics: operation = .changeLibrary // unaudited -> conservative
        }
        return OperationIntent(kind: operation, gameID: gameID)
    }
}

extension S2ArmLauncherModel {
    func operationBlocked(_ intent: OperationIntent) -> Bool {
        if backgroundOperations.values.contains(where: { intent.conflicts(with: $0) }) { return true }
        if playSessions.contains(where: { play in
            if case .finished = play.job.phase { return false }
            return intent.conflicts(with: OperationIntent(kind: .play, gameID: play.job.gameID, userID: play.user.id))
        }) { return true }
        return saveOperations.values.contains { intent.conflicts(with: $0) }
    }
    func localStateBlocked(gameID: String, userID: String, save: Bool = false) -> Bool {
        operationBlocked(OperationIntent(kind: save ? .saves : .play, gameID: gameID, userID: userID))
    }
}
