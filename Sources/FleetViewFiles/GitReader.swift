import Foundation

/// Every git command the file window runs, read-only and out of the agents' way.
///
/// Several agents usually work in the same repository and commit. Anything that takes
/// `.git/index.lock` while one of them commits makes that commit fail (`index.lock: File exists`),
/// and the usual reaction is `rm -f .git/index.lock`, which can break a git operation that really is
/// running. Measured on git 2.50.1: plain `git status` rewrites the index whenever a file's stat
/// changed; every porcelain `git diff` rewrites it too, *even with* `--no-optional-locks`; and
/// `status --no-optional-locks`, `ls-files`, `ls-tree`, `cat-file`, `check-ignore`, `rev-parse`,
/// `grep`, `diff-index`, `diff-files` and `log` write nothing. Only commands from that second list
/// are run here, always with `--no-optional-locks`, and never `git diff`.
///
/// `core.fsmonitor` is forced off for our calls: with it on, even a lock-free status starts a daemon
/// that writes cookies into `.git/`, which the window's own watcher would then report back.
public final class GitReader: @unchecked Sendable {
    public static let shared = GitReader()

    /// Resolved once: `/usr/bin/git` is a shim that costs ~10 ms per call finding the real binary.
    public let executable: String
    /// Two git processes at most across the app, however many windows ask.
    private let slots = DispatchSemaphore(value: 2)

    init() {
        executable = Self.resolveGit() ?? "/usr/bin/git"
    }

    private static func resolveGit() -> String? {
        let r = Subprocess.run("/usr/bin/xcrun", ["--find", "git"], timeout: 5)
        let path = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
                  "GIT_NAMESPACE", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] {
            env.removeValue(forKey: k)
        }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_NO_LAZY_FETCH"] = "1"         // a partial clone must not reach for the network
        env["GIT_LFS_SKIP_SMUDGE"] = "1"       // nor an LFS file
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        return env
    }()

    /// Run `git <args>` in `dir`. Blocks — call it off the main thread.
    public func run(_ args: [String], in dir: String, input: Data? = nil, timeout: TimeInterval = 10,
                    limit: Int = 64 << 20, cancel: CancelToken? = nil) -> Subprocess.Result {
        slots.wait()
        defer { slots.signal() }
        if cancel?.isCancelled == true { return .cancelled }
        let argv = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", dir] + args
        return Subprocess.run(executable, argv, environment: Self.environment, input: input,
                              timeout: timeout, limit: limit, cancel: cancel)
    }

    // MARK: - Queries

    public struct Repo: Equatable, Sendable {
        public let toplevel: String
        public let gitDir: String
        public let commonDir: String
    }

    /// The repository `dir` is in, or nil when it is not in one.
    public func repo(at dir: String) -> Repo? {
        let r = run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: dir)
        guard r.status == 0 else { return nil }
        let lines = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return nil }
        return Repo(toplevel: lines[0], gitDir: lines[1], commonDir: lines[2])
    }

    /// `git status`, relative to the repository's top level. Never `-uall` (one repository here holds
    /// eight million untracked files: 42–57 s and 284 MB of output) and never `--ignored`.
    ///
    /// `under`: a project that is a folder inside a larger repository asks about that folder only.
    public func status(_ repo: Repo, under subdir: String? = nil, cancel: CancelToken? = nil) -> [GitStatus.Entry]? {
        var args = ["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignore-submodules=dirty"]
        if let subdir, !subdir.isEmpty { args += ["--", subdir] }
        let r = run(args, in: repo.toplevel, timeout: 20, cancel: cancel)
        guard r.status == 0 else { return nil }
        return GitStatus.parse(r.out)
    }

    /// Tracked files, relative to the top level.
    public func trackedFiles(_ repo: Repo, cancel: CancelToken? = nil) -> [String]? {
        let r = run(["ls-files", "-z"], in: repo.toplevel, timeout: 20, cancel: cancel)
        guard r.status == 0 else { return nil }
        return Self.splitNUL(r.out)
    }

    /// Untracked, unignored entries with whole untracked directories collapsed to `dir/`.
    public func untrackedEntries(_ repo: Repo, cancel: CancelToken? = nil) -> [String]? {
        let r = run(["ls-files", "--others", "--exclude-standard", "--directory", "--no-empty-directory", "-z"],
                    in: repo.toplevel, timeout: 20, limit: 8 << 20, cancel: cancel)
        guard r.status == 0 || r.truncated else { return nil }
        return Self.splitNUL(r.out)
    }

    /// Which of `paths` (relative to the top level) .gitignore excludes.
    public func ignored(_ paths: [String], in repo: Repo) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        var input = Data()
        for p in paths { input.append(contentsOf: p.utf8); input.append(0) }
        let r = run(["check-ignore", "-z", "--stdin"], in: repo.toplevel, input: input)
        // Exit 1 means "none of them": not an error.
        guard r.status == 0 else { return [] }
        return Set(Self.splitNUL(r.out))
    }

    /// The HEAD blob of a file and its path from the top level of the repository that holds it —
    /// asked from the file's own directory, so a file inside a submodule is looked up in the
    /// submodule. nil when HEAD does not have it (new, untracked, no commits yet).
    public func headBlob(file: String) -> (oid: String, path: String)? {
        let dir = (file as NSString).deletingLastPathComponent
        let name = (file as NSString).lastPathComponent
        let r = run(["ls-tree", "--full-name", "-z", "HEAD", "--", name], in: dir)
        guard r.status == 0, let rec = Self.splitNUL(r.out).first,
              let tab = rec.firstIndex(of: "\t") else { return nil }
        let fields = rec[..<tab].split(separator: " ")
        guard fields.count >= 3, fields[1] == "blob" else { return nil }
        return (String(fields[2]), String(rec[rec.index(after: tab)...]))
    }

    /// A blob as it would be checked out: through `.gitattributes` eol conversion, `ident` and smudge
    /// filters. The raw blob (`git show`) differs from the working file on every line of a CRLF file
    /// or an LFS pointer while git reports no change. `--path` is relative to the top level.
    public func checkedOut(oid: String, path: String, near file: String) -> Data? {
        let dir = (file as NSString).deletingLastPathComponent
        var r = run(["cat-file", "--filters", "--path=" + path, oid], in: dir, timeout: 5)
        if r.status != 0 { r = run(["cat-file", "blob", oid], in: dir, timeout: 5) }
        return r.status == 0 ? r.out : nil
    }

    public func headCommit(_ repo: Repo) -> String? {
        let r = run(["rev-parse", "-q", "--verify", "HEAD"], in: repo.toplevel)
        guard r.status == 0 else { return nil }
        return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git grep` over tracked files. Stops at `maxHits` matches or 2 MB of output.
    public func grep(_ query: String, in repo: Repo, under subdir: String?, caseSensitive: Bool,
                     maxHits: Int = 1000, cancel: CancelToken? = nil) -> GrepResult {
        var args = ["grep", "-n", "-I", "-z", "--no-color", "-F"]
        if !caseSensitive { args.append("-i") }
        args += ["-e", query]
        if let subdir, !subdir.isEmpty { args += ["--", subdir] }
        let r = run(args, in: repo.toplevel, timeout: 15, limit: 2 << 20, cancel: cancel)
        return GrepResult.parse(r.out, maxHits: maxHits, truncated: r.truncated)
    }

    /// `git grep` over named files whatever git thinks of them (`--no-index`): the untracked files a
    /// project's file list opened up. Paths are relative to the top level.
    public func grepFiles(_ query: String, _ files: [String], in repo: Repo, caseSensitive: Bool,
                          maxHits: Int, cancel: CancelToken? = nil) -> GrepResult {
        var args = ["grep", "--no-index", "-n", "-I", "-z", "--no-color", "-F"]
        if !caseSensitive { args.append("-i") }
        args += ["-e", query, "--"] + files
        let r = run(args, in: repo.toplevel, timeout: 15, limit: 2 << 20, cancel: cancel)
        return GrepResult.parse(r.out, maxHits: maxHits, truncated: r.truncated)
    }

    static func splitNUL(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// `git status --porcelain=v2 -z`.
public enum GitStatus {
    public enum Mark: String, Sendable { case modified = "M", added = "A", deleted = "D", renamed = "R",
                                        untracked = "U", conflicted = "C" }

    public struct Entry: Equatable, Sendable {
        public let path: String
        public let mark: Mark
        /// For a rename staged in the index: where it came from (what HEAD calls it).
        public let originalPath: String?
    }

    public static func parse(_ data: Data) -> [Entry] {
        let recs = GitReader.splitNUL(data)
        var out: [Entry] = []
        var i = 0
        while i < recs.count {
            let r = recs[i]
            i += 1
            guard let kind = r.first else { continue }
            switch kind {
            case "1", "2", "u":
                let fields = r.split(separator: " ", maxSplits: kind == "1" ? 8 : (kind == "2" ? 9 : 10),
                                     omittingEmptySubsequences: false)
                guard let path = fields.last.map(String.init), fields.count > 1 else { continue }
                let xy = Array(fields[1])
                var orig: String? = nil
                if kind == "2", i < recs.count { orig = recs[i]; i += 1 }
                let mark: Mark
                if kind == "u" { mark = .conflicted }
                else if xy.contains("D") { mark = .deleted }
                else if kind == "2" { mark = .renamed }
                else if xy.first == "A" { mark = .added }
                else { mark = .modified }
                out.append(Entry(path: path, mark: mark, originalPath: orig))
            case "?":
                out.append(Entry(path: String(r.dropFirst(2)), mark: .untracked, originalPath: nil))
            default:
                continue
            }
        }
        return out
    }
}

public struct GrepHit: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let text: String

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

public struct GrepResult: Equatable, Sendable {
    public let hits: [GrepHit]
    /// More matched than are listed.
    public let truncated: Bool

    public init(hits: [GrepHit], truncated: Bool) {
        self.hits = hits
        self.truncated = truncated
    }

    /// `path\0line\0text\n`, as `git grep -n -z` prints it (and `grep -rnZ` close enough).
    public static func parse(_ data: Data, maxHits: Int, truncated: Bool) -> GrepResult {
        var hits: [GrepHit] = []
        var cut = truncated
        for raw in data.split(separator: 10, omittingEmptySubsequences: true) {
            if hits.count >= maxHits { cut = true; break }
            let parts = raw.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let n = Int(String(decoding: parts[1], as: UTF8.self)) else { continue }
            let text = String(decoding: parts[2].prefix(400), as: UTF8.self)
            hits.append(GrepHit(path: String(decoding: parts[0], as: UTF8.self), line: n, text: text))
        }
        return GrepResult(hits: hits, truncated: cut)
    }
}

/// A way to stop a running search when a newer one starts.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }
}

/// One short-lived child process: low priority, bounded in time and in output.
public enum Subprocess {
    public struct Result: Sendable {
        public let status: Int32
        public let out: Data
        /// Stopped at `limit` bytes of output (and killed).
        public let truncated: Bool
        public let timedOut: Bool

        static let cancelled = Result(status: -1, out: Data(), truncated: false, timedOut: false)
    }

    public static func run(_ executable: String, _ args: [String], environment: [String: String]? = nil,
                           input: Data? = nil, timeout: TimeInterval, limit: Int = 64 << 20,
                           cancel: CancelToken? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let environment { p.environment = environment }
        p.qualityOfService = .utility
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let inPipe = input.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice
        if let cancel, !cancel.attach(p) { return .cancelled }
        do { try p.run() } catch { return Result(status: -1, out: Data(), truncated: false, timedOut: false) }
        if let input, let inPipe {
            DispatchQueue.global(qos: .utility).async {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let timedOut = TimedOut()
        let killer = DispatchWorkItem { [weak p] in
            guard let p, p.isRunning else { return }
            timedOut.set()
            p.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let h = out.fileHandleForReading
        var data = Data()
        var truncated = false
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit {
                truncated = true
                if p.isRunning { p.terminate() }
                break
            }
        }
        p.waitUntilExit()
        killer.cancel()
        return Result(status: p.terminationStatus, out: data, truncated: truncated, timedOut: timedOut.value)
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}

/// HEAD's version of files, by blob id, up to a byte budget — so switching tabs, reopening a file
/// or every window on one repository does not run git again for content git cannot have changed.
/// A blob id names its content, so nothing here is ever stale; it is only evicted.
public final class BlobCache: @unchecked Sendable {
    public static let shared = BlobCache(limit: 64 << 20)

    private let lock = NSLock()
    private let limit: Int
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private var bytes = 0

    public init(limit: Int) { self.limit = limit }

    public func get(_ oid: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let d = entries[oid] else { return nil }
        if let i = order.firstIndex(of: oid) { order.remove(at: i); order.append(oid) }
        return d
    }

    public func put(_ oid: String, _ data: Data) {
        guard data.count <= limit / 4 else { return }      // one huge file must not empty the cache
        lock.lock(); defer { lock.unlock() }
        if entries[oid] != nil { return }
        entries[oid] = data
        order.append(oid)
        bytes += data.count
        while bytes > limit, let first = order.first {
            order.removeFirst()
            bytes -= entries.removeValue(forKey: first)?.count ?? 0
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }
}
