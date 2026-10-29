import SwiftUI
import AppKit

/// The right-hand panel a card's trigger chip opens: everything that will make that terminal's
/// agent act on its own, each with a way to take it away (see AgentTrigger for where they come
/// from, and AppState.cancelTrigger for what taking one away does).
struct TriggersPanel: View {
    static let width: Double = 400

    @EnvironmentObject var state: AppState
    let terminalId: UUID

    @State private var history: TriggerHistory?
    /// The row whose delete is waiting for a second click.
    @State private var confirming: String?
    @State private var expanded: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var copiedId = false

    private var terminal: TerminalSession? { state.terminals.first { $0.id == terminalId } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.outlineVariant).frame(height: 1)
            // Once a minute is all "next 23:09 · 5m" needs, and it is one timer for the panel.
            TimelineView(.everyMinute) { ctx in
                ScrollView {
                    content(now: ctx.date)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.panel)
        .onExitCommand { confirming != nil ? (confirming = nil) : state.closeTriggers() }
        // Re-read when a new report arrives (a cron added, one fired): incremental, so cheap.
        .task(id: historyKey) { await loadHistory() }
        .onChange(of: terminalId) { _, _ in confirming = nil; expanded = []; failures = [:] }
    }

    private var historyKey: String {
        "\(terminalId)|\(state.triggerReports[terminalId]?.at.timeIntervalSince1970 ?? 0)"
    }

    private func loadHistory() async {
        guard let t = terminal, t.agentKind == .claude, let path = state.transcriptPath(for: terminalId) else {
            history = nil
            return
        }
        history = await Task.detached(priority: .utility) { TriggerHistory.read(path: path) }.value
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "alarm").font(.system(size: 15)).foregroundColor(Theme.primary)
                Text(L(.trigTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Spacer()
                Button { state.closeTriggers() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(.plain).help(L(.closeEsc))
            }
            if let t = terminal {
                Button {
                    copy(t.id.uuidString.lowercased())
                    copiedId = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { copiedId = false }
                } label: {
                    HStack(spacing: 6) {
                        StatusGlyph(status: t.status, size: 12)
                        Text(copiedId ? L(.copied) : t.name).font(.fvLabel).lineLimit(1)
                        if t.agentKind != .unknown { AgentMark(kind: t.agentKind, size: 11) }
                    }
                    .foregroundColor(Theme.onSurfaceVariant)
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .strokeBorder(Theme.outlineVariant, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L(.treeCopyId))
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }

    // MARK: Content

    @ViewBuilder private func content(now: Date) -> some View {
        let all = terminal.map { state.triggers(for: $0) } ?? []
        VStack(alignment: .leading, spacing: 14) {
            if let note = sourceNote(now: now) {
                Text(note).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if all.isEmpty {
                emptyState
            } else {
                section(L(.trigSectionScheduled), all.filter { $0.kind == .cron }, now: now)
                section(L(.trigSectionBackground), all.filter { $0.kind == .background }, now: now)
                section(L(.trigSectionLaunchd), all.filter { $0.kind == .launchd }, now: now)
            }
        }
    }

    /// Where the list comes from and how fresh it is — said once, above it, because "the agent
    /// reported this at the end of its last turn" is the whole of what it can be trusted for.
    private func sourceNote(now: Date) -> String? {
        guard let t = terminal else { return nil }
        if t.agentKind == .codex { return L(.trigCodexNote) }
        guard t.status.isAgent else { return t.agentKind == .claude ? L(.trigNotRunning) : nil }
        guard let at = state.triggerReports[terminalId]?.at else { return L(.trigNeverReported) }
        return L(.trigReportedAt(Self.when(at, now: now)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "alarm").font(.system(size: 26)).foregroundColor(Theme.outline)
            Text(L(.trigNone)).font(.fvTitleSmall).foregroundColor(Theme.onSurface)
            Text(L(.trigNoneDetail)).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    @ViewBuilder private func section(_ title: String, _ items: [AgentTrigger], now: Date) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title).font(.fvLabel).foregroundColor(Theme.onSurfaceVariant)
                    Text("\(items.count)").font(.fvLabelSmall).monospacedDigit().foregroundColor(Theme.outline)
                }
                ForEach(items, id: \.key) { row($0, now: now) }
            }
        }
    }

    // MARK: A row

    private func row(_ t: AgentTrigger, now: Date) -> some View {
        let d = history?.detail(for: t) ?? TriggerHistory.Detail()
        let busy = state.isCancelling(t, on: terminalId)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(t, wakeup: d.wakeup))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.onSecondaryContainer)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.secondaryContainer))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title(t)).font(.fvTitleSmall).foregroundColor(Theme.onSurface)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    ForEach(tags(t, d), id: \.self) { tag in
                        Text(tag).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                            .padding(.horizontal, 6).frame(height: 18)
                            .overlay(Capsule().strokeBorder(Theme.outlineVariant, lineWidth: 1))
                            .fixedSize()
                    }
                }
                Text(idLine(t)).font(.fvMono).foregroundColor(Theme.onSurfaceVariant)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let meta = metaLine(t, d, now: now) {
                    Text(meta).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = d.reason, !reason.isEmpty {
                    Text(L(.trigReason(reason))).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                payload(t, d)
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                        Text(L(t.kind == .launchd ? .trigRemoving : .trigCancelling))
                            .font(.fvLabel).foregroundColor(Theme.primary)
                    }
                    .padding(.top, 2)
                } else if confirming == t.key {
                    confirmBox(t, wakeup: d.wakeup)
                }
                if let f = failures[t.key] {
                    Text(f).font(.fvLabel).foregroundColor(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !busy && confirming != t.key {
                Button {
                    failures[t.key] = nil
                    confirming = t.key
                } label: {
                    Image(systemName: t.kind == .background ? "stop.circle" : "trash")
                        .font(.system(size: 13)).foregroundColor(Theme.onSurfaceVariant)
                        .frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L(t.kind == .background ? .trigStopHelp : .trigDeleteHelp))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surfaceContainerHigh))
        .opacity(busy ? 0.7 : 1)
    }

    /// The prompt it will send, or what is running — the part you read to know what this is.
    @ViewBuilder private func payload(_ t: AgentTrigger, _ d: TriggerHistory.Detail) -> some View {
        let text: String = {
            switch t.kind {
            case .cron:       return d.prompt ?? TriggerHistory.unclipped(t.text)
            case .background: return t.text
            case .launchd:    return t.text
            }
        }()
        let code = t.kind == .background ? t.command : (t.kind == .launchd ? t.command : nil)
        let open = expanded.contains(t.key)
        VStack(alignment: .leading, spacing: 6) {
            if !text.isEmpty {
                Text(text).font(.fvBodySmall).foregroundColor(Theme.onSurface)
                    .lineLimit(open ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let code, !code.isEmpty, code != text {
                Text(code).font(.fvMono).foregroundColor(Theme.onSurfaceVariant)
                    .lineLimit(open ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if text.count > 240 || (code?.count ?? 0) > 160 || text.filter({ $0 == "\n" }).count > 3 {
                Button {
                    if open { expanded.remove(t.key) } else { expanded.insert(t.key) }
                } label: {
                    Text(L(open ? .trigShowLess : .trigShowAll)).font(.fvLabel).foregroundColor(Theme.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.surfaceContainer))
    }

    private func confirmBox(_ t: AgentTrigger, wakeup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(t.kind == .launchd ? .trigConfirmLaunchd : .trigConfirmAgent))
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button { confirming = nil } label: {
                    Text(L(.cancel)).font(.fvLabel).foregroundColor(Theme.primary)
                        .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    confirming = nil
                    if let why = state.cancelTrigger(t, on: terminalId, wakeup: wakeup) { failures[t.key] = why }
                } label: {
                    Text(L(t.kind == .background ? .trigConfirmStop : .trigConfirm))
                        .font(.fvLabel).lineLimit(1).fixedSize().foregroundColor(Theme.onPrimary)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(Theme.error).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Words

    private func icon(_ t: AgentTrigger, wakeup: Bool) -> String {
        switch t.kind {
        case .cron:
            if wakeup { return "arrow.triangle.2.circlepath" }
            return t.recurring == false ? "alarm" : "repeat"
        case .background:
            switch t.taskType {
            case "monitor":  return "waveform.path.ecg"
            case "subagent": return "person.2"
            default:         return "hourglass"
            }
        case .launchd:
            return "gearshape.2"
        }
    }

    private func title(_ t: AgentTrigger) -> String {
        switch t.kind {
        case .cron, .launchd:
            if let s = t.schedule, let shape = CronExpr.shape(s, recurring: t.recurring) {
                return Self.words(shape)
            }
            if let s = t.schedule { return s }
            if let i = t.interval { return L(.trigInterval(Self.span(i))) }
            return t.id
        case .background:
            return t.taskType ?? t.id
        }
    }

    private func tags(_ t: AgentTrigger, _ d: TriggerHistory.Detail) -> [String] {
        switch t.kind {
        case .cron:
            if d.wakeup { return [L(.trigWakeup)] }
            return [L(t.recurring == false ? .trigOneShot : .trigRecurring)]
        case .background:
            return t.status.map { [$0] } ?? []
        case .launchd:
            return []
        }
    }

    /// The machine's words for it: the expression as written, then the id the agent knows it by.
    private func idLine(_ t: AgentTrigger) -> String {
        switch t.kind {
        case .cron:       return [t.schedule, t.id].compactMap { $0 }.joined(separator: "  ·  ")
        case .background: return t.id
        case .launchd:    return t.id
        }
    }

    private func metaLine(_ t: AgentTrigger, _ d: TriggerHistory.Detail, now: Date) -> String? {
        var parts: [String] = []
        if let next = TriggerHistory.nextFire(t, d, after: now) {
            let at = Self.when(next, now: now) + " (" + Self.span(Int(next.timeIntervalSince(now))) + ")"
            parts.append(L(d.lag > 0 ? .trigNextAbout(at) : .trigNext(at)))
        }
        if t.kind == .cron {
            if d.fires > 0, let last = d.lastFire {
                parts.append(L(.trigFired(d.fires, Self.when(last, now: now))))
            } else if history != nil {
                parts.append(L(.trigNeverFired))
            }
            if let c = d.created { parts.append(L(.trigCreated(Self.when(c, now: now)))) }
            if let e = d.expires { parts.append(L(.trigExpires(Self.when(e, now: now)))) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func words(_ s: CronExpr.Shape) -> String {
        switch s {
        case .everyMinutes(let n): return L(.trigEveryMinutes(n))
        case .hourly(let m):       return L(.trigHourly(m.map { String(format: ":%02d", $0) }.joined(separator: " ")))
        case .daily(let h, let m): return L(.trigDaily(String(format: "%02d:%02d", h, m)))
        case .weekdays(let h, let m): return L(.trigWeekdays(String(format: "%02d:%02d", h, m)))
        case .once(let mo, let d, let h, let m): return L(.trigOnce(String(format: "%d-%d %02d:%02d", mo, d, h, m)))
        }
    }

    /// A time of day when it is today, with the date otherwise.
    static func when(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "M-d HH:mm"
        return f.string(from: d)
    }

    /// "5m", "2h10m", "3d" — the card's units, for a span either side of now.
    static func span(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h\(m % 60)m" }
        return "\(h / 24)d"
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
