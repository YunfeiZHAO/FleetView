import SwiftUI

/// Whether a card sits in the board's "进行中" zone, where a running card takes the primary
/// container and a needs-you card the warn container. Everywhere else a card is a plain filled card:
/// colour is reserved for the one place that answers "what needs me now".
private struct CardEmphasisKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var cardEmphasis: Bool {
        get { self[CardEmphasisKey.self] }
        set { self[CardEmphasisKey.self] = newValue }
    }
}

/// One terminal, as a Material 3 card.
///
/// Three rows: what it is and how it is (status shape, name, clock), what it was last asked, and
/// whose it is (agent mark, tokens). No status word and no "claude"/"codex" label — the shape and the
/// mark carry those, and the words are in the tooltips. The actions appear on hover, in a row whose
/// height is reserved either way, so no two cards in a grid are ever different heights.
struct TerminalCardView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.cardEmphasis) private var emphasis
    let terminal: TerminalSession

    @State private var hovering = false
    @State private var renaming = false
    /// Non-nil while the copy button is showing feedback.
    @State private var idFlash: String?

    private var done: Bool { terminal.subtaskDone }
    private var highlighted: Bool { state.highlightedTerminalId == terminal.id }
    private var treeDropTarget: Bool { state.treeDropCardId == terminal.id }
    /// Exited or closed: still on the board, still clickable, but not live — Material's outlined
    /// card with its content at the disabled opacity.
    private var ended: Bool { terminal.status == .exited || terminal.status == .closed }

    /// Background and foreground when the card takes a container colour (see CardEmphasisKey).
    private var container: (bg: Color, fg: Color)? {
        guard emphasis else { return nil }
        switch terminal.status {
        case .working:  return (Theme.primaryContainer, Theme.onPrimaryContainer)
        case .needsYou: return (Theme.warnContainer, Theme.onWarnContainer)
        default:        return nil
        }
    }
    private var fg: Color { container?.fg ?? Theme.onSurface }
    private var fgSecondary: Color { container.map { $0.fg.opacity(0.78) } ?? Theme.onSurfaceVariant }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.allowsHitTesting(renaming)     // display-only unless renaming → drags pass through the name/status
            promptLine.allowsHitTesting(false)    // never let the prompt text intercept a drag
            footer                                 // keeps its buttons clickable; drag still works over it
        }
        .opacity(ended && !hovering ? Theme.endedOpacity : 1)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(ended ? Theme.outlineVariant : Color.clear, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(highlighted || treeDropTarget ? Theme.primary : Color.clear, lineWidth: 2))
        .background(GeometryReader { g in            // drop target: tree node, or another card
            Color.clear.preference(key: CardFramesKey.self,
                                   value: [terminal.id: [g.frame(in: .named("fleet"))]])
        })
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { state.raiseTerminal(terminal.id) } }
        // Plain drag, NO long-press: on macOS a click-drag never scrolls a ScrollView, so the drag can
        // begin the instant the pointer moves a few px. Requiring a press-and-hold first is what made
        // dragging feel broken ("often invalid"). A pure click (no movement) still falls through to the
        // tap above (raise), and simultaneousGesture lets the drag start even over the action buttons.
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("fleet"))
                .onChanged { value in state.dragChanged(terminal.id, to: value.location) }
                .onEnded { value in state.dragEnded(at: value.location) }
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { menuItems(inMenu: false) }
    }

    private var cardFill: Color {
        if let container { return container.bg }
        if ended { return .clear }
        return hovering ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: terminal.status, onColor: container?.fg)
            EditableText(text: terminal.name,
                         font: .fvTitleSmall,
                         color: fg,
                         onCommit: { state.renameTerminal(terminal.id, to: $0) },
                         editing: $renaming)
            Spacer(minLength: 6)
            if done {
                Image(systemName: "bookmark.fill").font(.system(size: 12))
                    .foregroundColor(container?.fg ?? Theme.tertiary)
                    .help("已加书签")
            }
            if terminal.windowHidden == true {        // window hidden, agent running: a click opens it
                Image(systemName: "eye.slash").font(.system(size: 12)).foregroundColor(fgSecondary)
                    .help("窗口已隐藏，agent 在后台继续运行")
            }
            timeLabel
        }
        .frame(height: 20)
    }

    /// The run clock while it works; otherwise how long ago anything happened here.
    ///
    /// The clock is anchored on the run's own start, not on `.now`: `.now` is re-evaluated on every
    /// body pass, so each of the board's (many) re-renders handed the TimelineView a brand-new
    /// schedule and restarted its tick.
    @ViewBuilder private var timeLabel: some View {
        if terminal.status == .working, let since = terminal.runningSince {
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text(RelativeTime.clock(since: since, now: ctx.date))
                    .font(.fvLabel).monospacedDigit().lineLimit(1)
                    .foregroundColor(container?.fg ?? Theme.primary)
                    .help("已运行 \(RelativeTime.clock(since: since, now: ctx.date))")
            }
            .fixedSize()
        } else if let last = terminal.lastActivity {
            TimelineView(.periodic(from: last, by: 30)) { ctx in
                Text(RelativeTime.compact(last, now: ctx.date))
                    .font(.fvLabel).monospacedDigit().lineLimit(1)
                    .foregroundColor(fgSecondary)
                    .help(lastRunHelp)
            }
            .fixedSize()
        }
    }

    private var lastRunHelp: String {
        guard let secs = terminal.lastRunSeconds else { return "最后一次活动" }
        return "上一轮用了 \(RelativeTime.clock(seconds: secs))"
    }

    // Collapse whitespace and hard-cap length so a very long prompt can't overflow the card.
    private var displayPrompt: String {
        guard !terminal.lastPrompt.isEmpty else { return "—" }
        let collapsed = terminal.lastPrompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 220 ? String(collapsed.prefix(220)) + "…" : collapsed
    }

    private var promptLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(terminal.status == .shell ? "$" : "›")
                .font(.fvMonoBody)
                .foregroundColor(fgSecondary)
            Text(displayPrompt)
                .font(.fvBodySmall)
                .foregroundColor(fgSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(terminal.lastPrompt)      // full prompt on hover (selection removed so drag works here)
        }
        // Two lines, always: a one-line prompt must not make a shorter card than its neighbours.
        .frame(height: 32, alignment: .top)
    }

    /// Whose it is, and what it has cost — then the actions, on hover.
    private var footer: some View {
        HStack(spacing: 8) {
            if terminal.agentKind != .unknown {
                AgentMark(kind: terminal.agentKind, tint: container?.fg)
                    .help(terminal.agentKind == .claude ? "Claude" : "Codex")
            }
            if terminal.newTokens > 0 {
                Text(TokenUsage.short(terminal.newTokens))
                    .font(.fvLabelSmall).monospacedDigit()
                    .foregroundColor(fgSecondary)
                    .help("\(terminal.newTokens) tokens（输入 + 输出，不含缓存读取）")
            }
            Spacer(minLength: 4)
            controls
                .opacity(hovering || idFlash != nil ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .frame(height: 28)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            copyButton
            roundButton("iphone", help: "在手机上打开这个终端的聊天") {
                state.dialog = .webLink(terminalId: terminal.id)
            }
            Menu { menuItems(inMenu: true) } label: {
                Image(systemName: "ellipsis").font(.system(size: 13))
                    .foregroundColor(fgSecondary)
                    .frame(width: 28, height: 28)
                    .background(roundFill).clipShape(Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("更多")
        }
    }

    private var roundFill: Color {
        container.map { $0.fg.opacity(0.12) } ?? Theme.surfaceContainerHighest
    }

    /// The card's actions, for its context menu and for its ⋯ menu.
    @ViewBuilder private func menuItems(inMenu: Bool) -> some View {
        if inMenu {
            if terminal.status.isOpen {
                Button("置于最前") { state.raiseTerminal(terminal.id) }
            } else {
                Button("重新打开") { state.reopenTerminal(terminal.id) }
            }
            Button("复制对话文件路径") { copyTranscriptPath() }
            Divider()
        }
        Button("重命名…") {
            if inMenu { state.requestRename(terminal.id) } else { renaming = true }
        }
        Button(state.treePanelTerminalId == terminal.id ? "关闭对话树" : "打开对话树") {
            if state.treePanelTerminalId == terminal.id { state.closeSessionTree() }
            else { state.openSessionTree(terminal.id) }
        }
        Button("复制（分叉会话）") { state.duplicateTerminal(terminal.id) }
        Button("复制为空白终端") { state.duplicateTerminal(terminal.id, blank: true) }
        Button(done ? "取消书签" : "加书签") { state.toggleSubtaskDone(terminal.id) }
        if terminal.windowHidden == true {
            Button("显示窗口") { state.showTerminal(terminal.id) }
        } else if state.windowState(terminal.id) == .open {
            Button("隐藏窗口（继续运行）") { state.hideTerminal(terminal.id) }
        }
        if terminal.clusterId != nil {
            Button("移出组") { state.removeFromCluster(terminal.id) }
        }
        Divider()
        Button("移除终端", role: .destructive) { state.removeTerminal(terminal.id) }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func copyTranscriptPath() {
        // `transcriptPath(for:)`, not the stored `transcriptPath`: it resolves Codex from its
        // rollouts ahead of the hook pointer, which is the case where the stored value is silently
        // frozen on a file from days ago.
        if let path = state.transcriptPath(for: terminal.id) {
            copyToClipboard(path)
            flashId("path")
        } else {
            // Said out loud rather than copying an empty string: a card that only ever held a
            // shell has no conversation, and silence looks like a failed copy.
            flashId("none")
        }
    }

    /// Click copies the terminal id (what `project-manager` takes); double-click copies the
    /// conversation file's path.
    ///
    /// One exclusive gesture, not two `onTapGesture`s, and high-priority so it beats the card: two
    /// stacked taps fire the single on the first click and the double never forms, and the card's
    /// own tap (raise) competes for the same click from above.
    private var copyButton: some View {
        Image(systemName: idFlash == nil ? "doc.on.doc" : (idFlash == "none" ? "xmark" : "checkmark"))
            .font(.system(size: 12))
            .foregroundColor(fgSecondary)
            .frame(width: 28, height: 28)
            .background(roundFill).clipShape(Circle())
            .contentShape(Circle())
            .highPriorityGesture(
                TapGesture(count: 2).onEnded { copyTranscriptPath() }
                    .exclusively(before: TapGesture().onEnded {
                        copyToClipboard(terminal.id.uuidString.lowercased())
                        flashId("id")
                    })
            )
            .help(idFlash == "none" ? "这个终端没有对话记录"
                  : "单击复制终端 ID（\(String(terminal.id.uuidString.prefix(8)).lowercased())），双击复制对话文件路径")
    }

    private func flashId(_ text: String) {
        idFlash = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { idFlash = nil }
    }

    private func roundButton(_ name: String, help: String,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12))
                .foregroundColor(fgSecondary)
                .frame(width: 28, height: 28)
                .background(roundFill).clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The agent's own mark, small: Claude's starburst in its clay, Codex's hexagon in plain ink.
/// Identity, not status — it never colours a border or a fill.
struct AgentMark: View {
    let kind: AgentKind
    var tint: Color? = nil
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch kind {
            case .claude:
                ClaudeMark().stroke(tint ?? Theme.claudeTint,
                                    style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
            case .codex:
                ZStack {
                    Hexagon().stroke(tint ?? Theme.codexTint,
                                     style: StrokeStyle(lineWidth: size * 0.12, lineJoin: .round))
                    Circle().fill(tint ?? Theme.codexTint).frame(width: size * 0.22, height: size * 0.22)
                }
            case .unknown:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2 * 0.9
        for i in 0..<4 {
            let a = Double(i) * .pi / 4
            p.move(to: CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a)))
            p.addLine(to: CGPoint(x: c.x - R * cos(a), y: c.y - R * sin(a)))
        }
        return p
    }
}

private struct Hexagon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2 * 0.9
        for i in 0..<6 {
            let a = Double(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

struct StatusDot: View {
    let status: TermStatus
    var onColor: Color? = nil

    var body: some View { StatusGlyph(status: status, onColor: onColor) }
}
