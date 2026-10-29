import Darwin
import FleetViewAudit
import Foundation

/// Makes a card that says "closed" mean the agent behind it has stopped.
///
/// Closing a terminal kills its tmux session, and the hangup that delivers is what ends the agent.
/// It usually does. On 2026-10-21 one did not: a Claude Code under `sp-claude` took the SIGHUP,
/// closed its end of the terminal and then spun in a loop on its main thread — 46 hours at a full
/// core, its sub-pool lease still being refreshed, two background shells still polling — while
/// its card read "closed" and a second `--resume` of the same conversation ran beside it. `sp-claude`
/// only forwards signals and waits, so nothing above it ever noticed. See
/// docs/问题与修复/2026-10-22-agent-outlives-closed-card.md.
///
/// So the processes are written down before the kill and looked at again after it. Whatever
/// outlived the hangup gets SIGTERM, then SIGKILL — the innermost first, so a wrapper sees its
/// child go and still gets to clean up (`sp-claude` releases its lease and deletes its temp home
/// only once `claude` has exited).
///
/// What counts as the terminal's:
/// - everything in the pane's session: the shell, the agent, the wrapper around it, its MCP servers;
/// - the background shells the agent started. Claude puts every `run_in_background` command in a
///   session of its own (setsid), so the pane's session does not reach them, and when the agent
///   dies hard they are what is left: one such shell was still running `tail -F` five days after
///   its Claude was gone.
///
/// Except anything that says it is a daemon. Codex's app-server and Claude's `daemon run` /
/// `--bg-pty-host` are started by an agent on purpose to outlive it, and one is shared by every
/// agent on the same home: killing it with one card would cut off the others.
final class ProcessReaper: @unchecked Sendable {

    /// A process, by start time as well as pid: by the time a check comes round the pid may belong
    /// to something else.
    struct Proc: Hashable, Sendable {
        let pid: pid_t
        let start: UInt64       // µs since the epoch
    }

    struct Plan: Sendable {
        let label: String       // the tmux session, or "all sessions"
        let terminal: UUID?
        let known: Set<Proc>
    }

    /// How long an agent gets to exit on the hangup alone. A healthy Claude or Codex is gone in well
    /// under a second, background shells included.
    static let hangupGrace: TimeInterval = 3
    /// After SIGTERM.
    static let termGrace: TimeInterval = 3
    /// After the innermost processes are killed, for the wrappers around them to finish up.
    static let wrapperGrace: TimeInterval = 2
    private static let pollInterval: TimeInterval = 0.1

    private let pending = DispatchGroup()

    // MARK: - Before the kill

    /// Everything that belongs to these panes now. Call it before the session is killed: a
    /// background shell is found through its parent, and once the agent has gone it has none.
    static func plan(panes: [pid_t], label: String, terminal: UUID?) -> Plan? {
        let table = ProcTable.read()
        let paneSessions = Set(panes.map { getsid($0) }.filter { $0 > 0 })
        // A pane is a session of its own (tmux setsid's every one). If a pid from tmux ever led
        // back to FleetView's session, the sweep below would take the app with it.
        guard !paneSessions.isEmpty, !paneSessions.contains(getsid(0)) else { return nil }
        var mine = table.filter { paneSessions.contains($0.sid) }
        let memberPids = Set(mine.map(\.pid))
        let shellSessions = Set(table.filter {
            $0.pid == $0.sid && !paneSessions.contains($0.sid) && memberPids.contains($0.ppid)
        }.map(\.sid))
        mine += table.filter { shellSessions.contains($0.sid) }
        let daemons = Set(mine.filter { isDaemon($0.pid) }.map(\.pid))
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        mine.removeAll { descends($0, fromAnyOf: daemons, in: byPid) }
        guard !mine.isEmpty else { return nil }
        return Plan(label: label, terminal: terminal, known: Set(mine.map(\.proc)))
    }

    // MARK: - After the kill

    /// Watch a plan through to the end, off the caller's thread.
    func reap(_ plan: Plan, auditor: Auditor) {
        pending.enter()
        DispatchQueue.global(qos: .utility).async { [pending] in
            Self.run(plan, auditor: auditor)
            pending.leave()
        }
    }

    /// For quitting: the timers above die with the process, and an agent that ignored the hangup
    /// would then outlive FleetView too. Returns at once when nothing is pending.
    func waitForPending(timeout: TimeInterval) {
        if pending.wait(timeout: .now() + timeout) == .timedOut {
            FV.log("reaper: still waiting on processes after \(Int(timeout))s at quit — leaving them")
        }
    }

    private static func run(_ plan: Plan, auditor: Auditor) {
        var known = plan.known
        guard let outlived = survivors(&known, within: hangupGrace) else { return }
        let names = outlived.map { "\($0.pid) \($0.comm)" }
        FV.log("reaper: \(outlived.count) process(es) outlived the hangup of \(plan.label): "
               + names.joined(separator: ", "))
        send(SIGTERM, to: outlived)

        var signals = ["SIGTERM"]
        if let left = survivors(&known, within: termGrace) {
            // A wrapper is a parent in its child's own session: `sp-claude` over `claude`. Parents
            // across sessions don't count — the wedged agent is the parent of its background
            // shells, and counting that kept it alive until the wrapper's kill, so the two died
            // together and the wrapper never cleaned up.
            let sidOf = Dictionary(left.map { ($0.pid, $0.sid) }, uniquingKeysWith: { a, _ in a })
            let wrappers = Set(left.filter { sidOf[$0.ppid] == $0.sid }.map(\.ppid))
            let inner = left.filter { !wrappers.contains($0.pid) }
            FV.log("reaper: \(plan.label): SIGKILL " + inner.map { "\($0.pid) \($0.comm)" }.joined(separator: ", "))
            send(SIGKILL, to: inner)
            signals.append("SIGKILL")
            if let rest = survivors(&known, within: wrapperGrace) {
                FV.log("reaper: \(plan.label): SIGKILL " + rest.map { "\($0.pid) \($0.comm)" }.joined(separator: ", "))
                send(SIGKILL, to: rest)
            }
        }
        let remaining = survivors(&known, within: 0.5)
        if let remaining {
            FV.log("reaper: \(plan.label): \(remaining.count) still alive after SIGKILL: "
                   + remaining.map { "\($0.pid) \($0.comm)" }.joined(separator: ", "))
        } else {
            FV.log("reaper: \(plan.label): stopped (\(signals.joined(separator: " → ")))")
        }
        AuditContext.with(AuditActor(kind: .system)) {
            auditor.emit("fleetview.terminal.reaped",
                         categories: ["process"],
                         outcome: remaining == nil ? .success : .failure,
                         message: "\(outlived.count) process(es) outlived the hangup of \(plan.label)",
                         target: plan.terminal.map { AuditTarget(kind: "terminal", id: $0.uuidString) },
                         data: ["processes": .array(names.map { .string($0) }),
                                "signals": .array(signals.map { .string($0) }),
                                "still_alive": .int(remaining?.count ?? 0)])
        }
    }

    /// What is still running of `known` once `wait` is up, or nil as soon as nothing is. Children a
    /// survivor started since the last look are adopted, so a kill does not leave them behind.
    private static func survivors(_ known: inout Set<Proc>, within wait: TimeInterval) -> [ProcTable.Entry]? {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            let table = ProcTable.read()
            var alive = table.filter { known.contains($0.proc) }
            var pids = Set(alive.map(\.pid))
            var grew = true
            while grew {
                let kids = table.filter { !pids.contains($0.pid) && pids.contains($0.ppid) && !isDaemon($0.pid) }
                grew = !kids.isEmpty
                alive += kids
                pids.formUnion(kids.map(\.pid))
                known.formUnion(kids.map(\.proc))
            }
            if alive.isEmpty { return nil }
            if Date() >= deadline { return alive }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// Signals by (pid, start) as read a moment ago — the narrowest window this side of a pidfd.
    private static func send(_ signal: Int32, to procs: [ProcTable.Entry]) {
        for p in procs { kill(p.pid, signal) }
    }

    private static func descends(_ e: ProcTable.Entry, fromAnyOf roots: Set<pid_t>,
                                 in byPid: [pid_t: ProcTable.Entry]) -> Bool {
        var cur: ProcTable.Entry? = e
        var hops = 0
        while let c = cur, c.pid > 1, hops < 64 {
            if roots.contains(c.pid) { return true }
            cur = byPid[c.ppid]
            hops += 1
        }
        return false
    }

    /// Codex: `app-server --managed-daemon`, `app-server daemon pid-update-loop`. Claude: `daemon
    /// run`, `--daemon-worker`, `--bg-pty-host`, `--bg-spare`. Only the bare word and flags are
    /// looked at — a background shell's whole script is one argument, and mentioning "daemon" in it
    /// does not make it one.
    private static func isDaemon(_ pid: pid_t) -> Bool {
        ProcTable.arguments(pid).dropFirst().contains { a in
            a == "daemon" || (a.hasPrefix("-") && (a.contains("daemon") || a.hasPrefix("--bg")))
        }
    }
}

/// The process table, read from the kernel rather than from `ps` — this runs on the main actor
/// before every kill, and once a tenth of a second while a plan is open.
enum ProcTable {
    struct Entry {
        let pid: pid_t
        let ppid: pid_t
        let sid: pid_t
        let start: UInt64
        let comm: String
        var proc: ProcessReaper.Proc { .init(pid: pid, start: start) }
    }

    /// This user's processes. Nobody else's can be signalled anyway, and leaving them out saves a
    /// `getsid` each.
    static func read() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var procs: [kinfo_proc] = []
        var size = 0
        for _ in 0..<3 {
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            size += size / 8                    // room for what starts between the two calls
            procs = Array(repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            if sysctl(&mib, 4, &procs, &size, nil, 0) == 0 { break }
            guard errno == ENOMEM else { return [] }
            procs = []
        }
        let uid = getuid()
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { kp in
            let pid = kp.kp_proc.p_pid
            guard pid > 0, kp.kp_eproc.e_ucred.cr_uid == uid else { return nil }
            let t = kp.kp_proc.p_un.__p_starttime
            var comm = kp.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Entry(pid: pid, ppid: kp.kp_eproc.e_ppid, sid: getsid(pid),
                         start: UInt64(t.tv_sec) * 1_000_000 + UInt64(t.tv_usec), comm: name)
        }
    }

    /// argv, from KERN_PROCARGS2: argc, the executable path, padding, then argc NUL-terminated
    /// strings. Empty when the process is gone or not ours.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }  // the executable path
        while i < size, buf[i] == 0 { i += 1 }  // its padding
        var args: [String] = []
        while args.count < argc, i < size {
            let s = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
