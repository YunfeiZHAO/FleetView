import FleetViewFiles
import Foundation

/// Unsaved edits, kept on disk while they are unsaved.
///
/// The text of a dirty tab lives in the editor page, which is a separate process: if it crashes, or
/// FleetView is killed, the edits would go with it. The page sends a copy once typing stops (a
/// second for an ordinary file, longer for large ones); it lands here, one file per edited path, and
/// is deleted when the edits are saved, undone or thrown away. Opening a file that has one offers it
/// back. A file is one line of JSON — path, base version, time — and then the text as it is, so a
/// 20 MB document is written, not escaped into JSON first.
enum FileRecovery {
    struct Entry {
        let path: String
        /// The version of the file on disk the edits were made against.
        let base: String?
        let text: String
        let at: Date
    }

    private struct Header: Codable {
        let path: String
        let base: String?
        let at: Date
    }

    static var dir: URL { FV.supportDir.appendingPathComponent("editor-recovery", isDirectory: true) }

    private static let queue = DispatchQueue(label: "fleetview.files.recovery", qos: .utility)
    private static var pruned = false

    private static func file(for path: String) -> URL {
        dir.appendingPathComponent(String(FileText.version(Data(path.utf8)).prefix(24)) + ".recovery")
    }

    static func write(path: String, base: String?, text: String) {
        let header = Header(path: path, base: base, at: Date())
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard var data = try? JSONEncoder().encode(header) else { return }
            data.append(10)
            data.append(contentsOf: text.utf8)
            try? data.write(to: file(for: path), options: .atomic)
        }
    }

    /// `now`: before returning — for "Don't Save" on the way out, after which the process is gone.
    static func remove(path: String, now: Bool = false) {
        let work = { try? FileManager.default.removeItem(at: file(for: path)) }
        if now { queue.sync { _ = work() } } else { queue.async { _ = work() } }
    }

    /// Read synchronously: called when a tab opens, before it is shown.
    static func load(path: String) -> Entry? {
        queue.sync {
            guard let data = try? Data(contentsOf: file(for: path)), let nl = data.firstIndex(of: 10),
                  let h = try? JSONDecoder().decode(Header.self, from: data[..<nl]), h.path == path else { return nil }
            return Entry(path: h.path, base: h.base, text: String(decoding: data[(nl + 1)...], as: UTF8.self), at: h.at)
        }
    }

    /// Edits nobody came back for in two weeks are not coming back: removed, once per run.
    static func pruneOnce() {
        guard !pruned else { return }
        pruned = true
        queue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-14 * 86_400)
            for f in files {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if m < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }
}
