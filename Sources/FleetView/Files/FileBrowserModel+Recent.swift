import Foundation

/// "Recently changed": what moved in the project lately, newest first, with who did it when known.
///
/// Built from three things that are already at hand, never from a walk of the project: the files
/// git reports as changed, the files in directories the watcher reported since the window opened,
/// and the agents' own record of what they wrote (FileEdits). A file's time is its modification
/// time; its author is the card whose write is recorded at that time, and nobody otherwise.
extension FileBrowserModel {
    /// Look at the files in directories that just changed (a bounded number), for ones modified since
    /// the window opened.
    func observe(_ dirs: Set<String>) {
        let root = self.root, since = openedAt
        let list = Array(dirs.prefix(30))
        Task {
            let found = await onUtility { () -> [String: Date] in
                var out: [String: Date] = [:]
                let fm = FileManager.default
                for d in list {
                    let abs = d.isEmpty ? root : root + "/" + d
                    guard let names = try? fm.contentsOfDirectory(atPath: abs) else { continue }
                    for n in names.prefix(400) where n != ".DS_Store" {
                        let p = abs + "/" + n
                        guard let a = try? fm.attributesOfItem(atPath: p), (a[.type] as? FileAttributeType) == .typeRegular,
                              let m = a[.modificationDate] as? Date, m >= since else { continue }
                        out[d.isEmpty ? n : d + "/" + n] = m
                    }
                }
                return out
            }
            guard !found.isEmpty else { return }
            self.observedChanges.merge(found) { max($0, $1) }
            if self.observedChanges.count > 300 {
                let keep = self.observedChanges.sorted { $0.value > $1.value }.prefix(200)
                self.observedChanges = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            self.refreshRecent(after: 0.3)
        }
    }

    func refreshRecent(after delay: TimeInterval = 0.8) {
        recentTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.buildRecent() }
        recentTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: t)
    }

    private func buildRecent() {
        guard visible else { return }
        let root = self.root
        var candidates = Set(marks.compactMap { $0.value == .deleted || untrackedDirs.contains($0.key) ? nil : $0.key }.prefix(200))
        candidates.formUnion(observedChanges.keys)
        let edits = FileEdits.shared.recent(under: root)
        for e in edits { candidates.insert(String(e.path.dropFirst(root.count + 1))) }
        let list = Array(candidates)
        Task {
            let times = await onUtility { () -> [(String, Date)] in
                list.compactMap { rel -> (String, Date)? in
                    guard let a = try? FileManager.default.attributesOfItem(atPath: root + "/" + rel),
                          (a[.type] as? FileAttributeType) == .typeRegular,
                          let m = a[.modificationDate] as? Date else { return nil }
                    return (rel, m)
                }
            }
            let byPath = Dictionary(edits.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let out = times.sorted { $0.1 > $1.1 }.prefix(8).map { rel, m -> Recent in
                // The recorded write is the author only if nothing touched the file well after it.
                let e = byPath[root + "/" + rel]
                let by = e.flatMap { $0.at >= m.addingTimeInterval(-120) ? $0.terminalName : nil }
                return Recent(path: rel, at: m, by: by)
            }
            if Array(out) != self.recent { self.recent = Array(out) }
        }
    }
}
