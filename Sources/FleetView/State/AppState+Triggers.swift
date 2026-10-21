import FleetViewAudit
import Foundation

/// What will make each terminal act on its own later — and taking it away again (see AgentTrigger).
extension AppState {

    /// Everything scheduled against `t`: what its agent last reported, and the LaunchAgents that
    /// name it.
    ///
    /// A report counts only while an agent is running there. Session crons and background work
    /// live in the CLI process and die with it, and nothing announces that: a card that went back
    /// to the shell, was closed, or did not come back after a relaunch would otherwise go on
    /// showing a schedule nobody holds any more.
    func triggers(for t: TerminalSession) -> [AgentTrigger] {
        let reported = t.status.isAgent ? (triggerReports[t.id]?.items ?? []) : []
        return reported + (launchdTriggers[t.id] ?? [])
    }

    func triggers(for id: UUID) -> [AgentTrigger] {
        terminals.first { $0.id == id }.map { triggers(for: $0) } ?? []
    }

    /// A cancellation was sent and the agent has not carried it out yet. It stops counting after a
    /// while: an agent that ignored the message should get its delete button back.
    func isCancelling(_ trigger: AgentTrigger, on id: UUID) -> Bool {
        guard let at = triggerCancels[Self.cancelKey(id, trigger)] else { return false }
        return Date().timeIntervalSince(at) < Self.cancelPatience
    }

    /// Long enough for a busy agent to finish its turn and get to the queued message.
    static let cancelPatience: TimeInterval = 15 * 60

    static func cancelKey(_ id: UUID, _ t: AgentTrigger) -> String { id.uuidString + "/" + t.key }

    // MARK: Reports from the hook

    /// A Stop said what the session has scheduled and left running.
    ///
    /// Each list replaces only its own kind: a payload carrying one and not the other says nothing
    /// about the other. The time is refreshed on every report — "as of the last turn" is what the
    /// panel tells you — but the file is only rewritten when the lists themselves change.
    func noteReportedTriggers(_ ev: EventWatcher.Event, terminal id: UUID) {
        guard ev.crons != nil || ev.background != nil else { return }
        let old = triggerReports[id]?.items ?? []
        let items = (ev.crons ?? old.filter { $0.kind == .cron })
            + (ev.background ?? old.filter { $0.kind == .background })
        triggerReports[id] = TriggerReport(at: Date(), items: items)
        // A cancellation is done once the agent no longer reports the thing.
        let prefix = id.uuidString + "/"
        for key in triggerCancels.keys where key.hasPrefix(prefix)
            && !items.contains(where: { Self.cancelKey(id, $0) == key }) && !key.hasPrefix(prefix + "launchd:") {
            triggerCancels[key] = nil
        }
        guard items != old else { return }
        saveTriggerReports()
        if let t = terminals.first(where: { $0.id == id }) {
            audit.emit("fleetview.agent.triggers_changed",
                       categories: ["session"],
                       message: "\(items.filter { $0.kind == .cron }.count) scheduled, "
                           + "\(items.filter { $0.kind == .background }.count) in the background",
                       target: auditTarget(terminal: t.id),
                       data: ["triggers.ids": .string(items.map(\.key).joined(separator: ","))])
        }
    }

    /// The process the report described is gone (a new one started, or the session was killed).
    func forgetReportedTriggers(_ id: UUID) {
        let prefix = id.uuidString + "/"
        for key in triggerCancels.keys where key.hasPrefix(prefix) && !key.hasPrefix(prefix + "launchd:") {
            triggerCancels[key] = nil
        }
        guard triggerReports.removeValue(forKey: id) != nil else { return }
        saveTriggerReports()
    }

    // MARK: Persistence and the launchd look

    /// Load the last reports and start looking at ~/Library/LaunchAgents. Reports are kept across
    /// a relaunch because the agents are: quitting FleetView leaves every session running, and a
    /// cron that fires once a day would otherwise vanish from its card until the next day.
    func startTriggerWatch() {
        if let data = try? Data(contentsOf: FV.triggersFile),
           let saved = try? Self.triggerDecoder.decode([String: TriggerReport].self, from: data) {
            let known = Set(terminals.map(\.id))
            triggerReports = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in
                UUID(uuidString: k).flatMap { known.contains($0) ? ($0, v) : nil }
            })
        }
        refreshLaunchdTriggers()
        // A minute is plenty: a LaunchAgent is written by hand or by an agent, and the panel looks
        // again whenever it opens.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLaunchdTriggers() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func saveTriggerReports() {
        let out = Dictionary(uniqueKeysWithValues: triggerReports.map { ($0.key.uuidString, $0.value) })
        guard let data = try? Self.triggerEncoder.encode(out) else { return }
        try? data.write(to: FV.triggersFile, options: .atomic)
    }

    func refreshLaunchdTriggers() {
        let ids = terminals.map { (id: $0.id, session: RemoteServer.sessionName(for: $0.id)) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = LaunchdTriggers.scan(ids)
            Task { @MainActor in
                guard let self, self.launchdTriggers != found else { return }
                self.launchdTriggers = found
            }
        }
    }

    private static let triggerEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let triggerDecoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    // MARK: The panel

    func openTriggers(_ id: UUID) {
        if treePanelTerminalId != nil { closeSessionTree() }   // one panel on the right at a time
        triggersPanelTerminalId = id
        refreshLaunchdTriggers()
    }

    func closeTriggers() { triggersPanelTerminalId = nil }

    func toggleTriggers(_ id: UUID) {
        triggersPanelTerminalId == id ? closeTriggers() : openTriggers(id)
    }

    // MARK: Cancelling

    /// Take a trigger away. Returns why it could not be, or nil once it is on its way.
    ///
    /// A LaunchAgent is FleetView's to remove. A session cron or a background task is not — only
    /// the agent can reach them (see `AgentTrigger.cancelPrompt`) — so for those this sends the
    /// agent the instruction and marks the row until its next report no longer lists it.
    @discardableResult
    func cancelTrigger(_ trig: AgentTrigger, on id: UUID, wakeup: Bool = false) -> String? {
        guard let t = terminals.first(where: { $0.id == id }) else { return L(.trigGone) }
        let key = Self.cancelKey(id, trig)
        return audited(AuditIntent("trigger.cancel",
                                   event: "fleetview.trigger.cancel_requested",
                                   categories: ["process"],
                                   target: auditTarget(terminal: id),
                                   data: ["trigger.kind": .string(trig.kind.rawValue),
                                          "trigger.id": .string(trig.id),
                                          "trigger.schedule": .string(trig.schedule ?? "")],
                                   message: "cancel \(trig.kind.rawValue) \(trig.id) on \(t.name)")) {
            switch trig.kind {
            case .launchd:
                guard let path = trig.path else { return L(.trigGone) }
                triggerCancels[key] = Date()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let failure = LaunchdTriggers.remove(label: trig.id, path: path)
                    Task { @MainActor in
                        guard let self else { return }
                        self.triggerCancels[key] = nil
                        if let failure { FV.log("trigger: could not remove \(trig.id): \(failure)") }
                        self.refreshLaunchdTriggers()
                    }
                }
                return nil
            case .cron, .background:
                // Typed into a permission prompt, the text would be taken as its answer.
                guard t.status != .needsYou else { return L(.trigAgentAsking) }
                guard t.status.isAgent else { return L(.trigNoAgent) }
                let text = trig.cancelPrompt(wakeup: wakeup)
                if remote.sessionExists(id) { webType(id, text: text, enter: true) }
                else { typeIntoTerminal(id, text, after: 0) }
                triggerCancels[key] = Date()
                return nil
            }
        }
    }

    // MARK: Cards that are gone

    /// The cards are gone, so the LaunchAgents that existed to reach them go too.
    ///
    /// A job like the fleet's progress pings is tied to its card by nothing but the uuid in its
    /// arguments, and nothing took it away with the card: `com.fleetview.progress-ping.e4dbb87e`
    /// went on firing every hour for 26 days at a card removed on 2026-09-26. Harmless only by
    /// luck — a restore brings a card back under its old uuid, and the pings would have resumed
    /// into it. A job that also names a card still on the board is left alone: it is still that
    /// card's. Closing is not removing — a closed card reopens under the same uuid, meant to.
    func retireLaunchdJobs(for removed: [UUID]) {
        guard !removed.isEmpty else { return }
        let gone = Set(removed)
        let names = Dictionary(uniqueKeysWithValues: terminals.filter { gone.contains($0.id) }.map { ($0.id, $0.name) })
        let targets = removed.map { (id: $0, session: RemoteServer.sessionName(for: $0)) }
        let kept = terminals.filter { !gone.contains($0.id) }
            .map { (id: $0.id, session: RemoteServer.sessionName(for: $0.id)) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = LaunchdTriggers.scan(targets)
            guard !found.isEmpty else { return }
            let stillWanted = Set(LaunchdTriggers.scan(kept).values.flatMap { $0.map(\.id) })
            var done = Set<String>()
            var results: [(terminal: UUID, job: AgentTrigger, failure: String?)] = []
            for (id, jobs) in found {
                for job in jobs where !stillWanted.contains(job.id) && !done.contains(job.id) {
                    done.insert(job.id)
                    let failure = job.path.flatMap { LaunchdTriggers.remove(label: job.id, path: $0) }
                    results.append((id, job, failure))
                }
            }
            Task { @MainActor in
                guard let self else { return }
                for r in results {
                    let name = names[r.terminal] ?? r.terminal.uuidString
                    FV.log("trigger: retired launchd job \(r.job.id) with its card \(name)"
                           + (r.failure.map { " — failed: \($0)" } ?? ""))
                    self.audit.emit("fleetview.trigger.launchd_retired",
                                    categories: ["process"],
                                    message: "removed with its card: \(r.job.id)",
                                    target: AuditTarget(kind: "terminal", id: r.terminal.uuidString, name: name),
                                    data: AuditValue.compact(["launchd.label": .string(r.job.id),
                                                              "launchd.plist": r.job.path.map { .string($0) },
                                                              "error": r.failure.map { .string($0) }]))
                }
                self.refreshLaunchdTriggers()
            }
        }
    }

    // MARK: The web's view of it

    static func errorJSON(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data(#"{"error":""}"#.utf8)
    }

    /// What `/triggers` answers, gathered on the main actor and rendered off it (the transcript
    /// read can take a moment on a long session).
    func triggersSpec(_ id: UUID) -> TriggersSpec? {
        guard let t = terminals.first(where: { $0.id == id }) else { return nil }
        let items = triggers(for: t)
        return TriggersSpec(name: t.name, agent: t.agentKind.label,
                            agentRunning: t.status.isAgent,
                            reportedAt: t.status.isAgent ? triggerReports[id]?.at : nil,
                            items: items,
                            cancelling: Set(items.filter { isCancelling($0, on: id) }.map(\.key)),
                            transcript: t.agentKind == .claude ? transcriptPath(for: id) : nil)
    }
}

/// One terminal's triggers, enough to answer `/triggers` without the main actor.
struct TriggersSpec: Sendable {
    let name: String
    let agent: String
    let agentRunning: Bool
    let reportedAt: Date?
    let items: [AgentTrigger]
    let cancelling: Set<String>
    let transcript: String?

    /// Times go out as seconds from now, as the rest of the page's do: the phone's clock is its own.
    func respond(now: Date = Date()) -> Data {
        let history = transcript.map { TriggerHistory.read(path: $0) }
        func ago(_ d: Date?) -> Int { d.map { max(0, Int(now.timeIntervalSince($0))) } ?? -1 }
        func until(_ d: Date?) -> Int { d.map { max(0, Int($0.timeIntervalSince(now))) } ?? -1 }
        let rows: [[String: Any]] = items.map { t in
            let d = history?.detail(for: t) ?? TriggerHistory.Detail()
            var r: [String: Any] = [
                "key": t.key, "kind": t.kind.rawValue, "id": t.id,
                "text": d.prompt ?? TriggerHistory.unclipped(t.text),
                "cancelling": cancelling.contains(t.key),
                "wakeup": d.wakeup,
                "fires": d.fires,
                "lastFire": ago(d.lastFire),
                "created": ago(d.created),
                "expires": until(d.expires),
                "next": until(TriggerHistory.nextFire(t, d, after: now)),
                "lag": Int(d.lag),
            ]
            if let s = t.schedule { r["schedule"] = s }
            if let s = t.schedule, let shape = CronExpr.shape(s, recurring: t.recurring) {
                r["shape"] = Self.json(shape)
            }
            if let v = t.recurring { r["recurring"] = v }
            if let v = d.reason { r["reason"] = v }
            if let v = t.taskType { r["type"] = v }
            if let v = t.status { r["status"] = v }
            if let v = t.command { r["command"] = v }
            if let v = t.interval { r["interval"] = v }
            if let v = t.path { r["path"] = v }
            return r
        }
        let body: [String: Any] = ["name": name, "agent": agent, "agentRunning": agentRunning,
                                   "reported": ago(reportedAt), "items": rows]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    private static func json(_ s: CronExpr.Shape) -> [String: Any] {
        switch s {
        case .everyMinutes(let n):         return ["k": "every", "n": n]
        case .hourly(let m):               return ["k": "hourly", "m": m]
        case .daily(let h, let m):         return ["k": "daily", "h": h, "m": m]
        case .weekdays(let h, let m):      return ["k": "weekdays", "h": h, "m": m]
        case .once(let mo, let d, let h, let m): return ["k": "once", "mo": mo, "d": d, "h": h, "m": m]
        }
    }
}
