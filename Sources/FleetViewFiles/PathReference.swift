import Foundation

/// A file's path as typed into a terminal's input by "reference in card".
///
/// Typed, not pasted: a newline in a file name would press Return halfway through it, so a path
/// with a control character is refused. A shell gets the path single-quoted when it needs quoting at
/// all. An agent reads a double-quoted path as a path; Claude's `@` mention ends at the first space,
/// so a path that needs quotes goes to Claude quoted and without the `@`.
public enum PathReference {
    public enum Reader: Sendable { case claude, agent, shell }

    public static func text(_ path: String, for reader: Reader) -> String? {
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let plain = !path.isEmpty && path.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "/._-+,:@%=".unicodeScalars.contains($0)
        }
        let doubleQuoted = "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        switch reader {
        case .claude: return plain ? "@" + path : doubleQuoted
        case .agent: return plain ? path : doubleQuoted
        case .shell: return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}
