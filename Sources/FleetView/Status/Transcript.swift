import Foundation

/// Reads a Claude Code transcript JSONL to recover the latest user-typed prompt — used when a
/// terminal resumes an existing session (the UserPromptSubmit hook only fires for *new* prompts).
enum Transcript {
    static func latestUserPrompt(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Reverse scan: the last real user prompt is usually near the end.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  (obj["isMeta"] as? Bool) != true,
                  let msg = obj["message"] as? [String: Any],
                  let prompt = promptText(from: msg["content"]).flatMap(PromptText.clean)
            else { continue }
            return prompt
        }
        return nil
    }

    /// Extract typed text from a user message's `content` (string, or an array of blocks —
    /// ignoring tool_result blocks so we don't pick up tool output as a "prompt").
    private static func promptText(from content: Any?) -> String? {
        if let s = content as? String { return clean(s) }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? (block["text"] as? String) : nil
            }
            return texts.isEmpty ? nil : clean(texts.joined(separator: " "))
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What counts as something the user actually typed.
///
/// Claude Code and Codex both write harness-injected text as `user` records, and Claude Code also
/// submits some of it through the UserPromptSubmit hook. A background task finishing arrives as
/// `<task-notification>…</task-notification>`; on the card that read as raw XML in place of the
/// question you had asked. One list, used by the card, the search index and the Codex tree, so a
/// new wrapper only has to be learnt once.
enum PromptText {
    static let injectedPrefixes = ["<local-command", "<command-name", "<command-message",
                                   "<command-args", "<system-reminder", "<user-memory",
                                   "<task-notification",
                                   "Caveat: The messages below", "[Request interrupted",
                                   "<bash-input", "<bash-stdout", "<bash-stderr"]

    /// The typed text, or nil when the record was injected rather than typed.
    static func clean(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !injectedPrefixes.contains(where: { t.hasPrefix($0) }) else { return nil }
        // A reminder block glued onto the end of a real prompt is not part of what was said.
        if let r = t.range(of: "<system-reminder>"), r.lowerBound != t.startIndex {
            t = String(t[t.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t.isEmpty ? nil : t
    }
}
