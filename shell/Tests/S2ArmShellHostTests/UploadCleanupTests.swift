import Foundation
import Darwin
import Testing
@testable import S2ArmShellHost

private struct CleanupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("upload-cleanup-" + UUID().uuidString)
    let gid = "0100000000010000"
    var prefix: String { "Documents/.Trash/\(gid)/资源包/.incoming" }
    func put(_ path: String, _ count: Int = 123) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: count).write(to: url)
    }
    func preview() throws -> S2ArmUploadCleanup.Preview { try S2ArmUploadCleanup.preview(root: root, gameID: gid, archived: true) }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func uploadAbandonmentPreservesAllFormalAndUnknownData() throws {
    let f = CleanupFixture(); defer { f.clean() }
    try f.put(f.prefix + "/123_000.tar", 300)
    try f.put(f.prefix + "/123_001.tar", 25) // Truncated is still explicit abandonment, not content verification.
    let preserved = ["Documents/.Trash/\(f.gid)/S2A/ryujinx/bis/user/save/progress",
                     "Documents/.Trash/\(f.gid)/资源包/romfs.bin", "Documents/.Trash/\(f.gid)/资源包/.pushed",
                     "Documents/games/\(f.gid)/资源包/romfs.bin", "Documents/unknown", "tmp/live-writer"]
    for path in preserved { try f.put(path) }
    let p = try f.preview(); #expect(p.bytes == 325 && p.files.count == 2)
    #expect(try S2ArmUploadCleanup.previews(root: f.root).count == 1)
    #expect(throws: (any Error).self) { try S2ArmUploadCleanup.discard(root: f.root, preview: p, transportStopped: false) }
    #expect(try f.preview().files.count == 2)
    let result = try S2ArmUploadCleanup.discard(root: f.root, preview: p, transportStopped: true)
    #expect(result.removedFiles == 2 && result.removedLogicalBytes == 325 && !result.interrupted)
    #expect(try f.preview().files.isEmpty)
    for path in preserved { #expect(try Data(contentsOf: f.root.appendingPathComponent(path)) == Data(repeating: 3, count: 123)) }
}

@Test func cleanupChangedPreviewNeverDeletes() throws {
    for scenario in 0..<5 {
        let f = CleanupFixture(); defer { f.clean() }
        try f.put(f.prefix + "/1_000.tar")
        let p = try f.preview()
        switch scenario {
        case 0: try f.put(f.prefix + "/1_000.tar", 125)
        case 1: try f.put(f.prefix + "/1_001.tar")
        case 2:
            try FileManager.default.removeItem(at: f.root.appendingPathComponent(f.prefix + "/1_000.tar"))
            try f.put(f.prefix + "/1_000.tar")
        case 3:
            try FileManager.default.moveItem(at: f.root.appendingPathComponent(f.prefix), to: f.root.appendingPathComponent(f.prefix + "-old"))
            try f.put(f.prefix + "/1_000.tar")
        default: try f.put(f.prefix + "/save.dat")
        }
        #expect(throws: (any Error).self) { try S2ArmUploadCleanup.discard(root: f.root, preview: p, transportStopped: true) }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.prefix + "/1_000.tar").path))
    }
}

@Test func cleanupRejectsLinksHardlinksUnknownAndTraversal() throws {
    for scenario in 0..<4 {
        let f = CleanupFixture(); defer { f.clean() }
        try f.put("Documents/formal-save")
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent(f.prefix), withIntermediateDirectories: true)
        let target = f.root.appendingPathComponent(f.prefix + "/1_000.tar")
        switch scenario {
        case 0: try FileManager.default.createSymbolicLink(at: target, withDestinationURL: f.root.appendingPathComponent("Documents/formal-save"))
        case 1: try FileManager.default.linkItem(at: f.root.appendingPathComponent("Documents/formal-save"), to: target)
        case 2: try f.put(f.prefix + "/unknown.tar")
        default: try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        #expect(throws: (any Error).self) { try f.preview() }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("Documents/formal-save")).count == 123)
        #expect(throws: (any Error).self) { try S2ArmUploadCleanup.preview(root: f.root, gameID: "../games", archived: true) }
    }
}

@Test func cleanupActiveGameAndCancellation() throws {
    let f = CleanupFixture(); defer { f.clean() }
    let prefix = "Documents/games/\(f.gid)/资源包/.incoming"
    try f.put(prefix + "/1_000.tar")
    let p = try S2ArmUploadCleanup.preview(root: f.root, gameID: f.gid, archived: false)
    let cancelled = try S2ArmUploadCleanup.discard(root: f.root, preview: p, transportStopped: true, cancelled: { true })
    #expect(cancelled.interrupted && cancelled.removedFiles == 0)
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(prefix + "/1_000.tar").path))
    let done = try S2ArmUploadCleanup.discard(root: f.root, preview: p, transportStopped: true)
    #expect(done.removedFiles == 1)
}

@Test func cleanupStopsAfterPartialMutationOrCancellation() throws {
    for scenario in 0..<4 {
        let f = CleanupFixture(); defer { f.clean() }
        try f.put(f.prefix + "/1_000.tar", 10)
        try f.put(f.prefix + "/1_001.tar", 20)
        let p = try f.preview()
        let result = try S2ArmUploadCleanup.discard(root: f.root, preview: p, transportStopped: true) {
            // Runs synchronously before each unlink; mutate only this test root
            // after the first confirmed file has actually been removed.
            guard !FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.prefix + "/1_000.tar").path) else { return false }
            switch scenario {
            case 0: return true
            case 1: try! f.put(f.prefix + "/2_000.tar", 30)
            case 2: try! f.put(f.prefix + "/1_001.tar", 21)
            default:
                let parent = f.root.appendingPathComponent("Documents/.Trash")
                let moved = f.root.appendingPathComponent("Documents/moved")
                try! FileManager.default.moveItem(at: parent, to: moved)
                try! FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
            }
            return false
        }
        #expect(result.interrupted && result.removedFiles == 1 && result.removedLogicalBytes == 10)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.prefix + "/1_001.tar").path))
    }
}

@Test func cleanupRejectsReplacedAncestorBeforeFirstDeletion() throws {
    let f = CleanupFixture(); defer { f.clean() }
    try f.put(f.prefix + "/1_000.tar")
    let p = try f.preview()
    let parent = f.root.appendingPathComponent("Documents/.Trash")
    let moved = f.root.appendingPathComponent("Documents/moved")
    try FileManager.default.moveItem(at: parent, to: moved)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
    #expect(throws: (any Error).self) { try S2ArmUploadCleanup.discard(root: f.root, preview: p, transportStopped: true) }
    #expect(try Data(contentsOf: f.root.appendingPathComponent(f.prefix + "/1_000.tar")).count == 123)
}

@Test func incompleteSandboxDoesNotHideVerifiedUploadBatches() throws {
    let f = CleanupFixture(); defer { f.clean() }
    try f.put(f.prefix + "/1794216301_000.tar", 42)
    try f.put("Documents/games/\(f.gid)/资源包/.incoming/1794243803_000.tar", 2)
    // A special file makes sandbox accounting incomplete, just as an unreadable
    // system-owned entry does on iOS. Neither is part of either owned batch.
    let special = f.root.appendingPathComponent("system-entry").path
    #expect(mkfifo(special, 0o600) == 0)
    let report = try S2ArmStorage.scan(root: f.root)
    #expect(report.incomplete)
    let discovery = S2ArmUploadCleanup.discover(root: f.root)
    #expect(discovery.candidates.count == 2 && discovery.issues.isEmpty)
    #expect(discovery.candidates.map(\.bytes).sorted() == [2, 42])
    // Unknown data is not silently called zero recoverable space.
    try f.put(f.prefix + "/unknown-file")
    let blocked = S2ArmUploadCleanup.discover(root: f.root)
    #expect(blocked.candidates.count == 1 && blocked.issues.count == 1)
    #expect(blocked.issues[0].contains(f.gid))
}
