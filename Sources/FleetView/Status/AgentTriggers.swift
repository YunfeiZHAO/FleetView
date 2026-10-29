import Foundation

/// Something that will make an agent act later without anyone typing to it.
///
/// Three sources, because there are three ways it happens on this board:
///  • **cron** — a Claude session's scheduled prompts: `CronCreate`, and the one-shot wakeups behind
///    `/loop` (`ScheduleWakeup`). They live only in the CLI's memory — nothing on disk lists them —
///    so the only authority is the CLI itself, which reports them in every Stop hook as
///    `session_crons` (Claude Code 2.1.280; older builds leave the key out).
///  • **background** — work the session left running that wakes it when it ends or reports:
///    background shells, monitors, subagents. Same hook, `background_tasks`.
///  • **launchd** — a LaunchAgent whose command line names the terminal, which is how the fleet's
///    own scheduled pings reach a card (see `LaunchdTriggers`).
///
/// Codex CLI has no session scheduler at all (checked against codex-cli 0.163), so a Codex card
/// can only ever show the third kind.
struct AgentTrigger: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case cron, background, launchd }

    var kind: Kind
    /// The agent's own id for it (what `CronDelete` / `TaskStop` take), or the launchd label.
    var id: String
    /// Five-field cron, local time. For launchd a `StartCalendarInterval` written the same way —
    /// the two mean the same thing, field for field — and several of them joined by `;`.
    var schedule: String?
    var recurring: Bool?
    /// What it will say (a cron's prompt), what is running (a task's description), or for launchd
    /// the command it runs. The hook clips prompts at 1,000 characters; the transcript has the rest.
    var text: String
    /// Background work: "shell", "monitor", "subagent", … and its state.
    var taskType: String?
    var status: String?
    /// A background shell's command line; a LaunchAgent's arguments.
    var command: String?
    /// launchd `StartInterval`, seconds.
    var interval: Int?
    /// The LaunchAgent's plist.
    var path: String?

    /// Unique across kinds, for lists and for remembering a cancellation in flight.
    var key: String { kind.rawValue + ":" + id }

    /// Will it fire at a time (as opposed to when some work ends)?
    var isTimed: Bool { kind != .background }
}

/// The last list a terminal's agent reported, and when.
struct TriggerReport: Codable, Hashable, Sendable {
    var at: Date
    var items: [AgentTrigger]
}

extension AgentTrigger {
    /// `session_crons` → triggers. nil when the payload has no such key (an older Claude, a Codex
    /// Stop), which must leave the last report alone rather than read as "none scheduled".
    static func crons(fromStop p: [String: Any]) -> [AgentTrigger]? {
        guard let rows = p["session_crons"] as? [[String: Any]] else { return nil }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            return AgentTrigger(kind: .cron, id: id,
                                schedule: r["schedule"] as? String,
                                recurring: r["recurring"] as? Bool,
                                text: (r["prompt"] as? String) ?? "")
        }
    }

    /// `background_tasks` → triggers, with the same nil-means-unknown rule.
    static func background(fromStop p: [String: Any]) -> [AgentTrigger]? {
        guard let rows = p["background_tasks"] as? [[String: Any]] else { return nil }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            return AgentTrigger(kind: .background, id: id, schedule: nil, recurring: nil,
                                text: (r["description"] as? String) ?? "",
                                taskType: r["type"] as? String,
                                status: r["status"] as? String,
                                command: r["command"] as? String)
        }
    }

    /// What FleetView types into the terminal to cancel it.
    ///
    /// A session cron exists only inside the CLI process, and nothing outside it can reach that
    /// store — there is no file to edit, no slash command and no signal. The one door is the agent
    /// itself, so cancelling is a short, exact instruction it carries out with its own tool. The id
    /// is spelled out because it is the only thing that makes "that one" unambiguous to it.
    func cancelPrompt(wakeup: Bool) -> String {
        switch kind {
        case .cron:
            let what = schedule.map { " (\($0))" } ?? ""
            let tail = wakeup
                ? "It is a /loop wakeup, so the loop ends here: do not call ScheduleWakeup again."
                : "Do not schedule it again or create a replacement."
            return "[FleetView] The user cancelled scheduled task \(id)\(what) from FleetView. "
                + "Call CronDelete with id \"\(id)\" now. \(tail) Do nothing else; reply in one line."
        case .background:
            let what = text.isEmpty ? "" : " (\(String(text.prefix(80))))"
            return "[FleetView] The user stopped background task \(id)\(what) from FleetView. "
                + "Stop it now with TaskStop (task id \"\(id)\") and do not restart it. "
                + "Do nothing else; reply in one line."
        case .launchd:
            return ""
        }
    }
}

// MARK: - Cron

/// A five-field cron expression, for "when does it fire next" — the one thing the CLI's report
/// does not say. Numbers, `*`, ranges, steps and lists; names (`MON`, `JAN`) are not parsed, and an
/// expression using them simply has no next time rather than a wrong one.
struct CronExpr {
    let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let anyDay: Bool, anyWeekday: Bool

    init?(_ s: String) {
        let f = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count == 5,
              let mi = Self.field(f[0], 0, 59), let h = Self.field(f[1], 0, 23),
              let d = Self.field(f[2], 1, 31), let mo = Self.field(f[3], 1, 12),
              let w = Self.field(f[4], 0, 7) else { return nil }
        minutes = mi; hours = h; days = d; months = mo
        weekdays = Set(w.map { $0 == 7 ? 0 : $0 })
        anyDay = f[2] == "*"; anyWeekday = f[4] == "*"
    }

    private static func field(_ s: String, _ lo: Int, _ hi: Int) -> Set<Int>? {
        var out = Set<Int>()
        for part in s.split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            let range = pieces[0]
            var a = lo, b = hi
            if range != "*" {
                let ends = range.split(separator: "-", maxSplits: 1)
                guard let x = Int(ends[0]) else { return nil }
                a = x
                b = ends.count == 2 ? (Int(ends[1]) ?? -1) : (pieces.count == 2 ? hi : x)
            }
            guard a >= lo, b <= hi, a <= b else { return nil }
            out.formUnion(stride(from: a, through: b, by: step))
        }
        return out.isEmpty ? nil : out
    }

    /// Standard cron: with both day fields restricted, either one matching is enough.
    private func dayMatches(_ c: DateComponents) -> Bool {
        let d = days.contains(c.day!), w = weekdays.contains(c.weekday! - 1)
        if anyDay && anyWeekday { return true }
        if anyDay { return w }
        if anyWeekday { return d }
        return d || w
    }

    /// The first matching minute after `date`, within about a year.
    func next(after date: Date, calendar cal: Calendar = .current) -> Date? {
        var t = cal.date(bySetting: .second, value: 0, of: date.addingTimeInterval(60)) ?? date
        if t <= date { t = t.addingTimeInterval(60) }
        let limit = date.addingTimeInterval(400 * 86_400)
        while t < limit {
            let c = cal.dateComponents([.month, .day, .weekday, .hour, .minute], from: t)
            if !months.contains(c.month!) {
                let first = cal.date(from: cal.dateComponents([.year, .month], from: t))!
                t = cal.date(byAdding: .month, value: 1, to: first)!
            } else if !dayMatches(c) {
                t = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t))!
            } else if !hours.contains(c.hour!) {
                t = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: t))!
                    .addingTimeInterval(3600)
            } else if !minutes.contains(c.minute!) {
                t = t.addingTimeInterval(60)
            } else {
                return t
            }
        }
        return nil
    }

    /// How long after the slot it belongs to a fire at `fire` came — the nearest matching minute
    /// at or before it, looked for within the hour (Claude's jitter is at most 15 minutes; anything
    /// later was a busy agent, not the schedule, and is no guide to the next one).
    func lag(of fire: Date, calendar cal: Calendar = .current) -> TimeInterval {
        guard var t = cal.date(bySetting: .second, value: 0, of: fire) else { return 0 }
        if t > fire { t = t.addingTimeInterval(-60) }
        for _ in 0..<60 {
            let c = cal.dateComponents([.month, .day, .weekday, .hour, .minute], from: t)
            if months.contains(c.month!), dayMatches(c), hours.contains(c.hour!), minutes.contains(c.minute!) {
                let lag = fire.timeIntervalSince(t)
                return lag >= 60 ? lag : 0
            }
            t = t.addingTimeInterval(-60)
        }
        return 0
    }

    /// The soonest of several `;`-joined schedules (a LaunchAgent can list more than one).
    static func next(_ schedule: String, after date: Date = Date()) -> Date? {
        schedule.split(separator: ";")
            .compactMap { CronExpr(String($0).trimmingCharacters(in: .whitespaces))?.next(after: date) }
            .min()
    }

    /// The shapes worth saying in words. Anything else is shown as the expression itself.
    enum Shape: Equatable {
        case everyMinutes(Int)
        case hourly([Int])                 // at these minutes past every hour
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)
        case once(month: Int, day: Int, hour: Int, minute: Int)
    }

    static func shape(_ schedule: String, recurring: Bool?) -> Shape? {
        let f = schedule.split(separator: " ").map(String.init)
        guard f.count == 5, let e = CronExpr(schedule) else { return nil }
        let one = { (s: Set<Int>) -> Int? in s.count == 1 ? s.first : nil }
        if recurring == false, let mi = one(e.minutes), let h = one(e.hours),
           let d = one(e.days), let mo = one(e.months) {
            return .once(month: mo, day: d, hour: h, minute: mi)
        }
        guard f[2] == "*", f[3] == "*" else { return nil }
        if f[1] == "*", f[4] == "*" {
            let m = e.minutes.sorted()
            if m.count > 1, 60 % m.count == 0 {
                let step = 60 / m.count
                if zip(m, m.dropFirst()).allSatisfy({ $1 - $0 == step }) { return .everyMinutes(step) }
            }
            return .hourly(m)
        }
        guard let mi = one(e.minutes), let h = one(e.hours) else { return nil }
        if f[4] == "*" { return .daily(hour: h, minute: mi) }
        if e.weekdays == [1, 2, 3, 4, 5] { return .weekdays(hour: h, minute: mi) }
        return nil
    }
}

// MARK: - What the transcript remembers

/// What a Claude transcript says about its crons — the parts the hook does not carry: when each
/// was made, its whole prompt, how often it has fired and when last, and which one-shots are
/// `/loop` wakeups.
///
/// Read only for the panel, and incrementally, like `TokenUsage`: a long session's transcript is
/// tens of megabytes (75 MB for the one this was written against), and every line that can matter
/// names a cron tool or a schedule, so the rest is skipped without a JSON parse.
struct TriggerHistory: Sendable {
    struct Made: Sendable {
        var created: Date?
        var prompt: String
        var recurring: Bool?
        var durable: Bool?
    }
    struct Wakeup: Sendable {
        var created: Date?
        var prompt: String
        var reason: String?
        var fireAt: Date?
    }
    var made: [String: Made] = [:]
    var wakeups: [Wakeup] = []
    var fires: [String: (count: Int, last: Date?)] = [:]

    /// One trigger, as the panel describes it.
    struct Detail: Sendable {
        var created: Date?
        var prompt: String?
        var fires = 0
        var lastFire: Date?
        var wakeup = false
        var reason: String?
        /// Recurring crons expire seven days after they were made (Claude Code's rule).
        var expires: Date?
        /// How late after its slot it actually fires. Claude Code adds a fixed jitter per job — this
        /// file's 20-minute fleet monitor, set for :09 :29 :49, fires at :18 :38 :58 every time — so
        /// the last fire's lateness is the honest way to say when the next one will come.
        var lag: TimeInterval = 0
    }

    /// When it will really fire next: its next slot, as late as the last one was.
    static func nextFire(_ t: AgentTrigger, _ d: Detail, after now: Date = Date()) -> Date? {
        guard let s = t.schedule else { return nil }
        return CronExpr.next(s, after: now.addingTimeInterval(-d.lag)).map { $0.addingTimeInterval(d.lag) }
    }

    static let recurringLifetime: TimeInterval = 7 * 86_400

    func detail(for t: AgentTrigger) -> Detail {
        var d = Detail()
        guard t.kind == .cron else { return d }
        if let f = fires[t.id] { d.fires = f.count; d.lastFire = f.last }
        if let last = d.lastFire, let s = t.schedule, let e = CronExpr(s) { d.lag = e.lag(of: last) }
        if let m = made[t.id] {
            d.created = m.created
            d.prompt = m.prompt
            if m.recurring != false, let c = m.created { d.expires = c.addingTimeInterval(Self.recurringLifetime) }
            return d
        }
        // Not from CronCreate: a wakeup, which reports no id when it is scheduled. Matched on its
        // prompt, whose head is the same in the hook (clipped) and in the call (whole).
        let head = String(Self.unclipped(t.text).prefix(160))
        if !head.isEmpty, let w = wakeups.last(where: { $0.prompt.hasPrefix(head) }) {
            d.wakeup = true
            d.created = w.created
            d.prompt = w.prompt
            d.reason = w.reason
        }
        return d
    }

    /// The hook's prompt without its `… [+N chars]` clip marker.
    static func unclipped(_ s: String) -> String {
        guard let r = s.range(of: "\u{2026} [+", options: .backwards) else { return s }
        return String(s[..<r.lowerBound])
    }

    // MARK: Reading

    static func read(path: String) -> TriggerHistory {
        let l = ledger(for: path)
        l.lock.lock(); defer { l.lock.unlock() }
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return TriggerHistory() }
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if inode != l.inode || size < l.offset { l.reset(); l.inode = inode }
        if size > l.offset { l.offset += l.consume(path: path, from: l.offset, to: size) }
        return l.history
    }

    private final class Ledger {
        let lock = NSLock()
        var offset: UInt64 = 0
        var inode: UInt64 = 0
        var history = TriggerHistory()
        var pendingMade: [String: Made] = [:]      // tool_use id → the CronCreate call
        var pendingWake: [String: Wakeup] = [:]    // tool_use id → the ScheduleWakeup call
        var used = Date()

        func reset() { offset = 0; history = TriggerHistory(); pendingMade = [:]; pendingWake = [:] }

        func consume(path: String, from: UInt64, to: UInt64) -> UInt64 {
            guard let h = FileHandle(forReadingAtPath: path) else { return 0 }
            defer { try? h.close() }
            try? h.seek(toOffset: from)
            var consumed: UInt64 = 0, pos = from
            var carry = Data()
            var ended = false
            while pos < to, !ended {
                autoreleasepool {
                    guard let chunk = try? h.read(upToCount: Int(min(to - pos, 4 << 20))), !chunk.isEmpty
                    else { ended = true; return }
                    pos += UInt64(chunk.count)
                    var buf = carry
                    buf.append(chunk)
                    guard let lastNL = buf.lastIndex(of: 0x0A) else { carry = buf; return }
                    var start = buf.startIndex
                    while start < lastNL {
                        let end = buf[start...lastNL].firstIndex(of: 0x0A)!
                        let line = buf[start..<end]
                        if line.range(of: Self.cronKey) != nil || line.range(of: Self.scheduleKey) != nil,
                           Self.keys.contains(where: { line.range(of: $0) != nil }) {
                            take(Data(line))
                        }
                        start = buf.index(after: end)
                    }
                    consumed += UInt64(buf.distance(from: buf.startIndex, to: lastNL) + 1)
                    carry = Data(buf[buf.index(after: lastNL)...])
                }
            }
            return consumed
        }

        // Every line that matters says one of `keys`: the tool names, and the keys of their results
        // and of a fire. The two short ones are a cheaper first look that most lines fail.
        static let cronKey = Data("Cron".utf8)
        static let scheduleKey = Data("chedule".utf8)
        static let keys = [#""CronCreate""#, #""ScheduleWakeup""#, #""humanSchedule""#,
                           #""scheduledFor""#, #""scheduledTaskId""#].map { Data($0.utf8) }

        private func take(_ ld: Data) {
            guard let o = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { return }
            let ts = TriggerHistory.date(o["timestamp"])
            // A scheduled fire: the prompt arrives as a user turn that names the job it came from.
            if let sid = o["scheduledTaskId"] as? String {
                var f = history.fires[sid] ?? (0, nil)
                f.count += 1
                f.last = ts ?? f.last
                history.fires[sid] = f
            }
            guard let m = o["message"] as? [String: Any], let blocks = m["content"] as? [[String: Any]] else { return }
            for b in blocks {
                switch b["type"] as? String {
                case "tool_use":
                    guard let use = b["id"] as? String, let input = b["input"] as? [String: Any] else { continue }
                    switch b["name"] as? String {
                    case "CronCreate":
                        pendingMade[use] = Made(created: ts, prompt: (input["prompt"] as? String) ?? "",
                                                recurring: input["recurring"] as? Bool,
                                                durable: input["durable"] as? Bool)
                    case "ScheduleWakeup":
                        guard (input["stop"] as? Bool) != true else { continue }
                        pendingWake[use] = Wakeup(created: ts, prompt: (input["prompt"] as? String) ?? "",
                                                  reason: input["reason"] as? String)
                    default:
                        break
                    }
                case "tool_result":
                    guard let use = b["tool_use_id"] as? String else { continue }
                    let result = o["toolUseResult"] as? [String: Any]
                    if var made = pendingMade.removeValue(forKey: use), let id = result?["id"] as? String {
                        if let r = result?["recurring"] as? Bool { made.recurring = r }
                        if let d = result?["durable"] as? Bool { made.durable = d }
                        history.made[id] = made
                    } else if var w = pendingWake.removeValue(forKey: use) {
                        if let ms = result?["scheduledFor"] as? Double { w.fireAt = Date(timeIntervalSince1970: ms / 1000) }
                        history.wakeups.append(w)
                    }
                default:
                    break
                }
            }
        }
    }

    private static var ledgers: [String: Ledger] = [:]
    private static let ledgersLock = NSLock()

    private static func ledger(for path: String) -> Ledger {
        ledgersLock.lock(); defer { ledgersLock.unlock() }
        if let l = ledgers[path] { l.used = Date(); return l }
        if ledgers.count >= 16, let stale = ledgers.min(by: { $0.value.used < $1.value.used })?.key {
            ledgers.removeValue(forKey: stale)
        }
        let l = Ledger()
        ledgers[path] = l
        return l
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    fileprivate static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

// MARK: - launchd

/// LaunchAgents that name a terminal — the fleet's scheduled pings and anything like them.
///
/// They are matched by what they run, not by what they are called: a job that types into a card has
/// to say which card, and the only stable ways to say it are the terminal's uuid and its tmux
/// session (`fv_<uuid>`). The label is a convention someone may not follow; the argument is not.
/// A job is still listed when its terminal has gone — that is when it is most worth seeing, since
/// it goes on firing at nothing — but only the board's own cards can show it.
enum LaunchdTriggers {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    /// `terminals` pairs each id with its tmux session name (`RemoteServer.sessionName`).
    static func scan(_ terminals: [(id: UUID, session: String)]) -> [UUID: [AgentTrigger]] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        let needles = terminals.map { ($0.id, $0.id.uuidString.lowercased(), $0.session) }
        var out: [UUID: [AgentTrigger]] = [:]
        for f in files where f.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: f),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            if (plist["Disabled"] as? Bool) == true { continue }
            let args = (plist["ProgramArguments"] as? [String]) ?? [(plist["Program"] as? String) ?? ""]
            let line = args.joined(separator: " ").lowercased()
            for (id, uuid, session) in needles where line.contains(uuid) || line.contains(session) {
                let t = AgentTrigger(kind: .launchd, id: label,
                                     schedule: schedule(plist["StartCalendarInterval"]),
                                     recurring: true,
                                     text: describe(args, terminal: uuid),
                                     command: args.joined(separator: " "),
                                     interval: (plist["StartInterval"] as? NSNumber)?.intValue,
                                     path: f.path)
                out[id, default: []].append(t)
            }
        }
        return out
    }

    /// `StartCalendarInterval` as cron: an absent key is a wildcard in both.
    static func schedule(_ v: Any?) -> String? {
        let dicts = (v as? [[String: Any]]) ?? ((v as? [String: Any]).map { [$0] } ?? [])
        guard !dicts.isEmpty else { return nil }
        let crons = dicts.map { d -> String in
            func f(_ k: String) -> String { (d[k] as? NSNumber).map { "\($0.intValue)" } ?? "*" }
            return [f("Minute"), f("Hour"), f("Day"), f("Month"), f("Weekday")].joined(separator: " ")
        }
        return crons.joined(separator: "; ")
    }

    /// The arguments as a person would say them: no interpreter, scripts by name, and the
    /// terminal's own uuid left out — the panel already says which terminal this is.
    static func describe(_ args: [String], terminal uuid: String) -> String {
        var a = args
        if let first = a.first, ["bash", "sh", "zsh", "python3", "python", "node", "env"]
            .contains((first as NSString).lastPathComponent) { a.removeFirst() }
        return a.filter { $0.lowercased() != uuid }
            .map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }
            .joined(separator: " ")
    }

    /// Unload it and move its plist to the Trash — recoverable, unlike `rm`, and gone from the next
    /// login either way. Returns what went wrong, or nil.
    static func remove(label: String, path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // A job that is not loaded fails bootout, and that is fine: the plist is what brings it back.
        try? p.run()
        p.waitUntilExit()
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}
