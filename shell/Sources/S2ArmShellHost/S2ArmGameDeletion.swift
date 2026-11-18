import Foundation
import Darwin
import ShellUI

/// Deletion is limited to the App-owned Documents/games/<title> tree. No
/// FileManager recursive remove: snapshot every entry, reject links/hardlinks,
/// preflight the whole tree, then unlink only recorded leaves/empty directories.
/// Legacy external writers must be stopped by the user; compare+unlink is not
/// an atomic writer revocation mechanism.
enum S2ArmGameDeletion {
    struct Entry: Equatable, Sendable {
        let path: [String]
        let device: Int32
        let inode: UInt64
        let directory: Bool
        let size: Int64
        let mtime: Int64
        let mnano: Int64
        let ctime: Int64
        let cnano: Int64
    }
    struct Preview: Sendable {
        let gameID: String
        let deleteSaves: Bool
        let entries: [Entry]
        var targets: [Entry] { entries.filter { !Self.keep($0.path, deleteSaves) } }
        var bytes: UInt64 { targets.filter { !$0.directory }.reduce(0) { $0 + UInt64($1.size) } }
        var preservedBytes: UInt64 { entries.filter { !$0.directory && Self.keep($0.path, deleteSaves) }.reduce(0) { $0 + UInt64($1.size) } }
        // Keep the whole runtime state when preserving saves. This includes save
        // journals/backups and avoids losing saves in an unfamiliar sub-layout.
        static func keep(_ path: [String], _ deleteSaves: Bool) -> Bool { !deleteSaves && path.first == "S2A" }
    }
    struct Result: Sendable {
        let removedFiles: Int
        let removedBytes: UInt64
        let complete: Bool
    }
    enum Problem: Error, LocalizedError {
        case unsafe, changed, transport
        var errorDescription: String? {
            switch self {
            case .unsafe: shellText("Cannot safely verify the game directory. Links, multiple hard links, special files, or unreadable items block deletion. Deletion did not start.")
            case .changed: shellText("The game directory changed after preview. Please stop the transfer and check again. Deletion did not start.")
            case .transport: shellText("Please stop the transfer and disconnect the computer or wireless transfer connection first.")
            }
        }
    }
    private static func openDir(_ root: URL, _ path: [String]) throws -> Int32 {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Problem.unsafe }
        for part in path {
            guard !part.isEmpty, part != ".", part != "..", !part.contains("/"), !part.contains("\0") else { close(fd); throw Problem.unsafe }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw Problem.unsafe }
            fd = next
        }
        return fd
    }
    private static func names(_ fd: Int32) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw Problem.unsafe }
        guard let dir = fdopendir(copy) else { close(copy); throw Problem.unsafe }
        defer { closedir(dir) }
        var result: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(dir) else {
                if errno != 0 { throw Problem.unsafe }
                return result.sorted()
            }
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
    }
    private static func entry(_ fd: Int32, _ name: String, _ path: [String]) throws -> Entry {
        var s = stat()
        guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_size >= 0 else { throw Problem.unsafe }
        let directory = s.st_mode & S_IFMT == S_IFDIR
        guard directory || (s.st_mode & S_IFMT == S_IFREG && s.st_nlink == 1) else { throw Problem.unsafe }
        return Entry(path: path, device: s.st_dev, inode: s.st_ino, directory: directory, size: s.st_size,
                     mtime: Int64(s.st_mtimespec.tv_sec), mnano: Int64(s.st_mtimespec.tv_nsec),
                     ctime: Int64(s.st_ctimespec.tv_sec), cnano: Int64(s.st_ctimespec.tv_nsec))
    }
    static func preview(root: URL, gameID: String, deleteSaves: Bool) throws -> Preview {
        guard gameID.utf8.count == 16, gameID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { throw Problem.unsafe }
        let parent = try openDir(root, ["Documents", "games"]); defer { close(parent) }
        let fd = openat(parent, gameID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw Problem.unsafe }
            return Preview(gameID: gameID, deleteSaves: deleteSaves, entries: [])
        }
        defer { close(fd) }
        var entries: [Entry] = []
        func walk(_ fd: Int32, _ path: [String]) throws {
            guard path.count < 128, entries.count < 200_000, !Task.isCancelled else { throw Problem.unsafe }
            let own = try entry(fd, ".", path)
            guard own.directory else { throw Problem.unsafe }
            entries.append(own)
            let children = try names(fd)
            for name in children {
                let e = try entry(fd, name, path + [name])
                if e.directory {
                    let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw Problem.unsafe }
                    defer { close(next) }
                    let actual = try entry(next, ".", e.path)
                    guard actual == e else { throw Problem.changed }
                    try walk(next, e.path)
                } else { entries.append(e) }
                guard entries.count < 200_000 else { throw Problem.unsafe }
            }
            guard try names(fd) == children, try entry(fd, ".", path) == own else { throw Problem.changed }
        }
        try walk(fd, [])
        return Preview(gameID: gameID, deleteSaves: deleteSaves, entries: entries)
    }
    static func delete(root: URL, preview p: Preview, transportStopped: Bool,
                       cancelled: @Sendable () -> Bool = { false }) throws -> Result {
        guard transportStopped else { throw Problem.transport }
        let current = try preview(root: root, gameID: p.gameID, deleteSaves: p.deleteSaves)
        guard current.entries == p.entries else { throw Problem.changed }
        let base = ["Documents", "games", p.gameID]
        let directories = Dictionary(uniqueKeysWithValues: p.entries.filter(\.directory).map { ($0.path, $0) })
        // Check every ancestor against the confirmed inode before each mutation.
        func verifiedParent(_ path: [String]) throws -> Int32 {
            for depth in 0...path.count {
                let part = Array(path.prefix(depth))
                let fd = try openDir(root, base + part)
                defer { close(fd) }
                let actual = try entry(fd, ".", part)
                guard let expected = directories[part], actual.directory,
                      actual.device == expected.device, actual.inode == expected.inode else { throw Problem.changed }
            }
            return try openDir(root, base + path)
        }
        var count = 0; var bytes: UInt64 = 0
        let targets = p.targets.filter { !$0.path.isEmpty }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.path.joined(separator: "/") < $1.path.joined(separator: "/")
        }
        for target in targets {
            if cancelled() { return Result(removedFiles: count, removedBytes: bytes, complete: false) }
            do {
                let parent = try verifiedParent(Array(target.path.dropLast())); defer { close(parent) }
                let name = target.path.last!
                let actual = try entry(parent, name, target.path)
                if target.directory {
                    guard actual.directory, actual.device == target.device, actual.inode == target.inode else { throw Problem.changed }
                    // Only succeeds if empty; never recursively removes arrivals.
                    guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Problem.changed }
                } else {
                    guard actual == target, unlinkat(parent, name, 0) == 0 else { throw Problem.changed }
                    count += 1; bytes += UInt64(target.size)
                }
            } catch { return Result(removedFiles: count, removedBytes: bytes, complete: false) }
        }
        // Leave the owned root (and preserved S2A state) in place. Check that no
        // unconfirmed content appeared; partial failure never hides the tile.
        do {
            let left = try preview(root: root, gameID: p.gameID, deleteSaves: p.deleteSaves)
            guard left.targets.allSatisfy({ $0.path.isEmpty }) else { throw Problem.changed }
            if let originalRoot = p.entries.first {
                guard let currentRoot = left.entries.first,
                      currentRoot.device == originalRoot.device, currentRoot.inode == originalRoot.inode else { throw Problem.changed }
            }
            let before = p.entries.filter { Preview.keep($0.path, p.deleteSaves) }
            let after = left.entries.filter { Preview.keep($0.path, p.deleteSaves) }
            guard before == after else { throw Problem.changed }
        } catch { return Result(removedFiles: count, removedBytes: bytes, complete: false) }
        return Result(removedFiles: count, removedBytes: bytes, complete: true)
    }
}
