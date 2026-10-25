import CoreServices
import FleetViewFiles
import Foundation

/// What changed under a project, in batches — the one FSEvents stream a file window runs.
///
/// Directory-level only: a build writes tens of thousands of files, and per-file events would mean
/// tens of thousands of callbacks for a tree that shows one directory at a time. The directories a
/// window never shows (build output, dependencies, git's object store) are excluded at the source
/// where they sit at the top of the project, and dropped by name in the callback anywhere deeper.
/// Events arrive on a utility queue; only the digest reaches the main thread.
final class ProjectWatcher {
    struct Batch {
        /// Changed directories, relative to the project root ("" is the root itself).
        var dirs: Set<String> = []
        /// The index moved: git markers may be stale.
        var index = false
        /// HEAD or a ref moved: the baseline of every open file may have changed.
        var head = false
        /// The stream lost events: everything shown has to be looked at again.
        var rescan = false
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "fleetview.files.watch", qos: .utility)
    private let root: String
    private let gitDirs: [String]
    private let onBatch: (Batch) -> Void

    /// `gitDirs`: the repository's git directory and common directory, which for a worktree live in
    /// the main checkout — outside the project — and are where commits and checkouts show up.
    init(root: String, gitDirs: [String], onBatch: @escaping (Batch) -> Void) {
        self.root = root
        self.gitDirs = Array(Set(gitDirs.filter { !$0.hasPrefix(root + "/") }))
        self.onBatch = onBatch
    }

    func start() {
        guard stream == nil else { return }
        var paths = [root] + gitDirs
        paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, ProjectWatcher.callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        // Up to eight paths the stream does not report at all; the rest are dropped in the callback.
        // In order of how much a build or an install writes there, so the eight that exist are the
        // eight that matter.
        var excluded: [String] = gitDirs.map { $0 + "/objects" }
        for name in [".git/objects", "node_modules", ".build", "DerivedData", "target", "build", "dist",
                     ".next", ".venv", ".git/logs"] {
            let p = root + "/" + name
            if FileManager.default.fileExists(atPath: p) { excluded.append(p) }
        }
        FSEventStreamSetExclusionPaths(s, Array(excluded.prefix(8)) as CFArray)
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        // The context holds `self` unretained: wait out a callback already running on the queue, or
        // it would finish against a freed object. (The callback only hops to main asynchronously.)
        queue.sync {}
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let me = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        me.digest(list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }

    private func digest(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        var b = Batch()
        for (i, raw) in paths.enumerated() {
            let f = Int(flags[i])
            if f & kFSEventStreamEventFlagMustScanSubDirs != 0 || f & kFSEventStreamEventFlagUserDropped != 0
                || f & kFSEventStreamEventFlagKernelDropped != 0 || f & kFSEventStreamEventFlagRootChanged != 0 {
                b.rescan = true
            }
            let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if let g = gitDirs.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                gitEvent(String(path.dropFirst(g.count)), into: &b)
                continue
            }
            guard path == root || path.hasPrefix(root + "/") else { continue }
            let rel = path == root ? "" : String(path.dropFirst(root.count + 1))
            if rel == ".git" || rel.hasPrefix(".git/") {
                gitEvent(String(rel.dropFirst(4)), into: &b)
                continue
            }
            if rel.split(separator: "/").contains(where: { ProjectFiles.skipped.contains(String($0)) }) { continue }
            b.dirs.insert(rel)
        }
        guard b.rescan || b.index || b.head || !b.dirs.isEmpty else { return }
        onBatch(b)
    }

    /// `sub` is the part after the git directory, starting with "/" or empty.
    private func gitEvent(_ sub: String, into b: inout Batch) {
        if sub.isEmpty || sub == "/" { b.index = true; b.head = true; return }
        if sub.hasPrefix("/objects") || sub.hasPrefix("/logs") { return }
        if sub == "/index" { b.index = true; return }
        if sub == "/HEAD" || sub == "/packed-refs" || sub.hasPrefix("/refs") || sub.hasPrefix("/worktrees") {
            b.head = true
            b.index = true
        }
    }
}

/// Exactly when one open file changes, is replaced, renamed or deleted: a vnode source on it.
///
/// One file descriptor per open tab. Re-armed whenever the inode under the path changes, which is
/// what an agent's atomic write (and our own swap) does.
final class FileWatch {
    private var source: DispatchSourceFileSystemObject?
    private let path: String
    private let onChange: () -> Void
    /// The file the descriptor is on, to tell when the path has a new one.
    private var armed: (dev: dev_t, ino: ino_t)?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    func arm() {
        source?.cancel()
        source = nil
        armed = nil
        // Regular files only: opening a FIFO, even for events, can wait for a writer.
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
        let fd = open(path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return }
        var fst = stat()
        if fstat(fd, &fst) == 0 { armed = (fst.st_dev, fst.st_ino) }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke, .link],
            queue: .main)
        s.setEventHandler { [weak self] in self?.onChange() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    /// Watch the file now under the path, if it is not the one watched.
    func rearmIfReplaced() {
        var st = stat()
        let now = stat(path, &st) == 0 ? (st.st_dev, st.st_ino) : nil
        if now?.0 != armed?.dev || now?.1 != armed?.ino || source == nil { arm() }
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
