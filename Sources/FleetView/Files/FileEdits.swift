import Foundation

extension Notification.Name {
    /// An agent's tool call is about to write files; `object` is the [String] of absolute paths.
    static let fileEditsNoted = Notification.Name("FleetView.fileEditsNoted")
}

/// Which card wrote which file, as the agents' own hooks say it.
///
/// Claude's `PreToolUse` hook forwards every tool call's input, and an Edit or a Write names its file
/// (Codex's `apply_patch` names its files in the patch) — so who changed a file is known the moment
/// it is about to happen, without reading a transcript. Kept in memory only, newest last, a thousand
/// at most: it answers "who just changed this", not "who ever did". A file changed by a shell command
/// has no record here and is shown without an author rather than guessed at.
@MainActor
final class FileEdits {
    static let shared = FileEdits()

    struct Edit {
        let path: String
        let terminalId: UUID
        let terminalName: String
        let at: Date
    }

    private var edits: [Edit] = []
    private static let cap = 1000

    func note(_ paths: [String], terminal: TerminalSession) {
        let now = Date()
        for p in paths { edits.append(Edit(path: p, terminalId: terminal.id, terminalName: terminal.name, at: now)) }
        if edits.count > Self.cap { edits.removeFirst(edits.count - Self.cap) }
        NotificationCenter.default.post(name: .fileEditsNoted, object: paths)
    }

    /// The last record for this file, if any.
    func latest(for path: String) -> Edit? { edits.last { $0.path == path } }

    /// Records for files under `root`, newest first, one per file.
    func recent(under root: String, limit: Int = 50) -> [Edit] {
        var seen = Set<String>()
        var out: [Edit] = []
        for e in edits.reversed() where e.path.hasPrefix(root + "/") && !seen.contains(e.path) {
            seen.insert(e.path)
            out.append(e)
            if out.count >= limit { break }
        }
        return out
    }
}
