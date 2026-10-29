import AppKit
import FleetViewFiles

/// Finding files: quick open (⌘P), the tree's name filter, search in files (⌘⇧F), back and forward.
///
/// None of it walks a project. The list of names is `git ls-files` — tracked files, plus untracked
/// ones, an untracked folder opened up only when it is small (one project here has eight million
/// untracked files in two folders) — fetched the first time it is wanted and again only when the
/// index moved and it is more than 30 s old. Search is `git grep` over the same files, cancelled by
/// the next search. A folder that is not a repository is walked with a limit, skipping build output
/// and dependencies.
extension FileBrowserModel {
    struct SearchGroup: Identifiable, Equatable {
        let path: String
        var hits: [GrepHit]
        var id: String { path }
    }

    enum SearchState: Equatable {
        case idle
        case running
        case done(matches: Int, files: Int, truncated: Bool)
    }

    // MARK: - The list of files

    /// The project's file names (relative to its root), fetched if missing or stale.
    ///
    /// Untracked files count — they are usually what an agent just wrote. A wholly untracked folder
    /// is opened up when a short walk finishes it (0.3 s, 2 000 files); one that is bigger stays a
    /// single entry, which is what keeps a folder of millions of untracked job outputs from costing
    /// anything.
    ///
    /// One fetch at a time: callers arriving meanwhile wait for it. A list that is merely old is
    /// answered from at once and fetched again behind the answer — typing in quick open must not wait
    /// on `git ls-files` because an agent committed.
    func withFileIndex(_ then: @escaping ([String]) -> Void) {
        if let idx = fileIndex {
            then(idx)
            if fileIndexStale && Date().timeIntervalSince(fileIndexAt) > 30 { refreshFileIndex(nil) }
            return
        }
        refreshFileIndex(then)
    }

    private func refreshFileIndex(_ then: (([String]) -> Void)?) {
        if let then { fileIndexWaiters.append(then) }
        guard !fileIndexLoading else { return }
        fileIndexLoading = true
        let repo = self.repo, root = self.root, prefix = rootInRepo.isEmpty ? "" : rootInRepo + "/"
        Task {
            let (names, untracked) = await onUtility { () -> ([String], [String]) in
                guard let repo else { return (ProjectFiles.walk(root).files, []) }
                func mine(_ p: String) -> String? {
                    prefix.isEmpty ? p : (p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : nil)
                }
                var names = (GitReader.shared.trackedFiles(repo) ?? []).compactMap(mine)
                var untracked: [String] = []
                var budget = 2_000
                // 0.3 s per folder, 1.5 s for all of them: a hundred small untracked folders must not
                // add up to half a minute.
                let deadline = Date().addingTimeInterval(1.5)
                for e in (GitReader.shared.untrackedEntries(repo) ?? []) {
                    guard let p = mine(e) else { continue }
                    if !p.hasSuffix("/") { untracked.append(p); continue }
                    let left = deadline.timeIntervalSinceNow
                    let walk: (files: [String], complete: Bool) =
                        budget > 0 && left > 0 ? ProjectFiles.walk(root + "/" + p, limit: budget, budget: min(0.3, left)) : ([], false)
                    if walk.complete {
                        untracked += walk.files.map { p + $0 }
                        budget -= walk.files.count
                    } else {
                        names.append(p)              // too big to open up: one entry, never searched
                    }
                }
                return (names + untracked, untracked)
            }
            self.fileIndex = names
            self.untrackedFiles = untracked
            self.fileIndexAt = Date()
            self.fileIndexStale = false
            self.fileIndexLoading = false
            let waiting = self.fileIndexWaiters
            self.fileIndexWaiters.removeAll()
            waiting.forEach { $0(names) }
        }
    }

    // MARK: - The tree's filter

    func runFilter() {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { filterResults = []; return }
        findGeneration += 1
        let gen = findGeneration
        withFileIndex { [weak self] names in
            guard let self else { return }
            Task {
                let hits = await onUtility { Array(names.lazy.filter { ($0 as NSString).lastPathComponent.lowercased().contains(q) }.prefix(500)) }
                if gen == self.findGeneration { self.filterResults = hits }
            }
        }
    }

    // MARK: - Quick open

    func showQuickOpen() {
        quickQuery = ""
        quickSelection = 0
        quickOpen = true
        runQuickOpen()
    }

    /// Empty query: files opened recently, then files with changes. Otherwise the best fuzzy matches.
    func runQuickOpen() {
        let q = quickQuery
        findGeneration += 1
        let gen = findGeneration
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            var seen = Set<String>()
            var list: [String] = []
            for p in recentOpened + marks.keys.sorted() where !seen.contains(p) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: absolute(p), isDirectory: &isDir), !isDir.boolValue else { continue }
                seen.insert(p)
                list.append(p)
            }
            quickResults = list.prefix(30).map { FuzzyMatch.Match(path: $0, score: 0, positions: []) }
            quickSelection = 0
            return
        }
        withFileIndex { [weak self] names in
            guard let self else { return }
            Task {
                let best = await onUtility { FuzzyMatch.best(q, in: names, limit: 60) }
                guard gen == self.findGeneration else { return }
                self.quickResults = best
                self.quickSelection = 0
            }
        }
    }

    func quickMove(_ delta: Int) {
        guard !quickResults.isEmpty else { return }
        quickSelection = (quickSelection + delta + quickResults.count) % quickResults.count
    }

    func quickPick(_ index: Int? = nil, pin: Bool = false) {
        let i = index ?? quickSelection
        guard quickResults.indices.contains(i) else { return }
        let path = quickResults[i].path
        quickOpen = false
        open(path.hasSuffix("/") ? String(path.dropLast()) : path, pin: pin)
    }

    // MARK: - Search in files

    /// Tracked files through `git grep`, plus the untracked ones the file list opened up (see
    /// `withFileIndex`) — never a whole untracked folder.
    func runSearch() {
        searchCancel?.cancel()
        let q = searchQuery
        guard q.count >= 2 else { searchResults = []; searchState = .idle; return }
        let token = CancelToken()
        searchCancel = token
        searchState = .running
        withFileIndex { [weak self] _ in self?.search(q, token: token) }
    }

    private func search(_ q: String, token: CancelToken) {
        let repo = self.repo, root = self.root, sub = rootInRepo, cs = searchCaseSensitive
        let prefix = sub.isEmpty ? "" : sub + "/"
        let extra = (untrackedFiles ?? []).map { prefix + $0 }
        Task {
            let result = await onUtility { () -> GrepResult in
                guard let repo else { return ProjectFiles.grep(q, in: root, caseSensitive: cs, cancel: token) }
                let tracked = GitReader.shared.grep(q, in: repo, under: sub.isEmpty ? nil : sub, caseSensitive: cs, cancel: token)
                guard !extra.isEmpty, !token.isCancelled, tracked.hits.count < 1000 else { return tracked }
                let more = GitReader.shared.grepFiles(q, extra, in: repo, caseSensitive: cs,
                                                       maxHits: 1000 - tracked.hits.count, cancel: token)
                return GrepResult(hits: tracked.hits + more.hits, truncated: tracked.truncated || more.truncated)
            }
            guard !token.isCancelled else { return }
            var groups: [SearchGroup] = []
            var index: [String: Int] = [:]
            for hit in result.hits {
                let path = repo == nil || prefix.isEmpty ? hit.path
                    : (hit.path.hasPrefix(prefix) ? String(hit.path.dropFirst(prefix.count)) : hit.path)
                let h = GrepHit(path: path, line: hit.line, text: hit.text.trimmingCharacters(in: .whitespaces))
                if let i = index[path] { groups[i].hits.append(h) } else { index[path] = groups.count; groups.append(SearchGroup(path: path, hits: [h])) }
            }
            self.searchResults = groups
            self.searchState = .done(matches: result.hits.count, files: groups.count, truncated: result.truncated)
        }
    }

    func openHit(_ hit: GrepHit) {
        open(hit.path, line: hit.line, find: searchQuery)
    }

    // MARK: - Back and forward

    func noteVisit(_ rel: String) {
        if navigating { return }
        if backStack.last == rel { return }
        backStack.append(rel)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
        updateNav()
    }

    func goBack() {
        guard backStack.count > 1 else { return }
        forwardStack.append(backStack.removeLast())
        visit(backStack.last!)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(next)
        visit(next)
    }

    private func visit(_ rel: String) {
        navigating = true
        open(rel, pin: true)
        navigating = false
        updateNav()
    }

    private func updateNav() {
        // Assigned only when they change: each assignment redraws the window.
        if canGoBack != (backStack.count > 1) { canGoBack = backStack.count > 1 }
        if canGoForward != !forwardStack.isEmpty { canGoForward = !forwardStack.isEmpty }
    }
}
