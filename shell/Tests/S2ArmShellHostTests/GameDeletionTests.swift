import Foundation
import Darwin
import Testing
@testable import S2ArmShellHost

private struct GameDeleteFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-delete-" + UUID().uuidString)
    let id = "0100000000010000"
    var base: String { "Documents/games/\(id)" }
    func put(_ path: String, _ size: Int = 13) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 5, count: size).write(to: url)
    }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func preview(_ saves: Bool = false) throws -> S2ArmGameDeletion.Preview {
        try S2ArmGameDeletion.preview(root: root, gameID: id, deleteSaves: saves)
    }
}

@Test func gameDeletionKeepsSavesOrDeletesOnlyExplicitGameTree() throws {
    for saves in [false, true] {
        let f = GameDeleteFixture(); defer { f.clean() }
        let deleted = ["资源包/romfs.bin", "资源包/.incoming/1_000.tar", "资源包/.pushed", "identity.json", "VPadLayouts/layout.json"]
        let preserved = ["S2A/ryujinx/bis/user/save/progress", "S2A/ryujinx/bis/system/save/state", "S2A/save-transfer/save-transactions/recovery.json", "S2A/save-exports/a.s2asave", "S2A/ryujinx/cache/shader"]
        let outside = ["Documents/games/0100000000020000/资源包/romfs.bin", "Documents/.Trash/\(f.id)/资源包/.incoming/1_000.tar", "Documents/S2A/ryujinx/bis/user/save/legacy", "tmp/unrelated"]
        for path in deleted + preserved { try f.put(f.base + "/" + path) }
        for path in outside { try f.put(path) }
        let p = try f.preview(saves)
        #expect(p.bytes == UInt64((deleted.count + (saves ? preserved.count : 0)) * 13))
        #expect(p.preservedBytes == (saves ? 0 : UInt64(preserved.count * 13)))
        #expect(throws: (any Error).self) { try S2ArmGameDeletion.delete(root: f.root, preview: p, transportStopped: false) }
        #expect(f.exists(f.base + "/资源包/romfs.bin"))
        let result = try S2ArmGameDeletion.delete(root: f.root, preview: p, transportStopped: true)
        #expect(result.complete && result.removedBytes == p.bytes)
        for path in deleted { #expect(!f.exists(f.base + "/" + path)) }
        for path in preserved { #expect(f.exists(f.base + "/" + path) == !saves) }
        for path in outside { #expect(try Data(contentsOf: f.root.appendingPathComponent(path)) == Data(repeating: 5, count: 13)) }
        if !saves {
            for path in preserved { #expect(try Data(contentsOf: f.root.appendingPathComponent(f.base + "/" + path)) == Data(repeating: 5, count: 13)) }
            // Deleting again with the explicit save option removes retained saves.
            let remaining = try f.preview(true)
            #expect(try S2ArmGameDeletion.delete(root: f.root, preview: remaining, transportStopped: true).complete)
        }
    }
}

@Test func gameDeletionRejectsUnsafeOrChangedPreviewBeforeMutation() throws {
    for scenario in 0..<7 {
        let f = GameDeleteFixture(); defer { f.clean() }
        try f.put(f.base + "/资源包/a")
        let p = try f.preview()
        switch scenario {
        case 0: try f.put(f.base + "/资源包/a", 14)
        case 1: try f.put(f.base + "/new")
        case 2:
            try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent(f.base + "/link"), withDestinationURL: f.root)
        case 3:
            try FileManager.default.linkItem(at: f.root.appendingPathComponent(f.base + "/资源包/a"), to: f.root.appendingPathComponent(f.base + "/hardlink"))
        case 4: #expect(mkfifo(f.root.appendingPathComponent(f.base + "/fifo").path, 0o600) == 0)
        case 5:
            let parent = f.root.appendingPathComponent("Documents/games")
            let moved = f.root.appendingPathComponent("Documents/moved")
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        default:
            let dir = f.root.appendingPathComponent(f.base + "/资源包")
            try FileManager.default.moveItem(at: dir, to: f.root.appendingPathComponent(f.base + "/old"))
            try f.put(f.base + "/资源包/a")
        }
        #expect(throws: (any Error).self) { try S2ArmGameDeletion.delete(root: f.root, preview: p, transportStopped: true) }
        #expect(f.exists(f.base + "/资源包/a"))
        #expect(throws: (any Error).self) { try S2ArmGameDeletion.preview(root: f.root, gameID: "../games", deleteSaves: true) }
    }
}

@Test func gameDeletionReportsPartialCancellationAndNeverRecursivelyDeletesArrivals() throws {
    for scenario in 0..<3 {
        let f = GameDeleteFixture(); defer { f.clean() }
        try f.put(f.base + "/资源包/a", 11)
        try f.put(f.base + "/资源包/b", 12)
        let p = try f.preview(true)
        let result = try S2ArmGameDeletion.delete(root: f.root, preview: p, transportStopped: true) {
            guard !f.exists(f.base + "/资源包/a") else { return false }
            if scenario == 0 { return true }
            if scenario == 1 { try! f.put(f.base + "/资源包/b", 14) }
            else { try! f.put(f.base + "/资源包/new", 15) }
            return false
        }
        #expect(!result.complete && result.removedFiles >= 1 && result.removedBytes >= 11)
        if scenario == 0 { #expect(result.removedFiles == 1 && f.exists(f.base + "/资源包/b")) }
        if scenario == 1 { #expect(try Data(contentsOf: f.root.appendingPathComponent(f.base + "/资源包/b")).count == 14) }
        if scenario == 2 { #expect(f.exists(f.base + "/资源包/new")) }
    }
}

@Test func absentGameDirectoryCanBeRemovedFromListButNewDataInvalidatesPreview() throws {
    let f = GameDeleteFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Documents/games"), withIntermediateDirectories: true)
    let p = try f.preview()
    #expect(p.entries.isEmpty && p.bytes == 0)
    #expect(try S2ArmGameDeletion.delete(root: f.root, preview: p, transportStopped: true).complete)
    try f.put(f.base + "/资源包/new")
    #expect(throws: (any Error).self) { try S2ArmGameDeletion.delete(root: f.root, preview: p, transportStopped: true) }
    #expect(f.exists(f.base + "/资源包/new"))
}
