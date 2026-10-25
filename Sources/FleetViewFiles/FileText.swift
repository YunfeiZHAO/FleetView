import CryptoKit
import Foundation

/// What a file's bytes are, as far as the editor is concerned, and how to put them back.
///
/// The editor only ever sees LF and never sees a BOM. Everything that would otherwise be rewritten
/// on save without the user touching it is recorded here and restored by `encode`: CRLF line
/// endings, a UTF-8 BOM, and — by never adding or trimming anything — a missing final newline.
/// What cannot be put back exactly is not editable: invalid UTF-8 has no text to edit, and a file
/// that mixes CRLF with LF (or has a lone CR) would come back with one convention throughout.
public enum FileText {
    public enum EOL: String, Sendable { case lf, crlf }

    public struct Decoded: Sendable {
        /// LF-only, BOM-less.
        public let text: String
        public let eol: EOL
        public let bom: Bool
        /// Why the file opens read-only, or nil when it can be edited.
        public let readOnlyReason: ReadOnly?
    }

    public enum ReadOnly: String, Sendable {
        case mixedLineEndings = "mixed-eol"
        case notUTF8 = "not-utf8"
        case binary
        case tooLarge = "too-large"
        case notWritable = "not-writable"
    }

    /// A NUL in the first 8 KB is how git decides a file is binary, and what `/read` refuses.
    public static let probeLength = 8192

    public static func isBinary(_ head: Data) -> Bool {
        head.prefix(probeLength).contains(0)
    }

    /// The text of `data`, or nil when it is not UTF-8.
    public static func decode(_ data: Data) -> Decoded? {
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? data.dropFirst(3) : data[...]
        guard let raw = String(data: Data(body), encoding: .utf8) else { return nil }

        var crlf = 0, lf = 0, cr = 0
        body.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let n = p.count
            var i = 0
            while i < n {
                let c = p[i]
                if c == 13 {
                    if i + 1 < n && p[i + 1] == 10 { crlf += 1; i += 2; continue }
                    cr += 1
                } else if c == 10 {
                    lf += 1
                }
                i += 1
            }
        }
        if cr > 0 || (crlf > 0 && lf > 0) {
            // Shown as lines, but not editable: saving would settle on one convention for all of them.
            let shown = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return Decoded(text: shown, eol: crlf >= lf ? .crlf : .lf, bom: bom, readOnlyReason: .mixedLineEndings)
        }
        if crlf > 0 {
            return Decoded(text: raw.replacingOccurrences(of: "\r\n", with: "\n"), eol: .crlf, bom: bom, readOnlyReason: nil)
        }
        return Decoded(text: raw, eol: .lf, bom: bom, readOnlyReason: nil)
    }

    /// The bytes for `text` (LF-only, as the editor hands it back) in the file's own conventions.
    public static func encode(_ text: String, eol: EOL, bom: Bool) -> Data {
        // The editor never produces a CR, but a stray one would turn into "\r\r\n" below.
        var s = text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
        if eol == .crlf { s = s.replacingOccurrences(of: "\n", with: "\r\n") }
        var out = Data(capacity: s.utf8.count + 3)
        if bom { out.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        out.append(contentsOf: s.utf8)
        return out
    }

    /// The version token of a file's bytes — the same hex SHA-256 the web's `/read` and `/save` use.
    public static func version(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether any line is long enough to make highlighting a liability (minified JSON, one-line logs).
    public static func hasLongLine(_ text: String, limit: Int = 10_000) -> Bool {
        var run = 0
        for b in text.utf8 {
            if b == 10 { run = 0; continue }
            run += 1
            if run > limit { return true }
        }
        return false
    }
}
