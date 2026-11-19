import Foundation
import Darwin

/// Read-only inventory. Directory descriptors + O_NOFOLLOW prevent following a
/// symlink into saves/another container; no file contents or credentials are read.
public struct S2ArmStorage: Sendable {
    public struct Item: Identifiable, Sendable, Equatable {
        public var id: String
        public var logicalBytes: UInt64 = 0
        public var allocatedBytes: UInt64 = 0
        public var files: UInt64 = 0
    }
    public struct Report: Sendable {
        public var items: [Item]
        public var incomplete: Bool
        public var linksSkipped: UInt64
        public var logicalBytes: UInt64 { items.reduce(0) { $0 + $1.logicalBytes } }
        public var allocatedBytes: UInt64 { items.reduce(0) { $0 + $1.allocatedBytes } }
    }
    public static let liveRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    /// Categories are accounting labels, never deletion authorization. Archives
    /// in .incoming may be the ONLY copy of a completed upload, even with valid
    /// tar tails; .Trash may contain user-deleted saves or unimported resources.
    static func category(_ path: [String]) -> String {
        guard let first = path.first else { return "other" }
        if first == "tmp" { return "systemTemporary" }
        if first == "Library" { return path.dropFirst().first == "Caches" ? "cache" : "application" }
        guard first == "Documents" else { return "other" }
        let rest = Array(path.dropFirst())
        if rest.first == ".Trash" { return "trashReview" }
        if rest.first == "games", rest.count >= 2 {
            let gid = rest[1]
            let suffix = Array(rest.dropFirst(2))
            if suffix.starts(with: ["资源包", ".incoming"]) { return "upload:\(gid)" }
            if suffix.starts(with: ["S2A", "ryujinx", "bis", "user", "save"]) ||
                suffix.starts(with: ["S2A", "ryujinx", "bis", "system", "save"]) { return "save:\(gid)" }
            return "game:\(gid)"
        }
        if rest.starts(with: ["资源包", ".incoming"]) { return "upload:legacy" }
        if rest.starts(with: ["S2A", "ryujinx", "bis", "user", "save"]) ||
            rest.starts(with: ["S2A", "ryujinx", "bis", "system", "save"]) { return "save:legacy" }
        if rest.first == "资源包" { return "game:legacy" }
        return "documentsOther"
    }

    /// Whole sandbox except the signed app bundle (which is outside this root).
    /// Physical blocks are counted once for hard links; APFS clone sharing and
    /// purgeable capacity cannot be inferred from st_blocks. UI labels estimates.
    public static func scan(root: URL, cancelled: @Sendable () -> Bool = { false }) throws -> Report {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var items: [String: Item] = [:]
        var seen: Set<String> = []
        var incomplete = false
        var links: UInt64 = 0
        func walk(_ directory: Int32, _ path: [String], _ depth: Int) {
            if cancelled() || depth > 128 { incomplete = true; return }
            let copy = dup(directory)
            guard copy >= 0 else { incomplete = true; return }
            guard let stream = fdopendir(copy) else { close(copy); incomplete = true; return }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else { if errno != 0 { incomplete = true }; break }
                if cancelled() { incomplete = true; return }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { incomplete = true; continue }
                let type = info.st_mode & S_IFMT
                if type == S_IFLNK { links += 1; continue }
                let next = path + [name]
                if type == S_IFDIR {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { incomplete = true; continue }
                    var actual = stat()
                    if fstat(child, &actual) == 0 && actual.st_dev == info.st_dev && actual.st_ino == info.st_ino {
                        walk(child, next, depth + 1)
                    } else { incomplete = true }
                    close(child)
                } else if type == S_IFREG {
                    let key = category(next)
                    var item = items[key] ?? Item(id: key)
                    item.files += 1
                    item.logicalBytes += UInt64(max(0, info.st_size))
                    if seen.insert("\(info.st_dev):\(info.st_ino)").inserted {
                        item.allocatedBytes += UInt64(max(0, info.st_blocks)) * 512
                    }
                    items[key] = item
                } else { incomplete = true }
            }
        }
        walk(fd, [], 0)
        return Report(items: items.values.sorted { $0.id < $1.id }, incomplete: incomplete, linksSkipped: links)
    }
}
