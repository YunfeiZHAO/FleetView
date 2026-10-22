import Foundation

/// The session tree for Codex, built into the same `TreeGraph` the Claude panel renders.
///
/// Nothing about Codex's storage helps. Rollouts are filed by DATE, not by project, so there is no
/// directory that means "this conversation"; and a fork copies the parent's turns into a new file
/// **with every timestamp rewritten to the fork moment** — measured on this corpus: 589 turns
/// identical in text, not one identical in time. So neither the filesystem nor the clock can stitch
/// a tree, and `forked_from_id` names the parent session without saying where the split happened.
///
/// What survives copying is the conversation itself. Identity here is therefore a chain hash over
/// prompt text: a turn's id folds in every prompt before it, so a copied prefix produces exactly the
/// same ids as the original and the first divergence produces different ones. The fork attaches at
/// the point it actually forked without anything having had to record where that was — and two
/// sessions that merely *begin* alike stay merged only for as long as they really are alike.
///
/// Paginated rollouts (0.147+) stopped copying. A fork's file holds only what came after the fork
/// and names the rest with `history_base` — the parent rollout and the byte where its share ends —
/// and Esc Esc (`thread/revert`, 0.155+) does the same within ONE thread: a new file
/// `rollout-<ts>-<thread>_<rollout>.jsonl` continuing the old one up to the reverted turn, the old
/// file left whole. Read alone, such a file is a conversation that starts mid-air: a fork came out
/// as a root of its own, and a revert's segment, which shares its thread id, numbered its first
/// turn `<thread>:0` and overwrote the original's first turn — drawing a lineage that never
/// happened. So a rollout's turns are read through its base chain (`history`), which hashes the
/// referenced prefix exactly as a copied one would, and the chain hash still does the stitching.
///
/// Nodes are ADDRESSED the way treeflow addresses them — `<rollout-id>:<n>`, n counting user
/// prompts in file order — because that address is what opens a node (see `SearchOpen.planCodex`,
/// and `SearchIndex`, which numbers its hits identically). The rollout id is the thread id for every
/// file but a revert's segment, which is how addresses written before segments existed stay valid.
/// Identity dedupes; the address names. A shared turn takes the address of the earliest rollout
/// holding it, so a fork points at the original rather than at its own copy.
enum CodexTree {

    /// Where a rollout's history continues from: the rollout holding the earlier turns, and the
    /// byte in it where they stop. Written by a fork and by Esc Esc (`thread/revert`) since Codex's
    /// rollouts became paginated — the file then holds only what came after that point.
    struct HistoryBase {
        let rollout: String
        let endByte: Int?
    }

    /// A rollout's head record, which is fixed for the life of the file.
    struct Meta {
        let path: String
        let sid: String
        /// The rollout's own id. The thread id, except in a revert's segment
        /// (`rollout-<ts>-<thread>_<rollout>.jsonl`): one thread then owns several files, and a
        /// node is addressed by the file it is in, not by the thread.
        let rolloutId: String
        let base: HistoryBase?
        let cwd: String
        let started: String       // ISO8601 from the head record; also the sort key
        let forkedFrom: String?
        /// The thread that spawned this one, when it is a worker. Kept rather than dropped so a
        /// terminal that has been attributed to a worker can still be walked back to the
        /// conversation it belongs to.
        let parentThread: String?
        /// A thread another thread spawned — a multi-agent worker — never a conversation someone
        /// typed into. Not the same test as `parentThread != nil`: Codex 0.136 marked its workers
        /// only inside `source`, with no top-level parent id, so 139 of them here read as
        /// conversations of their own.
        let isWorker: Bool
        var isMainLine: Bool { !isWorker }
    }

    // MARK: - The rollout index

    /// Heads are immutable once written, so this is keyed by path alone. It matters: a full index
    /// pass opens ~2000 files and each head runs to ~19 KB (Codex puts the whole base instruction
    /// set on it), and the panel's refresh tick would otherwise pay that every two seconds.
    private static var metaCache: [String: Meta?] = [:]
    private static let lock = NSLock()

    /// Every rollout under `root`, newest directories first. Codex files them as
    /// `sessions/YYYY/MM/DD/rollout-*.jsonl`; walking the three levels by name costs no `stat`.
    static func rolloutPaths(roots: [URL]) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for root in roots {
            for y in (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] {
                let yp = root.appendingPathComponent(y)
                for m in (try? fm.contentsOfDirectory(atPath: yp.path))?.sorted() ?? [] {
                    let mp = yp.appendingPathComponent(m)
                    for d in (try? fm.contentsOfDirectory(atPath: mp.path))?.sorted() ?? [] {
                        let dp = mp.appendingPathComponent(d)
                        for f in (try? fm.contentsOfDirectory(atPath: dp.path)) ?? []
                        where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                            out.append(dp.appendingPathComponent(f).path)
                        }
                    }
                }
            }
        }
        return out
    }

    /// The main-line sessions recorded against `cwd`, oldest first.
    ///
    /// Sub-threads are excluded the way Claude's builder drops sidechains: a multi-agent run spawns
    /// a rollout per worker (1775 of the 2068 here), each of which would root its own mini-tree in
    /// a panel that is supposed to be showing one conversation. `Meta.isWorker` is the marker.
    static func sessions(cwd: String, roots: [URL]) -> [Meta] {
        guard !cwd.isEmpty else { return [] }
        var out: [Meta] = []
        for p in rolloutPaths(roots: roots) {
            guard let m = meta(p), m.isMainLine, m.cwd == cwd else { continue }
            out.append(m)
        }
        // Oldest first, so the ORIGINAL of a shared prefix claims the address and a fork points at
        // it. Ties break on the filename, which carries the same timestamp and is unique.
        return out.sorted { ($0.started, $0.path) < ($1.started, $1.path) }
    }

    static func meta(_ path: String) -> Meta? {
        lock.lock()
        if let hit = metaCache[path] { lock.unlock(); return hit }
        lock.unlock()

        // Not cached when there is no complete first line yet. A hook names a worker's rollout the
        // moment the worker acts, which can be before Codex has finished writing the head, and that
        // is "not yet", not "not a rollout" — cached, it would stay unclassified for good.
        guard let line = headLine(path) else { return nil }
        let parsed = readMeta((try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                              path: path)
        lock.lock(); metaCache[path] = parsed; lock.unlock()
        return parsed
    }

    private static func readMeta(_ obj: [String: Any]?, path: String) -> Meta? {
        guard let obj,
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String else { return nil }
        let sid = (payload["id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? sessionId(fromRollout: path)
        // Where Codex says "this is a worker, and whose" has moved between versions: 0.153 says it
        // three ways, 0.141 has the top-level `parent_thread_id`, 0.136 has it only inside `source`.
        let subagent = (payload["source"] as? [String: Any])?["subagent"]
        let spawn = (subagent as? [String: Any])?["thread_spawn"] as? [String: Any]
        let parent = (payload["parent_thread_id"] as? String)
            ?? (spawn?["parent_thread_id"] as? String)
        let hb = payload["history_base"] as? [String: Any]
        let base = (hb?["thread_id"] as? String).map {
            HistoryBase(rollout: $0, endByte: hb?["end_byte_offset"] as? Int)
        }
        return Meta(path: path, sid: sid, rolloutId: rolloutId(fromRollout: path), base: base,
                    cwd: cwd,
                    started: (payload["timestamp"] as? String)
                        ?? (obj["timestamp"] as? String) ?? "",
                    forkedFrom: payload["forked_from_id"] as? String,
                    parentThread: parent,
                    isWorker: parent != nil || subagent != nil
                        || (payload["thread_source"] as? String) == "subagent")
    }

    /// Whether `path` is a worker's rollout rather than a conversation's. False for anything that
    /// is not a Codex rollout, and for one whose head is not readable yet.
    static func isWorkerRollout(_ path: String) -> Bool {
        AgentHome.isCodex(path) && meta(path)?.isWorker == true
    }

    /// The conversation's rollout for any rollout in it: `path` itself unless that is a worker, else
    /// the first thread above it that is not. nil when the chain runs into a rollout that is not on
    /// disk, which is better than answering with the worker.
    ///
    /// Where `mainLineSession` answers with an id and indexes every head to do it, this follows the
    /// chain by filename alone — it sits on paths that run every second (`hookSessionPath`, the
    /// status poll) and only ever needs the two or three heads on the way up.
    static func mainLineRollout(of path: String) -> String? {
        var cur = path
        var seen: Set<String> = []
        while let m = meta(cur), m.isWorker {
            guard let up = m.parentThread, seen.insert(cur).inserted,
                  let next = rolloutPath(ofThread: up) else { return nil }
            cur = next
        }
        return cur
    }

    private static var threadPaths: [String: (path: String, at: Date)] = [:]
    private static var threadMisses: [String: Date] = [:]

    /// The rollout thread `id` currently writes to. Usually the one file named for it; after an
    /// Esc Esc the thread has several (`-<id>.jsonl`, then `-<id>_<rollout>.jsonl` per revert) and
    /// Codex continues in the newest name, so that is the answer here too — the original still
    /// holds the turns the revert threw away and reads as the thread standing still.
    ///
    /// A segment can land in a later day directory than the file it continues, so the whole tree is
    /// walked (names only) rather than the sibling's day first. Hits are remembered for a minute,
    /// not for good: a revert while FleetView runs adds a newer file. A miss is remembered for a
    /// minute too, so a parent that was deleted does not cost a walk on every poll.
    static func rolloutPath(ofThread id: String) -> String? {
        lock.lock()
        if let hit = threadPaths[id], Date().timeIntervalSince(hit.at) < 60 { lock.unlock(); return hit.path }
        if let at = threadMisses[id], Date().timeIntervalSince(at) < 60 { lock.unlock(); return nil }
        lock.unlock()

        let own = "-\(id).jsonl", segment = "-\(id)_"
        let found = rolloutPaths(roots: CodexSession.sessionRoots)
            .filter { p in
                let name = (p as NSString).lastPathComponent
                return name.hasSuffix(own) || name.contains(segment)
            }
            .max { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }

        lock.lock()
        if let found { threadPaths[id] = (found, Date()) } else { threadMisses[id] = Date() }
        lock.unlock()
        return found
    }

    private static var rolloutFiles: [String: String] = [:]

    /// The file of rollout `id` — what a `history_base` names, and the first half of a node address.
    /// Looked for under `archived_sessions` as well, as Codex does: archiving a thread moves its
    /// files there and a fork of it still reads its history from them.
    static func rolloutPath(ofRollout id: String, roots: [URL]) -> String? {
        lock.lock()
        let hit = rolloutFiles[id]
        lock.unlock()
        if let hit, FileManager.default.fileExists(atPath: hit) { return hit }

        let own = "-\(id).jsonl", segment = "_\(id).jsonl"
        let matches: (String) -> Bool = { p in
            let name = (p as NSString).lastPathComponent
            return name.hasPrefix("rollout-") && (name.hasSuffix(own) || name.hasSuffix(segment))
        }
        var found = rolloutPaths(roots: roots).first(where: matches)
        if found == nil {
            let fm = FileManager.default
            for root in roots {
                let archived = root.deletingLastPathComponent().appendingPathComponent("archived_sessions")
                guard let walk = fm.enumerator(atPath: archived.path) else { continue }
                while let rel = walk.nextObject() as? String {
                    let p = archived.appendingPathComponent(rel).path
                    if matches(p) { found = p; break }
                }
                if found != nil { break }
            }
        }
        if let found { lock.lock(); rolloutFiles[id] = found; lock.unlock() }
        return found
    }

    /// The conversation a rollout belongs to: itself if someone typed in it, otherwise the thread
    /// that spawned it, walked to the top.
    ///
    /// This is not a corner case. A multi-agent run writes one rollout per worker — 637 of them
    /// against this project, versus 47 real conversations — and they share the project's cwd, so
    /// "the newest rollout in this directory" (how a Codex terminal is attributed at all, see
    /// `CodexSession.currentRollout`) used to land on a worker most of the time while a run was
    /// going, and every worker's hook still reports as the terminal that started it. That no longer
    /// rebinds a terminal, but `state.json` written before it still names workers, and a tree opened
    /// on such a terminal has to show the conversation, not nothing.
    static func mainLineSession(of sid: String, roots: [URL]) -> String? {
        var index: [String: Meta] = [:]
        for p in rolloutPaths(roots: roots) {
            if let m = meta(p) { index[m.sid] = m }
        }
        var cur = sid
        var seen: Set<String> = []
        while let m = index[cur], let up = m.parentThread, seen.insert(cur).inserted {
            cur = up
        }
        return index[cur]?.isMainLine == true ? cur : nil
    }

    /// The first line, read in chunks: `session_meta` carries the whole base-instruction block and
    /// runs past any fixed-size read, and a truncated line parses as nothing at all.
    ///
    /// nil while that line has no end yet, so the caller can tell "still being written" from "read
    /// and is not a head". A megabyte with no newline is the second kind and comes back to fail.
    private static func headLine(_ path: String) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        var buf = Data()
        while buf.count < 1_048_576 {
            guard let chunk = try? h.read(upToCount: 65_536), !chunk.isEmpty else { break }
            buf.append(chunk)
            if buf.firstIndex(of: 0x0A) != nil { break }
        }
        if let nl = buf.firstIndex(of: 0x0A) { return buf.subdata(in: buf.startIndex..<nl) }
        return buf.count >= 1_048_576 ? buf : nil
    }

    /// `rollout-2026-07-19T02-14-32-<uuid>.jsonl` → `<uuid>`, and a revert's segment
    /// `rollout-…-<thread>_<rollout>.jsonl` → `<thread>`. SearchIndex asks this too, so the two
    /// agree on what a session is called even when the head record is unreadable.
    ///
    /// Taking the last five dash groups, as this used to, turned a segment's name into
    /// `<last group of thread>_<rollout>` — not a uuid, so the card's resume command came out nil
    /// and reopening a Codex card after one Esc Esc did nothing at all.
    static func sessionId(fromRollout path: String) -> String { rolloutIds(path).thread }

    /// The id of the file itself: the part after `_` in a revert's segment, else the thread id.
    static func rolloutId(fromRollout path: String) -> String { rolloutIds(path).rollout }

    private static func rolloutIds(_ path: String) -> (thread: String, rollout: String) {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let halves = name.split(separator: "_", maxSplits: 1).map(String.init)
        let parts = (halves.first ?? name).split(separator: "-")
        guard parts.count >= 5 else { return (name, name) }
        let thread = parts.suffix(5).joined(separator: "-")
        return (thread, halves.count == 2 ? halves[1] : thread)
    }

    // MARK: - Turns

    struct Turn {
        let n: Int            // treeflow's prompt index within this rollout
        /// Where the prompt's line starts in its file — what a `history_base` cuts on.
        let byte: Int
        let text: String
        var answer: String
        let ts: String
        /// A `context_compacted` event landed between the previous prompt and this one.
        var compactedBefore: Bool = false
    }

    private struct TurnCache { let size: Int64; let mtime: TimeInterval; let turns: [Turn] }
    private static var turnCache: [String: TurnCache] = [:]

    /// A rollout's user prompts, with the agent messages that answered each folded in.
    ///
    /// Read from `response_item` messages, which is where treeflow reads them and — since Codex
    /// 0.147 — the only place they exist. Rollouts used to carry a parallel `event_msg` stream
    /// (`user_message` / `agent_message`) and this counted those instead; the two happened to agree
    /// because the extra `response_item` copies were exactly the `<environment_context>` blocks
    /// treeflow filters out. Verified on a July rollout: 80 event_msg prompts, 85 response_item
    /// ones, 80 after the filter. The new format dropped the event_msg stream, so that reading
    /// found nothing at all and every Codex session showed an empty tree.
    ///
    /// The numbering still has to match treeflow's exactly or a node's address opens the wrong
    /// turn: a prompt treeflow keeps but this considers unshowable still advances the counter,
    /// while one treeflow never counted (the environment blocks) must not. This mirrors
    /// `SearchIndex.parseCodex`, deliberately — the tree and the search index address the same
    /// nodes and must not drift apart.
    static func turns(of path: String) -> [Turn] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        lock.lock()
        if let c = turnCache[path], c.size == size, c.mtime == mtime {
            lock.unlock(); return c.turns
        }
        lock.unlock()

        var out: [Turn] = []
        var n = 0
        // Held until the next prompt: a compaction happens between turns, and the turn that has to
        // carry the mark is the first one that ran without what came before it.
        var compactionPending = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            // Byte-level fast reject before any JSON. A rollout is overwhelmingly `response_item`
            // tool traffic — the same records `SearchIndex` skips for the same reason — and decoding
            // it only to throw it away is the whole cost: on this corpus it was 15.8s to build one
            // project's tree, against 0.6s once the reject went in.
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self)
                var lo = 0
                while lo < p.count {
                    var hi = lo
                    while hi < p.count, p[hi] != 0x0A { hi += 1 }
                    defer { lo = hi + 1 }
                    // Probed on the raw bytes, ahead of the role reject that would otherwise drop
                    // the line: a `context_compacted` event carries no role at all, so it never
                    // survives to be parsed.
                    //
                    // The literal is only a filter, and the record is then decoded and checked,
                    // because those same bytes can appear inside a prompt or a tool output — and
                    // swallowing one of those would drop a turn, which shifts every node address
                    // after it and opens the wrong turn (see the numbering note above). A line that
                    // merely mentions the word falls through to the normal path.
                    guard hi > lo, p[lo] == UInt8(ascii: "{") else { continue }
                    if contains(p, lo, hi, Self.compactedKey),
                       let obj = (try? JSONSerialization.jsonObject(
                           with: Data(raw[lo..<hi]))) as? [String: Any],
                       (obj["type"] as? String) == "event_msg",
                       ((obj["payload"] as? [String: Any])?["type"] as? String) == "context_compacted" {
                        compactionPending = true
                        continue
                    }
                    guard contains(p, lo, hi, Self.roleKey),
                          let obj = (try? JSONSerialization.jsonObject(
                              with: Data(raw[lo..<hi]))) as? [String: Any],
                          (obj["type"] as? String) == "response_item",
                          let payload = obj["payload"] as? [String: Any],
                          (payload["type"] as? String) == "message",
                          let role = payload["role"] as? String else { continue }
                    let ts = (obj["timestamp"] as? String) ?? ""
                    switch role {
                    case "user":
                        let raw = contentText(payload)
                        // Not a turn at all, in treeflow's counting or ours — skipping it before the
                        // counter is what keeps the two numbering schemes on the same items.
                        guard isRealUserText(raw) else { continue }
                        defer { n += 1 }
                        guard let t = cleanPrompt(raw) else { continue }
                        out.append(Turn(n: n, byte: lo, text: clip(t, SessionTreeBuilder.promptCap),
                                        answer: "", ts: ts, compactedBefore: compactionPending))
                        compactionPending = false
                    case "assistant":
                        guard !out.isEmpty, let t = trimmed(contentText(payload)) else { continue }
                        // A reply belongs to the prompt it answers — the last one seen.
                        let i = out.count - 1
                        guard out[i].answer.count < SessionTreeBuilder.answerCap else { continue }
                        out[i].answer = clip(out[i].answer.isEmpty ? t : out[i].answer + "\n" + t,
                                             SessionTreeBuilder.answerCap)
                    default:
                        continue
                    }
                }
            }
        }
        lock.lock(); turnCache[path] = TurnCache(size: size, mtime: mtime, turns: out); lock.unlock()
        return out
    }

    /// Only message items carry a role, and only they carry a turn; the rest of a rollout is
    /// reasoning and tool traffic. A better reject than the record type itself — `response_item` is
    /// the majority of the file, `"role":` is 8-12% of it.
    private static let roleKey: [UInt8] = Array(#""role":""#.utf8)
    private static let compactedKey: [UInt8] = Array(#""context_compacted""#.utf8)

    /// The text of a `response_item` message, joined across its content blocks.
    /// Mirrors treeflow's `_codex_extract_text`.
    static func contentText(_ payload: [String: Any]) -> String {
        guard let blocks = payload["content"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks {
            let t = (b["text"] as? String) ?? (b["input_text"] as? String)
                ?? (b["output_text"] as? String) ?? ""
            if !t.isEmpty { parts.append(t) }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Codex injects `<environment_context>` and `<turn_aborted>` blocks as role=user messages.
    /// treeflow (`_codex_is_real_user_text`) never counts them, so neither can we — an extra item
    /// in the index shifts every node address after it by one.
    static func isRealUserText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return !t.hasPrefix("<environment_context>") && !t.hasPrefix("<turn_aborted>")
    }

    /// Substring search over a raw line. A fast *reject* only — everything it keeps is still
    /// validated by the real JSON parse.
    private static func contains(_ p: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int,
                                 _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n > 0, hi - lo >= n else { return false }
        let first = needle[0]
        var i = lo
        let last = hi - n
        while i <= last {
            if p[i] == first {
                var j = 1
                while j < n, p[i + j] == needle[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    /// Injected wrappers never typed by anyone — see `PromptText`.
    private static func cleanPrompt(_ raw: String) -> String? { PromptText.clean(raw) }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    // MARK: - Build

    /// The sessions that make up ONE conversation: the bound session, whatever it forked from
    /// (transitively), and whatever forked from any of those.
    ///
    /// Scoping matters more here than it looks. A project directory accumulates unrelated Codex
    /// sessions — 47 against this one, 1.1 GB of rollout, of which the panel displays the single
    /// subtree the terminal is sitting in. Parsing the other 46 buys nothing and costs seconds.
    /// It is also *more correct*: two conversations that merely open with the same prompt ("继续")
    /// would otherwise hash alike and be drawn as one tree that branched, which is a lie.
    ///
    /// So `forked_from_id` and `history_base` decide WHICH sessions belong together — they are
    /// Codex's own record of a fork — and the content chain decides WHERE they diverge, which a
    /// copied fork never wrote down. Every file of a thread comes along: after a revert the thread
    /// is several files, and the one bound is the newest while the turns before it are in the oldest.
    static func family(of sid: String?, among metas: [Meta]) -> [Meta] {
        guard let start = sid ?? metas.last?.sid else { return [] }
        // Threads, linked both ways by a fork and by a history_base. A thread's own files — the
        // segments a revert leaves — need no link: they share its id.
        let threads = Set(metas.map(\.sid))
        var thread: [String: String] = [:]       // rollout id → thread id
        for m in metas { thread[m.rolloutId] = m.sid }
        var links: [String: [String]] = [:]
        func link(_ a: String, _ b: String) {
            guard a != b, threads.contains(a), threads.contains(b) else { return }
            links[a, default: []].append(b)
            links[b, default: []].append(a)
        }
        for m in metas {
            if let f = m.forkedFrom { link(m.sid, f) }
            if let b = m.base, let owner = thread[b.rollout] { link(m.sid, owner) }
        }
        guard threads.contains(start) else { return [] }
        var seen: Set<String> = [start]
        var queue = [start]
        while let s = queue.popLast() {
            for t in links[s] ?? [] where seen.insert(t).inserted { queue.append(t) }
        }
        return metas.filter { seen.contains($0.sid) }   // keeps the oldest-first order
    }

    /// The session whose tree to show, given whatever the terminal was attributed to: itself when
    /// it is one of `all`, a stale index re-read when it is not, and the conversation above it when
    /// the terminal turned out to be sitting on a worker thread.
    private static func resolveBound(_ sid: String?, _ all: inout [Meta],
                                     cwd: String, roots: [URL]) -> String? {
        guard let sid, !all.contains(where: { $0.sid == sid }) else { return sid }
        // A session started since the index was last built is not in it yet, and it is precisely
        // the one being asked about. Re-read once rather than showing the wrong conversation.
        forgetIndex()
        all = sessions(cwd: cwd, roots: roots)
        if all.contains(where: { $0.sid == sid }) { return sid }
        return mainLineSession(of: sid, roots: roots)
    }

    /// Build the tree for the conversation `boundSessionId` belongs to (see `family`).
    static func build(cwd: String, boundSessionId: String?, roots: [URL]) -> TreeGraph {
        var tree = TreeGraph()
        var all = sessions(cwd: cwd, roots: roots)
        let bound = resolveBound(boundSessionId, &all, cwd: cwd, roots: roots)
        let metas = family(of: bound, among: all)
        guard !metas.isEmpty else { return tree }

        var canonical: [UInt64: String] = [:]      // chain hash → the address that owns that turn
        var lastTurn: [String: String] = [:]       // rollout id → the turn its history ends on
        var current: [String: Meta] = [:]          // thread id → the rollout it continues in
        for m in metas {
            // Oldest first, so the newest of a thread's files is the one left standing: Codex
            // resumes a reverted thread from its newest file.
            current[m.sid] = m
            var chain: UInt64 = 0xcbf29ce484222325
            var parent: String?
            for (owner, t) in history(of: m, roots: roots) {
                chain = fold(chain, t.text)
                let addr: String
                if let owned = canonical[chain] {
                    addr = owned                    // a copy of a turn we already have, or a base's
                } else if tree.nodes["\(owner.rolloutId):\(t.n)"] != nil {
                    // The same physical turn under another chain. Rebuilding it would drop its
                    // children; one family is built with one seed, so this is only a guard.
                    addr = "\(owner.rolloutId):\(t.n)"
                    canonical[chain] = addr
                } else {
                    addr = "\(owner.rolloutId):\(t.n)"
                    canonical[chain] = addr
                    tree.nodes[addr] = TreeTurn(uuid: addr, parent: parent, text: t.text, ts: t.ts)
                    tree.nodes[addr]?.compactedBefore = t.compactedBefore
                    if let p = parent { tree.nodes[p]?.children.append(addr) }
                }
                // The copy may carry a reply the original was still writing when it was forked.
                if tree.nodes[addr]?.answer.isEmpty == true, !t.answer.isEmpty {
                    tree.nodes[addr]?.answer = t.answer
                }
                parent = addr
            }
            if let parent { lastTurn[m.rolloutId] = parent }
        }
        // `codex resume <sid>` continues a thread at the end of its current file's history, so that
        // turn is reachable with no fork at all — the same meaning `nativeSessionId` has on the
        // Claude side. What a revert left behind is not: the thread no longer resumes into it.
        for (sid, m) in current.sorted(by: { $0.key < $1.key }) {
            guard let leaf = lastTurn[m.rolloutId] else { continue }
            tree.sessionLeaf[sid] = leaf
            tree.leafNodeBySession[sid] = leaf
            if tree.nodes[leaf]?.nativeSessionId == nil { tree.nodes[leaf]?.nativeSessionId = sid }
        }
        guard !tree.nodes.isEmpty else { return tree }

        SessionTreeBuilder.finish(&tree, boundSessionId: bound)
        return tree
    }

    /// Every turn in a rollout's history, oldest first, each with the rollout that holds it: the
    /// `history_base` chain, every base cut where the reference says, then the rollout's own turns.
    ///
    /// A base is looked up wherever it is filed — under another cwd (a fork into a new worktree
    /// records the new folder) or archived — because the history is the fork's whatever folder the
    /// parent ran in. One that cannot be found ends the chain: the rest still reads.
    static func history(of m: Meta, roots: [URL]) -> [(Meta, Turn)] {
        var chain: [(Meta, Int?)] = []            // newest first: the rollout, and where to cut it
        var cur: Meta? = m
        var cut: Int?
        var seen: Set<String> = []
        while let c = cur, seen.insert(c.rolloutId).inserted {
            chain.append((c, cut))
            guard let b = c.base,
                  let p = rolloutPath(ofRollout: b.rollout, roots: roots),
                  let up = meta(p) else { break }
            cut = b.endByte
            cur = up
        }
        var out: [(Meta, Turn)] = []
        for (c, cut) in chain.reversed() {
            for t in turns(of: c.path) where cut.map({ t.byte < $0 }) ?? true { out.append((c, t)) }
        }
        return out
    }

    /// FNV-1a, folded turn by turn. Not a security boundary — it only has to make "the same
    /// conversation so far" collide and anything else not, over a few thousand turns.
    private static func fold(_ seed: UInt64, _ s: String) -> UInt64 {
        var h = seed
        h = (h ^ 0x0a) &* 0x100000001b3         // separator, so prompts cannot run together
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return h
    }

    /// Files whose size/mtime the panel watches to decide a rebuild is needed. Scoped to the same
    /// family the tree was built from, so an unrelated session growing in the background does not
    /// rebuild a tree it cannot appear in.
    static func watchPaths(cwd: String, boundSessionId: String?, roots: [URL]) -> [String] {
        var all = sessions(cwd: cwd, roots: roots)
        let bound = resolveBound(boundSessionId, &all, cwd: cwd, roots: roots)
        return family(of: bound, among: all).map(\.path)
    }

    /// A new rollout appears as a new *file*, which no per-file signature can notice — so the
    /// refresh tick has to be told when the index itself is stale.
    static func forgetIndex() {
        lock.lock(); metaCache.removeAll(); indexedCount = -1; lock.unlock()
    }

    private static var indexedCount = -1

    /// What the panel polls to decide whether to rebuild: the family's files, plus how many
    /// rollouts exist at all.
    ///
    /// The count is the part that matters and the part a per-file stat cannot supply — forking a
    /// session writes a *new* rollout, so the thing that changed is that a file appeared. When the
    /// count moves, the cached head index is dropped so the new session can be seen; the walk is
    /// name-only (no `stat`), which is what keeps it affordable at this interval.
    static func signature(cwd: String, boundSessionId: String?, roots: [URL]) -> String {
        let paths = rolloutPaths(roots: roots)
        lock.lock()
        let changed = paths.count != indexedCount
        if changed { indexedCount = paths.count }
        lock.unlock()
        if changed { lock.lock(); metaCache.removeAll(); lock.unlock() }

        var sig = "n=\(paths.count);"
        for p in watchPaths(cwd: cwd, boundSessionId: boundSessionId, roots: roots).sorted() {
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            sig += "\(p):\((a?[.size] as? Int64) ?? 0):"
                + "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0);"
        }
        return sig
    }
}
