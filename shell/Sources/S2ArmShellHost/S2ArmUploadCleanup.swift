import Foundation
import Darwin
import ShellUI

/// Explicit abandonment, NOT deduplication. Legacy AFC writers do not obey App
/// locks: the user must stop transfer/disconnect its transport before confirming.
/// No resources, saves, folders, links or unknown files are
/// recursively deleted. Immutable preview is revalidated before every unlink.
enum S2ArmUploadCleanup {
    struct File: Sendable, Equatable {
        let name: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64
    }
    struct Preview: Identifiable, Sendable {
        let id = UUID()
        let gameID: String
        let archived: Bool
        let directoryDevice: Int32
        let directoryInode: UInt64
        let files: [File]
        var bytes: UInt64 { files.reduce(0) { $0 + UInt64($1.size) } }
        var components: [String] { ["Documents", archived ? ".Trash" : "games", gameID, "资源包", ".incoming"] }
    }
    struct Result: Sendable {
        let removedFiles: Int
        let removedLogicalBytes: UInt64
        let interrupted: Bool
    }
    enum Problem: Error, LocalizedError {
        case unsafe, changed, transportNotStopped
        var errorDescription: String? {
            switch self {
            case .unsafe: shellText("Cannot verify directory or file ownership; cleanup did not run. Links, unknown files, and multiple hard links are not deleted.")
            case .changed: shellText("Staged content changed after confirmation, so cleanup stopped. Please stop the transfer, disconnect, and check again.")
            case .transportNotStopped: shellText("Please stop the computer transfer and disconnect the transfer connection before confirming upload abandonment.")
            }
        }
    }
    private static func openDirectory(root: URL, components: [String]) throws -> Int32 {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Problem.unsafe }
        for part in components {
            guard !part.isEmpty && part != "." && part != ".." && !part.contains("/") else { close(fd); throw Problem.unsafe }
            let child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard child >= 0 else { throw Problem.unsafe }
            fd = child
        }
        return fd
    }
    private static func names(_ fd: Int32) throws -> [String] {
        // openat(".") creates a new directory cursor; dup shares the old offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw Problem.unsafe }
        guard let dir = fdopendir(copy) else { close(copy); throw Problem.unsafe }
        defer { closedir(dir) }
        var list: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else { if errno != 0 { throw Problem.unsafe }; return list.sorted() }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { list.append(name) }
        }
    }
    private static func identity(_ fd: Int32, _ name: String) throws -> File {
        // Only sender-generated batch names; unknown files make the whole preview
        // unavailable. Tar payload is not inspected or executed, valid or truncated.
        guard name.range(of: #"^[0-9]+_[0-9]{3}\.tar$"#, options: .regularExpression) != nil else { throw Problem.unsafe }
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size >= 0 else { throw Problem.unsafe }
        return File(name: name, device: st.st_dev, inode: st.st_ino, size: st.st_size,
                    modifiedSeconds: Int64(st.st_mtimespec.tv_sec), modifiedNanos: Int64(st.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(st.st_ctimespec.tv_sec), changedNanos: Int64(st.st_ctimespec.tv_nsec))
    }
    struct Discovery: Sendable {
        var candidates: [Preview] = []
        var issues: [String] = []
    }
    /// Independent of sandbox-wide accounting: an unreadable system directory
    /// must not hide a separately verified, user-owned incoming directory.
    static func discover(root: URL) -> Discovery {
        var result = Discovery()
        for archived in [true, false] {
            let scope = archived ? shellText("Trash") : shellText("Game directory")
            let parent = ["Documents", archived ? ".Trash" : "games"]
            let fd: Int32
            do { fd = try openDirectory(root: root, components: parent) }
            catch {
                if errno != ENOENT { result.issues.append(shellText("\(scope): directory cannot be read safely; deletion is unavailable.")) }
                continue
            }
            defer { close(fd) }
            do {
                for gid in try names(fd) where isTitleID(gid) {
                    do {
                        let p = try preview(root: root, gameID: gid, archived: archived)
                        if !p.files.isEmpty { result.candidates.append(p) }
                    } catch {
                        // ENOENT means no incoming directory, not a blocked batch.
                        if errno != ENOENT { result.issues.append(shellText("\(scope) · \(gid): batch directory is unreadable or contains unknown files, links, or multiple hard links; kept.")) }
                    }
                }
            } catch { result.issues.append(shellText("\(scope): could not list directory completely; unverified items were kept.")) }
        }
        return result
    }
    static func previews(root: URL) throws -> [Preview] { discover(root: root).candidates }
    static func preview(root: URL, gameID: String, archived: Bool) throws -> Preview {
        errno = 0
        guard isTitleID(gameID) else { throw Problem.unsafe }
        let fd = try openDirectory(root: root, components: ["Documents", archived ? ".Trash" : "games", gameID, "资源包", ".incoming"])
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Problem.unsafe }
        let files = try names(fd).map { try identity(fd, $0) }
        return Preview(gameID: gameID, archived: archived, directoryDevice: st.st_dev, directoryInode: st.st_ino, files: files)
    }
    static func discard(root: URL, preview: Preview, transportStopped: Bool,
                        cancelled: @Sendable () -> Bool = { false }) throws -> Result {
        guard transportStopped else { throw Problem.transportNotStopped }
        let fd = try openDirectory(root: root, components: preview.components)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == preview.directoryDevice, st.st_ino == preview.directoryInode,
              try names(fd) == preview.files.map(\.name) else { throw Problem.changed }
        // Reject the entire batch before any mutation if even one file changed.
        for file in preview.files { guard try identity(fd, file.name) == file else { throw Problem.changed } }
        var count = 0
        var bytes: UInt64 = 0
        for (index, file) in preview.files.enumerated() {
            if cancelled() { return Result(removedFiles: count, removedLogicalBytes: bytes, interrupted: true) }
            // Verify current path still refers to this directory. Never chase a
            // replaced ancestor or unlink a newly arrived batch after confirmation.
            guard let current = try? openDirectory(root: root, components: preview.components) else {
                return Result(removedFiles: count, removedLogicalBytes: bytes, interrupted: true)
            }
            var currentStat = stat()
            let same = fstat(current, &currentStat) == 0 && currentStat.st_dev == st.st_dev && currentStat.st_ino == st.st_ino
            close(current)
            let remainingNames = preview.files[index...].map(\.name)
            guard same, let currentNames = try? names(fd), currentNames == remainingNames,
                  let actual = try? identity(fd, file.name), actual == file,
                  unlinkat(fd, file.name, 0) == 0 else {
                return Result(removedFiles: count, removedLogicalBytes: bytes, interrupted: true)
            }
            count += 1; bytes += UInt64(file.size)
        }
        // .pushed is deliberately retained: existing sender only trusts it when
        // complete incoming archives remain. No resources/save metadata rewritten.
        return Result(removedFiles: count, removedLogicalBytes: bytes, interrupted: false)
    }
}
