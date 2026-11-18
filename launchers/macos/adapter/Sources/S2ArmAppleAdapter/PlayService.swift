import Foundation

/// Each game/user pair owns one launch job. Backend locks remain authoritative
/// across launcher processes; this registry owns only this client's handles.
public final class PlayService {
    public struct Session: Equatable, Sendable {
        public let taskId: String
        public let gameId: String
        public let userId: String
    }

    private struct Entry {
        let session: Session
        var handle: JobHandle?
        var stopping = false
    }
    private let client: JobClient
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(client: JobClient) { self.client = client }

    public var sessions: [Session] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.session).sorted { $0.taskId < $1.taskId }
    }
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !entries.isEmpty
    }
    /// Compatibility for single-session callers. Never pick an arbitrary game
    /// when several are running; controls should address taskId explicitly.
    public var current: JobHandle? {
        lock.lock(); defer { lock.unlock() }
        return entries.count == 1 ? entries.values.first?.handle : nil
    }

    @discardableResult
    public func play(gameId: String, userId: String? = nil, uiLanguage: String? = nil,
                     arguments: [String: Any]? = nil,
                     onEvent: @escaping (JobEvent) -> Void = { _ in },
                     onFinish: @escaping (JobOutcome) -> Void = { _ in }) throws -> JobHandle {
        var extra = arguments ?? [:]
        // User selection has one typed entry point, not a second unvalidated
        // arguments override that could disagree with local pair ownership.
        guard extra["userId"] == nil, extra["taskId"] == nil, extra["operation"] == nil,
              userId == nil || userId!.range(of: #"^(?:0[1-9]|[1-9][0-9]{1,5})$"#, options: .regularExpression) != nil else {
            throw JobClientError("用户选择无效，请刷新用户列表。")
        }
        var selected = userId ?? "01"
        if selected == "01", let player = extra["player"] as? [String: Any],
           let playerUser = player["user"] as? String, !playerUser.isEmpty, playerUser != "first" {
            selected = playerUser
        }
        let task = UUID().uuidString.lowercased()
        let session = Session(taskId: task, gameId: gameId, userId: selected)
        lock.lock()
        if entries.values.contains(where: { $0.session.gameId.lowercased() == gameId.lowercased() && $0.session.userId == selected }) {
            lock.unlock()
            throw JobClientError("同一游戏和用户已有一局在运行，请先停止。")
        }
        // Reserve before start: a fast callback may arrive before it returns.
        entries[task] = Entry(session: session)
        lock.unlock()
        extra["gameId"] = gameId
        if let userId { extra["userId"] = userId }
        if let uiLanguage, !uiLanguage.isEmpty { extra["uiLanguage"] = uiLanguage }   // 照原样带，作业层认（build.py 六门之外不设宿主界面语言）
        do {
            let handle = try client.start(operation: "launch", extra: extra, id: task, onEvent: onEvent,
                                          onFinish: { [weak self] outcome in
                self?.finish(task)
                onFinish(outcome)
            })
            lock.lock()
            var cancel = false
            if var entry = entries[task] {
                entry.handle = handle; cancel = entry.stopping
                entries[task] = entry
            }
            // No entry means it already exited. Do not resurrect a finished job.
            lock.unlock()
            if cancel { handle.cancel() }
            return handle
        } catch {
            finish(task)
            throw error
        }
    }

    private func finish(_ task: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: task)
    }

    /// Cancellation retains pair ownership until the owned process exits.
    public func stop(taskId: String) {
        lock.lock()
        guard var entry = entries[taskId], !entry.stopping else { lock.unlock(); return }
        entry.stopping = true; entries[taskId] = entry
        let handle = entry.handle
        lock.unlock()
        handle?.cancel()
    }

    public func stop() {
        lock.lock()
        let task = entries.count == 1 ? entries.values.first?.session.taskId : nil
        lock.unlock()
        if let task { stop(taskId: task) }
    }
}
