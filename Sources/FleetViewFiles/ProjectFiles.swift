import Foundation

/// Finding files in a folder that git does not describe, without walking all of it.
///
/// A git project's file list comes from `git ls-files` (11 ms for 7 788 files in the largest one
/// here). A folder that is not a repository has no index, so it is walked — but never into the
/// directories that make a walk expensive and are never what anyone is looking for, and never past
/// a fixed number of entries or a fixed time.
public enum ProjectFiles {
    /// Directory names a walk or a search never enters.
    public static let skipped: Set<String> = [
        ".git", "node_modules", ".venv", "venv", ".build", "build", "dist", "target", "__pycache__",
        "DerivedData", ".next", ".cache", ".tox", ".mypy_cache", ".pytest_cache", ".gradle", "Pods",
    ]

    /// Up to `limit` file paths under `root`, relative to it, found within `budget` seconds.
    public static func walk(_ root: String, limit: Int = 50_000, budget: TimeInterval = 1.5,
                            cancel: CancelToken? = nil) -> (files: [String], complete: Bool) {
        let deadline = Date().addingTimeInterval(budget)
        let fm = FileManager.default
        var out: [String] = []
        var queue: [String] = [""]
        var complete = true
        while !queue.isEmpty {
            if out.count >= limit || Date() > deadline || cancel?.isCancelled == true { complete = false; break }
            let rel = queue.removeFirst()
            let abs = rel.isEmpty ? root : root + "/" + rel
            guard let names = try? fm.contentsOfDirectory(atPath: abs) else { continue }
            for name in names.sorted() where name != ".DS_Store" {
                let child = rel.isEmpty ? name : rel + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: abs + "/" + name, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if !skipped.contains(name) { queue.append(child) }
                } else {
                    out.append(child)
                    if out.count >= limit { break }
                }
            }
        }
        return (out, complete)
    }

    /// Text search in a folder that is not a repository: BSD grep, skipping the same directories.
    public static func grep(_ query: String, in root: String, caseSensitive: Bool, maxHits: Int = 1000,
                            cancel: CancelToken? = nil) -> GrepResult {
        var args = ["-r", "-I", "-n", "-F", "--null"]
        if !caseSensitive { args.append("-i") }
        for d in skipped.sorted() { args.append("--exclude-dir=" + d) }
        args += ["-e", query, "--", "."]
        let r = Subprocess.run("/usr/bin/grep", args, timeout: 15, limit: 2 << 20, cancel: cancel)
        // BSD grep with --null prints "path\0line:text".
        var hits: [GrepHit] = []
        var cut = r.truncated
        for raw in r.out.split(separator: 10) {
            if hits.count >= maxHits { cut = true; break }
            let parts = raw.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let colon = parts[1].firstIndex(of: 58),
                  let n = Int(String(decoding: parts[1][..<colon], as: UTF8.self)) else { continue }
            var path = String(decoding: parts[0], as: UTF8.self)
            if path.hasPrefix("./") { path.removeFirst(2) }
            hits.append(GrepHit(path: path, line: n,
                                text: String(decoding: parts[1][parts[1].index(after: colon)...].prefix(400), as: UTF8.self)))
        }
        return GrepResult(hits: hits, truncated: cut)
    }
}

/// Quick-open matching: the letters of the query, in order, anywhere in the path — preferring the
/// file name, the start of a word, and runs of consecutive letters.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        public let path: String
        public let score: Double
        /// Matched character offsets into `path`, for bolding.
        public let positions: [Int]
    }

    public static func match(_ query: String, _ path: String) -> Match? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return nil }
        let chars = Array(path)
        let low = Array(path.lowercased())
        guard low.count == chars.count else { return nil }
        let nameStart = (chars.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        func run(from start: Int) -> (Double, [Int])? {
            var pos: [Int] = []
            var score = 0.0
            var i = start, prev = -2
            for c in q {
                while i < low.count && low[i] != c { i += 1 }
                if i >= low.count { return nil }
                let edge = i == 0 || "/_-. +".contains(chars[i - 1])
                    || (chars[i].isUppercase && chars[i - 1].isLowercase)
                score += (i == prev + 1 ? 6 : 1) + (edge ? 5 : 0)
                pos.append(i)
                prev = i
                i += 1
            }
            return (score, pos)
        }
        if let (s, p) = run(from: nameStart) {
            return Match(path: path, score: s + 25 - Double(chars.count - nameStart) * 0.05, positions: p)
        }
        if let (s, p) = run(from: 0) {
            return Match(path: path, score: s - Double(chars.count) * 0.03, positions: p)
        }
        return nil
    }

    /// The best `limit` matches, best first.
    public static func best(_ query: String, in paths: [String], limit: Int = 200) -> [Match] {
        var out: [Match] = []
        out.reserveCapacity(min(paths.count, 4096))
        for p in paths { if let m = match(query, p) { out.append(m) } }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return Array(out.prefix(limit))
    }
}

/// Which files a tool call writes, read off its input the way the hook payload carries it.
///
/// Claude names the file in `file_path` (`notebook_path` for notebooks). Codex's `apply_patch`
/// carries the patch text, whose `*** Add File:`, `*** Update File:`, `*** Delete File:` and
/// `*** Move to:` headers name every file it touches. A shell command can write anything; it is not
/// guessed at, and a file changed that way simply has no author.
public enum EditedPaths {
    public static func paths(tool: String?, input: [String: Any]?, cwd: String?) -> [String] {
        guard let tool, let input else { return [] }
        var found: [String] = []
        switch tool {
        case "Write", "Edit", "MultiEdit":
            if let p = input["file_path"] as? String { found.append(p) }
        case "NotebookEdit":
            if let p = (input["notebook_path"] as? String) ?? (input["file_path"] as? String) { found.append(p) }
        default:
            for v in input.values {
                if let s = v as? String { found += patchPaths(s) }
                if let a = v as? [Any] { for case let s as String in a { found += patchPaths(s) } }
            }
        }
        return found.map { absolute($0, cwd: cwd) }
    }

    static func patchPaths(_ text: String) -> [String] {
        guard text.contains("*** ") else { return [] }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
            where line.hasPrefix(prefix) {
                let p = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { out.append(p) }
            }
        }
        return out
    }

    static func absolute(_ path: String, cwd: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        guard let cwd else { return expanded }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL.path
    }
}
