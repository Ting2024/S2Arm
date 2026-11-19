import Foundation
import Testing
@testable import S2ArmShellHost

@Test func storageInventoryDoesNotTreatArchivesAsDisposable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func put(_ path: String, _ count: Int) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x51, count: count).write(to: file)
    }
    let gid = "0100000000010000"
    try put("Documents/games/\(gid)/资源包/romfs.bin", 100)
    try put("Documents/games/\(gid)/资源包/.incoming/1_001.tar", 30)
    try put("Documents/games/\(gid)/S2A/ryujinx/bis/user/save/a/progress", 20)
    try put("Documents/.Trash/possibly-only-copy.tar", 50)
    try put("tmp/upload", 10)
    try put("Library/Caches/shader", 11)
    try put("Library/Preferences/settings", 12)
    try put("Documents/unknown", 13)
    try put("Documents/资源包/.incoming/old.tar", 14)
    try put("Documents/S2A/ryujinx/bis/system/save/progress", 15)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Documents/linked"), withDestinationURL: root)
    let report = try S2ArmStorage.scan(root: root)
    #expect(!report.incomplete && report.linksSkipped == 1)
    #expect(report.logicalBytes == 275)
    let entries = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0.logicalBytes) })
    #expect(entries["game:\(gid)"] == 100)
    #expect(entries["save:\(gid)"] == 20)
    #expect(entries["upload:\(gid)"] == 30)
    #expect(entries["trashReview"] == 50)
    #expect(entries["systemTemporary"] == 10)
    #expect(entries["upload:legacy"] == 14)
    #expect(entries["save:legacy"] == 15)
    // Inventory reads metadata only; every byte remains unchanged.
    #expect(try Data(contentsOf: root.appendingPathComponent("Documents/.Trash/possibly-only-copy.tar")) == Data(repeating: 0x51, count: 50))
    #expect(try Data(contentsOf: root.appendingPathComponent("Documents/games/\(gid)/S2A/ryujinx/bis/user/save/a/progress")) == Data(repeating: 0x51, count: 20))
    let cancelled = try S2ArmStorage.scan(root: root, cancelled: { true })
    #expect(cancelled.incomplete && cancelled.items.isEmpty)
}

@Test func storageHardlinksAndRootSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
    try Data(repeating: 7, count: 8192).write(to: first)
    let before = try S2ArmStorage.scan(root: root)
    try FileManager.default.linkItem(at: first, to: second)
    let after = try S2ArmStorage.scan(root: root)
    #expect(after.logicalBytes == 16384)
    #expect(after.allocatedBytes == before.allocatedBytes)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    #expect(throws: (any Error).self) { try S2ArmStorage.scan(root: link) }
}
