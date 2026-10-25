import FleetViewFiles
import Foundation

/// Unsaved edits, kept on disk while they are unsaved.
///
/// The text of a dirty tab lives in the editor page, which is a separate process: if it crashes, or
/// FleetView is killed, the edits would go with it. The page sends a copy a second after typing
/// stops; it lands here, one small JSON file per edited path, and is deleted when the edits are saved
/// or thrown away. Opening a file that has one offers it back.
enum FileRecovery {
    struct Entry: Codable {
        let path: String
        /// The version of the file on disk the edits were made against.
        let base: String?
        let text: String
        let at: Date
    }

    static var dir: URL { FV.supportDir.appendingPathComponent("editor-recovery", isDirectory: true) }

    private static let queue = DispatchQueue(label: "fleetview.files.recovery", qos: .utility)

    private static func file(for path: String) -> URL {
        dir.appendingPathComponent(String(FileText.version(Data(path.utf8)).prefix(24)) + ".json")
    }

    static func write(path: String, base: String?, text: String) {
        let entry = Entry(path: path, base: base, text: text, at: Date())
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: file(for: path), options: .atomic)
        }
    }

    static func remove(path: String) {
        queue.async { try? FileManager.default.removeItem(at: file(for: path)) }
    }

    /// Read synchronously: called when a tab opens, before it is shown.
    static func load(path: String) -> Entry? {
        queue.sync {
            guard let data = try? Data(contentsOf: file(for: path)) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }
    }
}
