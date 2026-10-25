import AppKit
import FleetViewFiles
import SwiftUI

/// Run `work` on a utility queue and come back with its result.
func onUtility<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
    }
}

/// Everything one file window knows: the tree, the tabs, what git says, what is unsaved.
///
/// Its own object rather than part of AppState on purpose: AppState publishes to the whole board,
/// and a keystroke in an editor must never make the board lay itself out again.
@MainActor
final class FileBrowserModel: ObservableObject, EditorHost {
    struct Row: Identifiable, Equatable {
        let id: String          // path relative to the project root
        let name: String
        let depth: Int
        let isDir: Bool
        let ignored: Bool
    }

    enum Kind: Equatable { case text, image, other }
    enum Mode: String { case source, preview }

    struct Tab: Identifiable, Equatable {
        let id: String
        var path: String        // relative to the project root
        var pinned: Bool
        var kind: Kind
        var mode: Mode
        var dirty = false
        var readOnly: String? = nil
        var wrap = false
    }

    enum Banner: Equatable {
        /// The file changed on disk while there are unsaved edits (or a save found it changed).
        case diskChanged
        case deleted
        case failed(String)
        /// Unsaved edits from an earlier session; `sameBase` when they were made against this version.
        case recovered(Date, sameBase: Bool)
        /// The editor page crashed and came back; unsaved edits were restored.
        case crashRestored
    }

    struct Status: Equatable {
        var line = 0, col = 0, lines = 0
        var added = 0, changed = 0, deleted = 0
        var noHead = false
        var hasDiff = false
    }

    /// What Swift keeps about an open text file: what the page was given, and how to put it back.
    struct Doc {
        var abs: String
        var lang: String
        var base: String?
        var eol: FileText.EOL = .lf
        var bom = false
        var fingerprint: FileSave.Fingerprint?
        var size: Int64 = 0
        /// Changed on disk while the tab was out of sight: read again when shown.
        var stale = false
        var recoveryOffered = false
    }

    struct Entry { let name: String; let isDir: Bool }

    let projectId: UUID
    let projectName: String
    let root: String
    weak var app: AppState?
    weak var window: NSWindow?
    let editor = EditorBridge()

    @Published private(set) var repo: GitReader.Repo?
    @Published private(set) var branch: String?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var marks: [String: GitStatus.Mark] = [:]
    @Published private(set) var dirtyDirs: Set<String> = []
    @Published var showIgnored = false { didSet { if showIgnored != oldValue { rebuildRows() } } }
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeTab: String?
    @Published private(set) var banners: [String: Banner] = [:]
    @Published private(set) var status = Status()
    @Published var revealTarget: String?
    @Published var toast: String?

    private var listings: [String: [Entry]] = [:]
    private var ignoredNames: [String: Set<String>] = [:]
    private var loading: Set<String> = []
    private(set) var expanded: Set<String> = [""]
    private var docs: [String: Doc] = [:]
    private var watches: [String: FileWatch] = [:]
    private var checks: [String: DispatchWorkItem] = [:]
    private var watcher: ProjectWatcher?
    /// The project's path inside its repository ("" when the project is the repository).
    private var rootInRepo = ""
    private var untrackedDirs: Set<String> = []
    /// Staged renames: new path → the path HEAD has it under.
    private(set) var renames: [String: String] = [:]
    private(set) var headCommit: String?
    private var toastTimer: DispatchWorkItem?
    private var lastKey: (String, Date) = ("", .distantPast)

    /// The window can be seen. Everything that costs anything waits for this.
    var visible = true { didSet { if visible && !oldValue { flushPending() } } }
    var isKey = false { didSet { if isKey && !oldValue { checkHead(); requestStatus(after: 0.2) } } }

    init(project: Project, app: AppState) {
        projectId = project.id
        projectName = project.name
        root = URL(fileURLWithPath: (project.path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        self.app = app
        editor.host = self
    }

    // MARK: - Paths

    func absolute(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    /// `abs` relative to the project root, or nil when it is outside it (after resolving links).
    func relative(_ abs: String) -> String? {
        let real = URL(fileURLWithPath: abs).resolvingSymlinksInPath().path
        for candidate in [abs, real] {
            if candidate == root { return "" }
            if candidate.hasPrefix(root + "/") { return String(candidate.dropFirst(root.count + 1)) }
        }
        return nil
    }

    private static func parent(_ rel: String) -> String {
        guard let i = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<i])
    }

    // MARK: - Lifecycle

    func start() {
        load("")
        Task {
            let root = self.root
            let repo = await onUtility { GitReader.shared.repo(at: root) }
            self.repo = repo
            if let repo {
                let top = URL(fileURLWithPath: repo.toplevel).resolvingSymlinksInPath().path
                rootInRepo = root == top ? "" : (root.hasPrefix(top + "/") ? String(root.dropFirst(top.count + 1)) : "")
                for dir in listings.keys { load(dir) }      // now with .gitignore applied
                readBranch()
                checkHead()
                requestStatus(after: 0)
            }
            startWatching()
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        for w in watches.values { w.cancel() }
        watches.removeAll()
        checks.values.forEach { $0.cancel() }
        statusTimer?.cancel()
        statusCancel?.cancel()
        editor.tearDown()
    }

    private func startWatching() {
        var gitDirs: [String] = []
        if let repo { gitDirs = [repo.gitDir, repo.commonDir] }
        let w = ProjectWatcher(root: root, gitDirs: gitDirs) { [weak self] batch in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(batch) } }
        }
        w.start()
        watcher = w
    }

    // MARK: - Tree

    private nonisolated static func list(_ abs: String) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: abs) else { return [] }
        var dirs: [Entry] = [], files: [Entry] = []
        for name in names where name != ".git" && name != ".DS_Store" {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs + "/" + name, isDirectory: &isDir) else { continue }
            if isDir.boolValue { dirs.append(Entry(name: name, isDir: true)) } else { files.append(Entry(name: name, isDir: false)) }
        }
        let order: (Entry, Entry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // The web's cap: a listing is a screenful of names, and node_modules is not a screenful.
        return Array((dirs.sorted(by: order) + files.sorted(by: order)).prefix(3000))
    }

    /// Read one directory (again).
    func load(_ dir: String, then: (() -> Void)? = nil) {
        guard !loading.contains(dir) else { return }
        loading.insert(dir)
        let abs = absolute(dir), repo = self.repo
        let prefix = rootInRepo.isEmpty ? "" : rootInRepo + "/"
        Task {
            let (entries, ignored) = await onUtility { () -> ([Entry], Set<String>) in
                let entries = Self.list(abs)
                guard let repo, !entries.isEmpty else { return (entries, []) }
                let base = prefix + (dir.isEmpty ? "" : dir + "/")
                let hits = GitReader.shared.ignored(entries.map { base + $0.name }, in: repo)
                return (entries, Set(hits.map { ($0 as NSString).lastPathComponent }))
            }
            self.loading.remove(dir)
            self.listings[dir] = entries
            self.ignoredNames[dir] = ignored
            self.rebuildRows()
            then?()
        }
    }

    private func rebuildRows() {
        var out: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            guard let list = listings[dir] else { return }
            let ignored = ignoredNames[dir] ?? []
            for e in list {
                let rel = dir.isEmpty ? e.name : dir + "/" + e.name
                let isIgnored = ignored.contains(e.name)
                if isIgnored && !showIgnored { continue }
                out.append(Row(id: rel, name: e.name, depth: depth, isDir: e.isDir, ignored: isIgnored))
                if e.isDir && expanded.contains(rel) { walk(rel, depth + 1) }
            }
        }
        walk("", 0)
        if out != rows { rows = out }
    }

    func toggle(_ dir: String) {
        if expanded.contains(dir) {
            expanded.remove(dir)
            rebuildRows()
        } else {
            expanded.insert(dir)
            if listings[dir] == nil { load(dir) } else { rebuildRows() }
        }
    }

    /// Open every folder above `rel` and scroll it into view.
    func reveal(_ rel: String) {
        var chain: [String] = []
        var d = Self.parent(rel)
        while !d.isEmpty { chain.insert(d, at: 0); d = Self.parent(d) }
        func step(_ i: Int) {
            guard i < chain.count else { rebuildRows(); revealTarget = rel; return }
            expanded.insert(chain[i])
            if listings[chain[i]] == nil { load(chain[i]) { step(i + 1) } } else { step(i + 1) }
        }
        step(0)
    }

    /// The card's working directory, opened in the tree.
    func revealDirectory(_ abs: String) {
        guard let rel = relative(abs), !rel.isEmpty else { return }
        expanded.insert(rel)
        reveal(rel + "/")
        if listings[rel] == nil { load(rel) }
        revealTarget = rel
    }

    // MARK: - Watching

    private var pendingDirs: Set<String> = []
    private var pendingIndex = false, pendingHead = false, pendingRescan = false
    private var flushTimer: DispatchWorkItem?

    private func received(_ b: ProjectWatcher.Batch) {
        pendingDirs.formUnion(b.dirs)
        pendingIndex = pendingIndex || b.index
        pendingHead = pendingHead || b.head
        pendingRescan = pendingRescan || b.rescan
        guard visible else { return }          // remembered; looked at when the window shows again
        flushTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.flushPending() }
        flushTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: t)
    }

    private func flushPending() {
        let dirs = pendingRescan ? Set(listings.keys) : pendingDirs.intersection(listings.keys)
        for d in dirs { load(d) }
        if pendingRescan { for id in watches.keys { scheduleCheck(id, after: 0.1) } }
        if pendingHead { checkHead(); readBranch() }
        // An agent writing into a folder git already lists as one untracked entry changes nothing git
        // would report: no status for that.
        let worthStatus = pendingIndex || pendingHead || pendingRescan
            || pendingDirs.contains { d in !untrackedDirs.contains { d == $0 || d.hasPrefix($0 + "/") } }
        if worthStatus { requestStatus() }
        pendingDirs.removeAll()
        pendingIndex = false; pendingHead = false; pendingRescan = false
    }

    // MARK: - Git status

    private var statusTimer: DispatchWorkItem?
    private var statusRunning = false, statusAgain = false
    private var lastStatusAt = Date.distantPast
    private var lastStatusTook: TimeInterval = 0
    private var statusCancel: CancelToken?
    private var gitStale = false

    /// Ask for a `git status`, at most this often: every 3 s while the window is in front, every 10 s
    /// behind another window, never while it cannot be seen — and never sooner than five times what
    /// the last one took, so a slow repository is asked less often.
    func requestStatus(after delay: TimeInterval = 1.5) {
        guard repo != nil else { return }
        guard visible else { gitStale = true; return }
        statusTimer?.cancel()
        let minGap = max(isKey ? 3 : 10, lastStatusTook * 5)
        let wait = max(delay, lastStatusAt.addingTimeInterval(minGap).timeIntervalSinceNow)
        let t = DispatchWorkItem { [weak self] in self?.runStatus(attempt: 0) }
        statusTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait), execute: t)
    }

    private func runStatus(attempt: Int) {
        guard let repo, visible else { gitStale = true; return }
        if statusRunning { statusAgain = true; return }
        // An agent's git command holds the index right now: let it finish first.
        if FileManager.default.fileExists(atPath: repo.gitDir + "/index.lock"), attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runStatus(attempt: attempt + 1) }
            return
        }
        statusRunning = true
        gitStale = false
        let token = CancelToken()
        statusCancel = token
        let started = Date()
        Task {
            let entries = await onUtility { GitReader.shared.status(repo, cancel: token) }
            self.statusRunning = false
            self.lastStatusAt = Date()
            self.lastStatusTook = Date().timeIntervalSince(started)
            if let entries { self.apply(entries) }
            if self.statusAgain { self.statusAgain = false; self.requestStatus() }
        }
    }

    private func repoRelative(_ p: String) -> String? {
        if rootInRepo.isEmpty { return p }
        if p == rootInRepo { return "" }
        return p.hasPrefix(rootInRepo + "/") ? String(p.dropFirst(rootInRepo.count + 1)) : nil
    }

    private func apply(_ entries: [GitStatus.Entry]) {
        var m: [String: GitStatus.Mark] = [:], dirs = Set<String>(), untracked = Set<String>(), moved: [String: String] = [:]
        for e in entries {
            var p = e.path
            let isDir = p.hasSuffix("/")
            if isDir { p.removeLast() }
            guard let rel = repoRelative(p), !rel.isEmpty else { continue }
            m[rel] = e.mark
            if isDir { untracked.insert(rel) }
            if let o = e.originalPath, let relO = repoRelative(o) { moved[rel] = relO }
            var d = Self.parent(rel)
            while !d.isEmpty { dirs.insert(d); d = Self.parent(d) }
        }
        if m != marks { marks = m }
        if dirs != dirtyDirs { dirtyDirs = dirs }
        untrackedDirs = untracked
        renames = moved
    }

    /// What HEAD points at, read from the file rather than by running git.
    private func readBranch() {
        guard let repo, let head = try? String(contentsOfFile: repo.gitDir + "/HEAD", encoding: .utf8) else { return }
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        branch = h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst("ref: refs/heads/".count)) : String(h.prefix(8))
        window?.subtitle = subtitle
    }

    var subtitle: String {
        let path = (root as NSString).abbreviatingWithTildeInPath
        return branch.map { "\(path) · ⎇ \($0)" } ?? path
    }

    /// HEAD moved (a commit, a checkout): every open file's baseline may have changed.
    func checkHead() {
        guard let repo else { return }
        Task {
            let commit = await onUtility { GitReader.shared.headCommit(repo) }
            guard commit != self.headCommit else { return }
            let first = self.headCommit == nil
            self.headCommit = commit
            if !first { for t in self.tabs where t.kind == .text { self.editor.call("headChanged", [t.id]) } }
        }
    }

    // MARK: - Tabs

    var active: Tab? { tabs.first { $0.id == activeTab } }

    func docLang(_ id: String) -> String { docs[id]?.lang ?? "plain" }
    func docSize(_ id: String) -> Int64? { docs[id]?.size }
    func docEOL(_ id: String) -> String? {
        guard let d = docs[id], d.base != nil else { return nil }
        return (d.eol == .crlf ? "CRLF" : "LF") + (d.bom ? " · BOM" : "")
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "ico", "svg"]
    static let otherExtensions: Set<String> = ["pdf", "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "dmg", "pkg", "app",
                                               "mp3", "mp4", "mov", "m4a", "wav", "aiff", "sqlite", "db", "jar",
                                               "class", "o", "a", "dylib", "so", "pyc", "woff", "woff2", "ttf", "otf"]

    static func language(for path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "md", "markdown", "mdx": return "markdown"
        case "swift": return "swift"
        case "py", "pyi", "pyw": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "jsx"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "tsx"
        case "json", "jsonc", "jsonl", "resolved", "ipynb", "webmanifest": return "json"
        case "html", "htm", "xhtml": return "html"
        case "xml", "plist", "svg", "xcscheme", "storyboard", "xib", "iml", "entitlements": return "xml"
        case "css", "scss", "less": return "css"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash", "zsh", "fish", "command": return "shell"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return "cpp"
        case "java", "kt", "kts", "scala", "groovy", "gradle": return "java"
        case "sql": return "sql"
        case "rb": return "ruby"
        case "lua": return "lua"
        case "diff", "patch": return "diff"
        case "ini", "cfg", "conf", "properties", "env": return "properties"
        default: break
        }
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "dockerfile" }
        if [".gitignore", ".gitattributes", ".dockerignore", ".npmrc", ".editorconfig", ".env"].contains(name)
            || name.hasPrefix(".env.") { return "properties" }
        if [".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile"].contains(name) { return "shell" }
        if name == "makefile" || name == "gnumakefile" { return "shell" }
        // No extension: the first line may say (`scripts/project-manager` is Python).
        if ext.isEmpty, let h = FileHandle(forReadingAtPath: path) {
            let first = String(decoding: h.readData(ofLength: 120), as: UTF8.self)
            try? h.close()
            if first.hasPrefix("#!") {
                if first.contains("python") { return "python" }
                if first.contains("node") { return "javascript" }
                if first.contains("sh") { return "shell" }
                if first.contains("ruby") { return "ruby" }
            }
        }
        return "plain"
    }

    private static func fileSize(_ abs: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: abs))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Open a file in a tab — the preview tab unless `pin` — or reveal a folder.
    func open(_ rel: String, pin: Bool = false, line: Int? = nil, find: String? = nil) {
        let abs = absolute(rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir) else {
            showToast(L(.filesMissing))
            return
        }
        if isDir.boolValue { toggle(rel); reveal(rel); return }
        if let i = tabs.firstIndex(where: { $0.path == rel }) {
            if pin { tabs[i].pinned = true }
            activate(tabs[i].id, line: line, find: find)
            return
        }
        let size = Self.fileSize(abs)
        if size > 100_000_000, !confirmLarge(rel, size: size) { return }

        let ext = (abs as NSString).pathExtension.lowercased()
        let kind: Kind = Self.imageExtensions.contains(ext) ? .image : (Self.otherExtensions.contains(ext) ? .other : .text)
        let lang = Self.language(for: abs)
        let id = UUID().uuidString
        let tab = Tab(id: id, path: rel, pinned: pin, kind: kind, mode: lang == "markdown" ? .preview : .source)
        if !pin, let i = tabs.firstIndex(where: { !$0.pinned && !$0.dirty }) {
            let old = tabs[i].id
            tabs[i] = tab
            dispose(old)
        } else if let a = tabs.firstIndex(where: { $0.id == activeTab }) {
            tabs.insert(tab, at: a + 1)
        } else {
            tabs.append(tab)
        }
        docs[id] = Doc(abs: abs, lang: lang, size: size)
        activeTab = id
        status = Status()
        if kind == .text { watch(id) }

        var meta: [String: Any] = ["path": abs, "lang": lang, "mode": tab.mode.rawValue, "kind": kind == .text ? "text" : "info"]
        if let line { meta["line"] = line }
        if let find { meta["find"] = find }
        if kind == .image {
            meta["info"] = ["kind": "image", "url": Self.rawURL(abs), "detail": Self.sizeText(size)]
        } else if kind == .other {
            meta["info"] = binaryInfo(rel, size: size)
        }
        editor.call("open", [id, meta]) { [weak self] r in
            guard let self, let r = r as? [String: Any] else { return }
            if let reason = r["reason"] as? String, !reason.isEmpty, let i = self.tabs.firstIndex(where: { $0.id == id }) {
                self.tabs[i].readOnly = reason
            }
        }
        noteOpened(rel)
        reveal(rel)
    }

    static func rawURL(_ abs: String) -> String {
        "fvfile://app/raw" + abs.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
        }.reduce("") { $0 + "/" + $1 }
    }

    static func sizeText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func binaryInfo(_ rel: String, size: Int64) -> [String: Any] {
        ["kind": "binary", "title": (rel as NSString).lastPathComponent, "detail": L(.filesBinaryDetail(Self.sizeText(size))),
         "actions": [["id": "openDefault", "label": L(.filesOpenDefault)], ["id": "reveal", "label": L(.filesReveal)]]]
    }

    private func confirmLarge(_ rel: String, size: Int64) -> Bool {
        let a = NSAlert()
        a.messageText = L(.filesLargeTitle((rel as NSString).lastPathComponent, Self.sizeText(size)))
        a.informativeText = L(.filesLargeBody)
        a.addButton(withTitle: L(.filesOpen))
        a.addButton(withTitle: L(.cancel))
        return a.runModal() == .alertFirstButtonReturn
    }

    func activate(_ id: String, line: Int? = nil, find: String? = nil) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTab = id
        status = Status()
        editor.call("show", [id]) { [weak self] _ in
            guard let self else { return }
            if self.docs[id]?.stale == true, self.tabs.first(where: { $0.id == id })?.dirty == false {
                self.docs[id]?.stale = false
                self.editor.call("reload", [id])
            }
            if let line { self.editor.call("goto", [id, line]) }
            if let find { self.editor.call("find", [find]) }
        }
        if let rel = tabs.first(where: { $0.id == id })?.path { reveal(rel); noteOpened(rel) }
    }

    func pin(_ id: String) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].pinned = true }
    }

    func setMode(_ id: String, _ mode: Mode) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].mode = mode
        editor.call("setMode", [id, mode.rawValue])
    }

    func toggleWrap(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].wrap.toggle()
        editor.call("setWrap", [id, tabs[i].wrap])
    }

    /// Close a tab; unsaved edits are asked about first.
    func close(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard tab.dirty else { closeNow(id); return }
        askAboutUnsaved([tab]) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .save: self.saveTabs([tab]) { ok in if ok { self.closeNow(id) } }
            case .discard:
                if let d = self.docs[id] { FileRecovery.remove(path: d.abs) }
                self.closeNow(id)
            case .cancel: break
            }
        }
    }

    private func closeNow(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        dispose(id)
        if activeTab == id {
            activeTab = nil
            if !tabs.isEmpty { activate(tabs[min(i, tabs.count - 1)].id) }
        }
        updateEdited()
    }

    private func dispose(_ id: String) {
        editor.call("close", [id])
        watches.removeValue(forKey: id)?.cancel()
        checks.removeValue(forKey: id)?.cancel()
        docs.removeValue(forKey: id)
        banners.removeValue(forKey: id)
    }

    func closeActive() { if let a = activeTab { close(a) } }

    private func updateEdited() {
        window?.isDocumentEdited = tabs.contains { $0.dirty }
    }

    // MARK: - Serving the page

    func serve(_ kind: String, _ rest: String) async -> EditorBridge.Response {
        switch kind {
        case "doc": return await serveDoc(rest, updateBase: true)
        case "disk": return await serveDoc(rest, updateBase: false)
        case "head": return await serveHead(rest)
        case "raw": return await serveRaw(rest)
        default: return .notFound
        }
    }

    private enum Read: Sendable {
        case missing
        case binary(Int64)
        case notUTF8(Int64)
        case text(FileText.Decoded, String, FileSave.Fingerprint?, Int64, Bool)
    }

    private nonisolated static func read(_ abs: String) -> Read {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: abs), options: .alwaysMapped) else { return .missing }
        let size = Int64(data.count)
        if FileText.isBinary(data) { return .binary(size) }
        guard let d = FileText.decode(data) else { return .notUTF8(size) }
        return .text(d, FileText.version(data), FileSave.fingerprint(path: abs), size, access(abs, W_OK) == 0)
    }

    /// The text of a tab's file, LF-only. `updateBase`: this is what the editor will now hold, so it
    /// is the version a save is checked against.
    private func serveDoc(_ id: String, updateBase: Bool) async -> EditorBridge.Response {
        guard let doc = docs[id] else { return .notFound }
        let abs = doc.abs
        let r = await onUtility { Self.read(abs) }
        let name = (abs as NSString).lastPathComponent
        switch r {
        case .missing:
            return .json(404, ["kind": "missing", "title": L(.filesMissing), "detail": name])
        case .binary(let size):
            return .json(415, binaryInfo(relative(abs) ?? name, size: size))
        case .notUTF8(let size):
            return .json(415, ["kind": "binary", "title": name, "detail": L(.filesNotUTF8(Self.sizeText(size))),
                               "actions": [["id": "openDefault", "label": L(.filesOpenDefault)]]])
        case .text(let decoded, let version, let fp, let size, let writable):
            var reason = decoded.readOnlyReason?.rawValue
            if reason == nil && !writable { reason = FileText.ReadOnly.notWritable.rawValue }
            if updateBase, var d = docs[id] {
                d.base = version
                d.eol = decoded.eol
                d.bom = decoded.bom
                d.fingerprint = fp
                d.size = size
                d.stale = false
                docs[id] = d
                if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].readOnly = reason }
                offerRecovery(id)
            }
            var headers: [String: String] = [:]
            if let reason { headers["X-FV-ReadOnly"] = reason }
            return EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8",
                                         data: Data(decoded.text.utf8), headers: headers)
        }
    }

    /// The file as HEAD has it, LF-only like the editor's text, for the tint of changed lines.
    /// 404 — no tint — for a file HEAD does not have (new, untracked, no commits yet) and for files
    /// above 20 MB, where the page does not diff anyway.
    func serveHead(_ id: String) async -> EditorBridge.Response {
        guard let doc = docs[id], repo != nil, doc.size <= 20_000_000 else { return .notFound }
        var target = doc.abs
        // A rename staged in the index: HEAD has the file under its old name.
        if let rel = relative(doc.abs), let old = renames[rel] { target = absolute(old) }
        let file = target
        let data: Data? = await onUtility {
            guard let blob = GitReader.shared.headBlob(file: file) else { return nil }
            if let hit = BlobCache.shared.get(blob.oid) { return hit }
            guard let d = GitReader.shared.checkedOut(oid: blob.oid, path: blob.path, near: file) else { return nil }
            BlobCache.shared.put(blob.oid, d)
            return d
        }
        // Decoded the same way as the working file, so line endings never count as a change.
        guard let data, let text = FileText.decode(data) else { return .notFound }
        return EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8", data: Data(text.text.utf8))
    }

    private func serveRaw(_ path: String) async -> EditorBridge.Response {
        // Images in a rendered document, and image tabs: only from inside the project.
        guard relative(path) != nil else { return .notFound }
        let data = await onUtility { try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }
        guard let data else { return .notFound }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "svg": mime = "image/svg+xml"
        case "bmp": mime = "image/bmp"
        case "tif", "tiff": mime = "image/tiff"
        case "heic": mime = "image/heic"
        case "ico": mime = "image/x-icon"
        default: mime = "application/octet-stream"
        }
        return EditorBridge.Response(status: 200, mime: mime, data: data)
    }

    // MARK: - Messages from the page

    func editorReady() {}

    /// The page came back after its process died: open the tabs again, and put back unsaved text.
    func editorCrashed() {
        let open = tabs
        let current = activeTab
        for t in open {
            guard let d = docs[t.id] else { continue }
            var meta: [String: Any] = ["path": d.abs, "lang": d.lang, "mode": t.mode.rawValue,
                                       "kind": t.kind == .text ? "text" : "info"]
            if t.kind == .image { meta["info"] = ["kind": "image", "url": Self.rawURL(d.abs), "detail": Self.sizeText(d.size)] }
            if t.kind == .other { meta["info"] = binaryInfo(t.path, size: d.size) }
            editor.call("open", [t.id, meta])
            if t.dirty, let entry = FileRecovery.load(path: d.abs) {
                editor.call("restore", [t.id, entry.text])
                banners[t.id] = .crashRestored
            }
        }
        if let current { editor.call("show", [current]) }
    }

    func editorMessage(_ type: String, _ body: [String: Any]) async -> Any? {
        let tab = body["tab"] as? String
        switch type {
        case "dirty":
            if let tab, let i = tabs.firstIndex(where: { $0.id == tab }) {
                let dirty = body["dirty"] as? Bool ?? false
                tabs[i].dirty = dirty
                if dirty { tabs[i].pinned = true }        // an edited preview tab must not be replaced
                updateEdited()
            }
        case "snapshot":
            if let tab, let d = docs[tab], let text = body["text"] as? String {
                FileRecovery.write(path: d.abs, base: d.base, text: text)
            }
        case "save":
            if let tab, let text = body["text"] as? String { return await save(tab, text: text, force: false) }
        case "saveMerged":
            if let tab, let text = body["text"] as? String { return await save(tab, text: text, force: true) }
        case "cursor":
            if tab == activeTab {
                status.line = body["line"] as? Int ?? 0
                status.col = body["col"] as? Int ?? 0
                status.lines = body["lines"] as? Int ?? 0
            }
        case "diffStats":
            if tab == activeTab {
                status.added = body["added"] as? Int ?? 0
                status.changed = body["changed"] as? Int ?? 0
                status.deleted = body["deleted"] as? Int ?? 0
                status.noHead = body["none"] as? Bool ?? false
                status.hasDiff = true
            }
        case "link":
            if let href = body["href"] as? String, let from = body["from"] as? String { followLink(href, from: from) }
        case "key":
            if let name = body["name"] as? String { key(name) }
        case "action":
            if let tab, let id = body["id"] as? String, let d = docs[tab] {
                if id == "openDefault" { NSWorkspace.shared.open(URL(fileURLWithPath: d.abs)) }
                if id == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.abs)]) }
            }
        case "mode":
            if let tab, let m = (body["mode"] as? String).flatMap(Mode.init(rawValue:)),
               let i = tabs.firstIndex(where: { $0.id == tab }) { tabs[i].mode = m }
        default: break
        }
        return nil
    }

    /// A window-level key, from the page or from the window's own shortcuts — the same press can
    /// arrive both ways, so a repeat within a moment is the same press.
    func key(_ name: String) {
        if lastKey.0 == name && Date().timeIntervalSince(lastKey.1) < 0.25 { return }
        lastKey = (name, Date())
        switch name {
        case "closeTab": closeActive()
        case "save": editor.call("saveActive")
        default: keyHook?(name)
        }
    }

    /// Phase 4's keys (quick open, search, back and forward) plug in here.
    var keyHook: ((String) -> Void)?

    private func followLink(_ href: String, from: String) {
        if href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:") {
            if let url = URL(string: href) { NSWorkspace.shared.open(url) }
            return
        }
        let target = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !target.isEmpty else { return }
        let decoded = target.removingPercentEncoding ?? target
        let base = (from as NSString).deletingLastPathComponent
        let abs = decoded.hasPrefix("/") ? root + decoded : URL(fileURLWithPath: base).appendingPathComponent(decoded).standardizedFileURL.path
        guard let rel = relative(abs) else { showToast(L(.filesOutside)); return }
        open(rel, pin: true)
    }

    // MARK: - Saving

    private func save(_ id: String, text: String, force: Bool) async -> [String: Any] {
        guard let doc = docs[id] else { return ["error": "gone"] }
        let bytes = FileText.encode(text, eol: doc.eol, bom: doc.bom)
        let abs = doc.abs, base = doc.base
        let outcome = await onUtility { FileSave.save(bytes, to: abs, base: base, force: force) }
        let rel = relative(abs) ?? abs
        switch outcome {
        case .saved(let version, let fp):
            docs[id]?.base = version
            docs[id]?.fingerprint = fp
            docs[id]?.size = Int64(bytes.count)
            banners.removeValue(forKey: id)
            FileRecovery.remove(path: abs)
            app?.audit.emit("fleetview.file.saved", categories: ["file"], message: "saved \(rel)",
                            data: ["path": .string(abs), "file.bytes": .int(bytes.count),
                                   "file.sha256": .string(version), "file.base": base.map { .string($0) } ?? .null,
                                   "forced": .bool(force), "source": .string("desktop")])
            requestStatus(after: 0.3)
            return ["ok": true]
        case .conflict(let current):
            banners[id] = .diskChanged
            app?.audit.emit("fleetview.file.save_conflict", categories: ["file"], message: "not saved, changed on disk: \(rel)",
                            data: ["path": .string(abs), "file.base": base.map { .string($0) } ?? .null,
                                   "file.sha256": current.map { .string($0) } ?? .null])
            return ["conflict": true]
        case .failed(let why):
            banners[id] = .failed(why)
            return ["error": why]
        }
    }

    enum UnsavedChoice { case save, discard, cancel }

    func askAboutUnsaved(_ list: [Tab], reason: String? = nil, _ done: @escaping (UnsavedChoice) -> Void) {
        let a = NSAlert()
        if list.count == 1 {
            a.messageText = L(.filesUnsavedOne((list[0].path as NSString).lastPathComponent))
        } else {
            a.messageText = L(.filesUnsavedMany(list.count))
        }
        a.informativeText = reason ?? L(.filesUnsavedBody)
        a.addButton(withTitle: list.count == 1 ? L(.save) : L(.filesSaveAll))
        a.addButton(withTitle: L(.cancel))
        a.addButton(withTitle: L(.filesDontSave))
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            switch r {
            case .alertFirstButtonReturn: done(.save)
            case .alertThirdButtonReturn: done(.discard)
            default: done(.cancel)
            }
        }
        if let window, window.isVisible { a.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(a.runModal()) }
    }

    /// Save these tabs' current text. `done(false)` when any of them could not be saved (its banner
    /// says why).
    func saveTabs(_ list: [Tab], done: @escaping (Bool) -> Void) {
        editor.call("dirtyTexts") { [weak self] result in
            guard let self else { return }
            let wanted = Set(list.map(\.id))
            let texts = (result as? [[String: Any]] ?? []).compactMap { e -> (String, String)? in
                guard let t = e["tab"] as? String, wanted.contains(t), let s = e["text"] as? String else { return nil }
                return (t, s)
            }
            Task {
                var ok = true
                for (tab, text) in texts {
                    let r = await self.save(tab, text: text, force: false)
                    if r["ok"] as? Bool == true { self.editor.call("markSaved", [tab, text]) } else { ok = false }
                }
                done(ok)
            }
        }
    }

    var unsavedTabs: [Tab] { tabs.filter(\.dirty) }

    func discardAll() {
        for t in unsavedTabs {
            if let d = docs[t.id] { FileRecovery.remove(path: d.abs) }
            editor.call("discard", [t.id])
        }
    }

    // MARK: - Disk changes to open files

    private func watch(_ id: String) {
        guard let d = docs[id] else { return }
        watches[id] = FileWatch(path: d.abs) { [weak self] in self?.fileEvent(id) }
    }

    private func fileEvent(_ id: String) {
        guard let d = docs[id] else { return }
        // Small files are looked at after a short pause; mid-size ones at most every 5 s (a log being
        // appended to); huge ones only get a banner.
        let wait: TimeInterval = d.size <= 1_000_000 ? 0.3 : (d.size <= 20_000_000 ? 5 : 0.5)
        scheduleCheck(id, after: wait)
    }

    private func scheduleCheck(_ id: String, after wait: TimeInterval) {
        checks[id]?.cancel()
        let t = DispatchWorkItem { [weak self] in Task { await self?.check(id) } }
        checks[id] = t
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: t)
    }

    private func check(_ id: String, recheck: Bool = false) async {
        guard let d = docs[id], let tab = tabs.first(where: { $0.id == id }) else { return }
        guard let fp = FileSave.fingerprint(path: d.abs) else {
            // Gone — or a checkout deleting and recreating it. Look again before saying so.
            if !recheck {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await check(id, recheck: true)
            } else {
                banners[id] = .deleted
            }
            return
        }
        watches[id]?.arm()                     // the inode may be new (an atomic write by an agent)
        if banners[id] == .deleted { banners.removeValue(forKey: id) }
        if fp == d.fingerprint { return }      // our own save, or nothing that changed the bytes
        let abs = d.abs
        let version = await onUtility { FileManager.default.contents(atPath: abs).map(FileText.version) }
        guard docs[id] != nil else { return }
        if version == docs[id]?.base { docs[id]?.fingerprint = fp; return }
        if tab.dirty || d.size > 20_000_000 {
            banners[id] = .diskChanged
        } else if id == activeTab && visible {
            editor.call("reload", [id])
        } else {
            docs[id]?.stale = true
        }
    }

    /// The banner's three ways out of a disk change under unsaved edits.
    func useDiskVersion(_ id: String) {
        banners.removeValue(forKey: id)
        if let d = docs[id] { FileRecovery.remove(path: d.abs) }
        editor.call("useDisk", [id])
    }

    func compare(_ id: String) { editor.call("compare", [id]) }

    func overwrite(_ id: String) {
        editor.call("text", [id]) { [weak self] r in
            guard let self, let text = r as? String else { return }
            Task {
                let out = await self.save(id, text: text, force: true)
                if out["ok"] as? Bool == true { self.editor.call("markSaved", [id, text]) }
            }
        }
    }

    func dismissBanner(_ id: String) { banners.removeValue(forKey: id) }

    // MARK: - Recovery

    private func offerRecovery(_ id: String) {
        guard var d = docs[id], !d.recoveryOffered else { return }
        d.recoveryOffered = true
        docs[id] = d
        guard let entry = FileRecovery.load(path: d.abs) else { return }
        banners[id] = .recovered(entry.at, sameBase: entry.base == d.base)
    }

    func restoreRecovered(_ id: String) {
        guard let d = docs[id], let entry = FileRecovery.load(path: d.abs) else { return }
        banners.removeValue(forKey: id)
        editor.call("restore", [id, entry.text])
    }

    func discardRecovered(_ id: String) {
        guard let d = docs[id] else { return }
        banners.removeValue(forKey: id)
        FileRecovery.remove(path: d.abs)
    }

    // MARK: - Small things

    func showToast(_ text: String) {
        toast = text
        toastTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: t)
    }

    func copyPath(_ rel: String, relativeOnly: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativeOnly ? rel : absolute(rel), forType: .string)
        showToast(L(.filesCopied))
    }

    /// Phase 5's "recently changed" list hears about every file opened, too.
    var openedHook: ((String) -> Void)?
    private func noteOpened(_ rel: String) { openedHook?(rel) }

    // MARK: - Reference in a card

    /// The project's terminals that can take text now.
    var referenceTargets: [TerminalSession] {
        (app?.terminals(inProject: projectId) ?? []).filter { $0.status.isOpen }
    }

    /// Put the file's path into a terminal's input, without pressing Return.
    func reference(_ rel: String, in terminal: TerminalSession) {
        let abs = absolute(rel)
        var path = abs
        let cwd = URL(fileURLWithPath: (terminal.cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        if abs.hasPrefix(cwd + "/") { path = String(abs.dropFirst(cwd.count + 1)) }
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        let text = (terminal.agentKind == .claude ? "@" : "") + quoted + " "
        app?.insertText(terminal.id, text, why: "file.reference")
        showToast(L(.filesReferenced(terminal.name)))
    }
}
