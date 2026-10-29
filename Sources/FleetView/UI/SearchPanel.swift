import SwiftUI
import AppKit

/// Search across the board and every local Claude and Codex conversation (⌘K). It opens over the
/// board rather than docking beside a terminal, because a hit can come from any project — including
/// one that has no terminal open right now.
///
/// A list on the left and what is selected on the right. One click always means the same thing —
/// select it and show it — and opening is a separate, explicit act: Return, double-click, the
/// button, or dragging onto the board. It used to be that clicking a board row opened that terminal
/// while clicking a conversation only previewed it, opening a conversation was a drag and nothing
/// else, and the preview floated as a second layer over the list it came from.
struct SearchPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool
    /// The message under the pointer in a conversation, which is the one offering "resume from here".
    @State private var hoveredStep: Int64?

    /// One selectable row: a project to open, a thing on the board, or one message that matched.
    enum Item: Identifiable {
        case project(SearchModel.ProjectGroup)
        case fleet(SearchModel.FleetHit)
        case hit(SearchIndex.Hit, SearchModel.Group)

        var id: String {
            switch self {
            case .project(let p): return "p:\(p.id)"
            case .fleet(let f): return "f:\(f.id.uuidString)"
            case .hit(let h, _): return "h:\(h.id)"
            }
        }
    }

    /// A project's rows when it is open: board hits, then its messages newest first across all of
    /// its conversations.
    private func rows(of p: SearchModel.ProjectGroup) -> [Item] {
        guard model.isExpanded(p) else { return [] }
        let hits = p.sessions.flatMap { g in g.hits.map { (h: $0, g: g) } }.sorted { $0.h.ts > $1.h.ts }
        return p.fleet.map { Item.fleet($0) } + hits.map { Item.hit($0.h, $0.g) }
    }

    /// Every row in list order, for the arrow keys. Projects are rows only where they fold.
    private var items: [Item] {
        model.projectGroups.flatMap { p in (model.folds ? [Item.project(p)] : []) + rows(of: p) }
    }
    private var selected: Item? { items.first { $0.id == model.selectedKey } }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(Theme.outlineVariant)
            modeBar
            Divider().overlay(Theme.outlineVariant)
            HStack(spacing: 0) {
                list.frame(width: 460)
                Divider().overlay(Theme.outlineVariant)
                detail.frame(maxWidth: .infinity)
            }
        }
        .frame(width: 1080, height: 680)
        .background(Theme.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dialog))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .onExitCommand { state.closeSearch() }
        // Tab widens the search a step, shift-Tab narrows it. Intercepted here rather than bound
        // on the field: the field has focus, and Tab is what SwiftUI would use to leave it.
        .background {
            Button("") { model.mode = model.mode.next }
                .keyboardShortcut(.tab, modifiers: []).hidden()
            Button("") { model.mode = model.mode.previous }
                .keyboardShortcut(.tab, modifiers: .shift).hidden()
        }
        .onAppear {
            model.app = state
            focused = true
            model.refreshIndex()
        }
        // Results change under the selection: keep it if it is still there, else take the first,
        // so the right side always shows something and Return always has a target.
        .onChange(of: items.map(\.id)) { _, keys in
            if model.selectedKey == nil || !keys.contains(model.selectedKey!) { select(keys.first) }
        }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.onSurfaceVariant).font(.system(size: 18))
            TextField(model.mode == .fleet ? L(.searchFleetPlaceholder) : L(.searchConvPlaceholder), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(Theme.onSurface)
                .focused($focused)
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            if model.indexing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.onSurfaceVariant)
                }.buttonStyle(.plain).help(L(.clear))
            }
            Text("Esc").font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.surfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 24).frame(height: 64)
    }

    // MARK: - Modes and scope

    private var modeBar: some View {
        HStack(spacing: 8) {
            ForEach(SearchModel.Mode.allCases) { m in
                chip(m.title, icon: m.icon, count: model.mode == m ? model.total : nil, on: model.mode == m) {
                    // Picking "已移除" here means every project; the scoped view is what a
                    // project's own button opens. Without this the scope from that button would
                    // stick, and the tab would quietly keep showing one project's rows.
                    if m == .archive { model.archiveProject = nil }
                    model.mode = m
                }
            }
            if model.mode != .fleet {
                Divider().frame(height: 20).overlay(Theme.outlineVariant).padding(.horizontal, 4)
                chip(L(.searchMine), on: model.scope == .prompts) { model.scope = .prompts }
                chip(L(.searchReplies), on: model.scope == .replies) { model.scope = .replies }
                chip(L(.searchAll), on: model.scope == .both) { model.scope = .both }
                chip("Claude", on: model.source == .claude) {
                    model.source = model.source == .claude ? nil : .claude
                }
                chip("Codex", on: model.source == .codex) {
                    model.source = model.source == .codex ? nil : .codex
                }
            }
            Spacer()
            if model.truncated {
                Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundColor(Theme.warn)
                    .help(L(.searchTruncated(model.total)))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    /// A Material filter chip.
    private func chip(_ title: String, icon: String? = nil, count: Int? = nil, on: Bool,
                      _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12)) }
                Text(title).font(.fvLabel)
                if let count, count > 0 { Text("\(count)").font(.fvLabel).monospacedDigit().opacity(0.75) }
            }
            .foregroundColor(on ? Theme.onSecondaryContainer : Theme.onSurfaceVariant)
            .padding(.horizontal, 12).frame(height: 32)
            .background(on ? Theme.secondaryContainer : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .strokeBorder(on ? Color.clear : Theme.outlineVariant, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    @ViewBuilder private var list: some View {
        if let failure = model.failure, model.preview == nil {
            message(failure, icon: "exclamationmark.triangle", tint: Theme.warn)
        } else if model.mode != .archive,
                  model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Archive is a list, not a query: an empty box there means "everything", not "waiting
            // for you to type". Every other mode has nothing to show until something is typed.
            message(model.indexing ? model.indexNote : statsLine, icon: "text.magnifyingglass",
                    tint: Theme.onSurfaceVariant)
        } else if model.projectGroups.isEmpty {
            message(model.mode == .archive
                        ? (model.indexing ? model.indexNote : L(.searchNoArchived))
                        : (model.indexing ? model.indexNote : L(.searchNothing)),
                    icon: model.mode == .archive ? "archivebox" : "questionmark.circle",
                    tint: Theme.onSurfaceVariant)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.projectGroups) { p in
                            if model.folds {
                                row(.project(p))
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").font(.system(size: 12))
                                    Text(p.name).font(.fvLabelSmall).lineLimit(1)
                                    Spacer()
                                    Text("\(p.count)").font(.fvLabelSmall).monospacedDigit()
                                }
                                .foregroundColor(Theme.onSurfaceVariant)
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                            }
                            // Under its project, indented, so a message reads as belonging to it.
                            ForEach(rows(of: p)) { item in
                                row(item).padding(.leading, model.folds ? 22 : 0)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
                .onChange(of: model.selectedKey) { _, key in
                    if let key { proxy.scrollTo(key) }
                }
            }
        }
    }

    private var statsLine: String {
        model.stats.messages > 0 ? L(.searchStats(model.stats.files, model.stats.messages)) : ""
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        let on = item.id == model.selectedKey
        Group {
            switch item {
            case .project(let p): projectRow(p, on: on)
            case .fleet(let f): fleetRow(f, on: on)
            case .hit(let h, let g):
                if let card = g.card { cardRow(card, hit: h, on: on) }
                else { hitRow(h, on: on) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Theme.secondaryContainer : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet))
        .contentShape(Rectangle())
        .id(item.id)
        .onTapGesture(count: 2) { select(item.id); openSelected() }
        .onTapGesture {
            select(item.id)
            if case .project(let p) = item { withAnimation(.easeOut(duration: 0.15)) { model.toggle(p) } }
        }
        .modifier(HitDrag(item: item, state: state))
    }

    private func projectRow(_ p: SearchModel.ProjectGroup, on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(model.isExpanded(p) ? 90 : 0))
                .frame(width: 12)
            Image(systemName: "folder").font(.system(size: 13))
            Text(p.name).font(.fvTitleSmall).lineLimit(1)
                .foregroundColor(on ? Theme.onSecondaryContainer : Theme.onSurface)
            Spacer(minLength: 8)
            Text(shortDate(p.newest)).font(.fvLabelSmall).monospacedDigit()
            Text("\(p.count)").font(.fvLabel).monospacedDigit()
                .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 20)
                .background(on ? Theme.surfaceContainerHigh : Theme.surfaceContainerHighest)
                .clipShape(Capsule())
        }
        .foregroundColor(Theme.onSurfaceVariant)
    }

    private func fleetRow(_ h: SearchModel.FleetHit, on: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if h.kind == .terminal, let s = h.status {
                    StatusGlyph(status: s)
                } else {
                    Image(systemName: h.kind == .cluster ? "square.stack" : "folder")
                        .font(.system(size: 13)).foregroundColor(Theme.onSurfaceVariant)
                        .frame(width: 16, height: 16)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(highlighted(h.name, base: on ? Theme.onSecondaryContainer : Theme.onSurface))
                        .font(.fvTitleSmall).lineLimit(1)
                    if let a = h.agent, a != .unknown { AgentMark(kind: a, size: 11) }
                }
                Text(highlighted(h.detail, base: Theme.onSurfaceVariant))
                    .font(.fvBodySmall).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func hitRow(_ hit: SearchIndex.Hit, on: Bool) -> some View {
        let isPrompt = hit.role == .user
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isPrompt ? "person" : "sparkles")
                .font(.system(size: 11))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(width: 24, height: 24)
                .background(on ? Theme.surfaceContainerHigh : Theme.surfaceContainerHighest)
                .clipShape(Circle())
                .help(isPrompt ? L(.searchYourPrompt) : L(.searchAgentReply))
            VStack(alignment: .leading, spacing: 4) {
                Text(highlighted(snippet(hit.body), base: on ? Theme.onSecondaryContainer : Theme.onSurface))
                    .font(.fvBody).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // No project here: messages are listed only where the list folds, under their
                // project's row.
                HStack(spacing: 6) {
                    AgentMark(kind: hit.src == .claude ? .claude : .codex, size: 10)
                    Text(shortDate(hit.ts))
                }
                .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
            }
        }
    }

    /// A removed card, drawn as the card it was: its name, then what it was last asked. The
    /// conversation is the right side's job. Drawn as the conversation's last message instead, the
    /// list read as a project's history with no cards in it — the names were a grey line under
    /// each message, and the name is what you came looking for.
    private func cardRow(_ card: TerminalArchive, hit: SearchIndex.Hit, on: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AgentMark(kind: hit.src == .claude ? .claude : .codex, size: 13)
                .frame(width: 24, height: 24)
                .background(on ? Theme.surfaceContainerHigh : Theme.surfaceContainerHighest)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(highlighted(card.name, base: on ? Theme.onSecondaryContainer : Theme.onSurface))
                        .font(.fvTitleSmall).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(shortDate(hit.ts)).font(.fvLabelSmall).monospacedDigit()
                }
                // The prompt as the card showed it, behind its "›". A card that never recorded one
                // falls back to where its conversation ended.
                HStack(alignment: .top, spacing: 6) {
                    if !card.lastPrompt.isEmpty { Text("›").font(.fvMonoBody) }
                    Text(highlighted(snippet(card.lastPrompt.isEmpty ? hit.body : card.lastPrompt),
                                     base: Theme.onSurfaceVariant))
                        .font(.fvBodySmall).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundColor(Theme.onSurfaceVariant)
    }

    private func message(_ text: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 28)).foregroundColor(tint.opacity(0.6))
            if !text.isEmpty {
                Text(text).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    // MARK: - Detail (right side)

    @ViewBuilder private var detail: some View {
        switch selected {
        case .project(let p)?:
            projectDetail(p)
        case .hit(let hit, let g)?:
            conversation(hit, card: g.card)
        case .fleet(let f)?:
            fleetDetail(f)
        case nil:
            message("", icon: "sidebar.right", tint: Theme.onSurfaceVariant)
        }
    }

    /// The conversation around the hit, read from the index. Nothing is written until it is opened.
    /// Headed by the removed card it belonged to when there is one — the list's project row already
    /// says the project.
    @ViewBuilder private func conversation(_ hit: SearchIndex.Hit, card: TerminalArchive?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentMark(kind: hit.src == .claude ? .claude : .codex, size: 13)
                Text(card?.name ?? projectName(hit.project)).font(.fvTitleSmall).foregroundColor(Theme.onSurface)
                    .lineLimit(1)
                Text(shortDate(hit.ts)).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                Spacer()
                if let p = model.preview, p.id == hit.id {
                    Text(L(.searchNMessages(p.context.count))).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)
            if let p = model.preview, p.id == hit.id {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(p.context) { msg in
                                step(msg, isHit: msg.id == hit.id).id(msg.id)
                            }
                        }
                        .padding(.horizontal, 24).padding(.vertical, 8)
                    }
                    .onAppear { proxy.scrollTo(hit.id, anchor: .center) }
                    // The window paints first and the whole conversation replaces it a moment later;
                    // without this the hit slides off screen exactly when it finishes loading.
                    .onChange(of: p.context.count) { _, _ in proxy.scrollTo(hit.id, anchor: .center) }
                }
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            Divider().overlay(Theme.outlineVariant)
            HStack(spacing: 12) {
                hint(draggable: true)
                Spacer()
                if let failure = model.failure {
                    Text(failure).font(.fvLabelSmall).foregroundColor(Theme.warn).lineLimit(1)
                }
                resumeButtons(hit)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
    }

    /// The two ways back into a conversation: as it is now, in its own card, or from a step of it in
    /// a new one. Return takes whichever is likelier to be meant — in the drawer of removed cards
    /// that is the card coming back, everywhere else it is the place the search landed on.
    @ViewBuilder private func resumeButtons(_ hit: SearchIndex.Hit) -> some View {
        let busy = model.opening == hit.id
        let latest = button(busy && model.openingLatest ? L(.searchOpening) : L(.searchResumeLatest),
                            icon: "arrow.uturn.forward", busy: busy && model.openingLatest,
                            primary: model.mode == .archive) {
            model.resumeLatest(hit, in: state)
        }.help(L(.searchResumeLatestHelp))
        let here = button(busy && !model.openingLatest ? L(.searchOpening) : L(.searchResumeHere),
                          icon: "arrow.up.right.square", busy: busy && !model.openingLatest,
                          primary: model.mode != .archive) {
            model.open(hit, in: state)
        }.help(L(.searchResumeHereHelp))
        if model.mode == .archive { here; latest } else { latest; here }
    }

    /// A message, and on hover the way to resume the conversation from it — any step, not only
    /// the one the search landed on. It sits beside the bubble, on the side the bubble leaves open,
    /// and keeps its place while hidden so the list does not shift under the pointer.
    private func step(_ msg: SearchIndex.Hit, isHit: Bool) -> some View {
        let isPrompt = msg.role == .user
        let busy = model.opening == msg.id && !model.openingLatest
        let shown = hoveredStep == msg.id || busy
        let resume = Button { model.open(msg, in: state) } label: {
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 12, height: 12) }
                else { Image(systemName: "arrow.uturn.backward").font(.system(size: 10)) }
                Text(L(.searchResumeStep)).font(.fvLabelSmall)
            }
            .foregroundColor(Theme.primary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Theme.surfaceContainerHighest).clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L(.searchResumeStepHelp))
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .disabled(model.opening != nil)
        return HStack(alignment: .bottom, spacing: 8) {
            if isPrompt { resume }
            bubble(msg, isHit: isHit)
            if !isPrompt { resume }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredStep = msg.id } else if hoveredStep == msg.id { hoveredStep = nil }
        }
    }

    private func bubble(_ msg: SearchIndex.Hit, isHit: Bool) -> some View {
        let isPrompt = msg.role == .user
        let text = Text(markdownText(msg.body, query: model.query,
                                     base: isPrompt ? Theme.onPrimaryContainer : Theme.onSurface))
            .font(.fvBody)
            .lineSpacing(3)
            .textSelection(.enabled)
            .lineLimit(isHit ? nil : 12)
        // No spacers of its own: `step` lays it out, with the resume button between the bubble
        // and the empty side.
        return text
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isPrompt ? Theme.primaryContainer
                        : (isHit ? Theme.surfaceContainerHighest : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isHit ? Theme.primary : Color.clear, lineWidth: 1.5))
            .frame(maxWidth: .infinity, alignment: isPrompt ? .trailing : .leading)
    }

    private func fleetDetail(_ f: SearchModel.FleetHit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let s = f.status { StatusGlyph(status: s, size: 18) }
                Text(f.name).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                if let s = f.status { Text(s.label).font(.fvLabel).foregroundColor(Theme.statusColor(s)) }
            }
            if let c = f.clusterName {
                Label(c, systemImage: "square.stack").font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
            }
            Text(f.detail).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .textSelection(.enabled)
            Spacer()
            HStack {
                hint(draggable: false)
                Spacer()
                primaryButton(f.kind == .terminal ? L(.searchJumpTerminal) : L(.searchSwitchProject),
                              icon: "arrow.right", busy: false) { openFleet(f) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Keyboard help, and — for a conversation, which is the only thing a drag can open — the drag.
    private func hint(draggable: Bool) -> some View {
        HStack(spacing: 6) {
            Text("↑↓").font(.fvLabelSmall).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.surfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(L(.searchSelect)).font(.fvLabelSmall)
            if draggable {
                Image(systemName: "hand.draw").font(.system(size: 12)).padding(.leading, 8)
                Text(L(.searchDragHint)).font(.fvLabelSmall)
            }
        }
        .foregroundColor(Theme.onSurfaceVariant)
    }

    private func primaryButton(_ title: String, icon: String, busy: Bool,
                               _ action: @escaping () -> Void) -> some View {
        button(title, icon: icon, busy: busy, primary: true, action)
    }

    /// The filled button is the one Return presses, and the only one that says so.
    private func button(_ title: String, icon: String, busy: Bool, primary: Bool,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14) }
                else { Image(systemName: icon).font(.system(size: 13)) }
                Text(title).font(.fvLabel)
                if primary {
                    Text("↵").font(.fvLabelSmall).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.onPrimary.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .foregroundColor(primary ? Theme.onPrimary : Theme.primary)
            .padding(.leading, 16).padding(.trailing, primary ? 12 : 16).frame(height: 40)
            .background(primary ? Theme.primary : Color.clear)
            .overlay(Capsule().strokeBorder(primary ? Color.clear : Theme.outline, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy || model.opening != nil)
    }

    // MARK: - Actions

    private func select(_ key: String?) {
        model.selectedKey = key
        if case .hit(let h, _)? = items.first(where: { $0.id == key }), model.preview?.id != h.id {
            model.showPreview(h)
        }
    }

    private func move(_ delta: Int) {
        let keys = items.map(\.id)
        guard !keys.isEmpty else { return }
        let i = keys.firstIndex(of: model.selectedKey ?? "") ?? (delta > 0 ? -1 : keys.count)
        select(keys[max(0, min(keys.count - 1, i + delta))])
    }

    private func openSelected() {
        switch selected {
        case .project(let p)?: withAnimation(.easeOut(duration: 0.15)) { model.toggle(p) }
        case .hit(let h, _)?:
            // What the filled button does (see `resumeButtons`).
            if model.mode == .archive { model.resumeLatest(h, in: state) } else { model.open(h, in: state) }
        case .fleet(let f)?: openFleet(f)
        case nil: break
        }
    }

    private func openFleet(_ f: SearchModel.FleetHit) {
        if f.kind == .terminal {
            state.raiseTerminal(f.id)
            state.closeSearch()
        } else if let pid = f.projectId {
            state.selectedProjectId = pid
            state.scrollToId = pid
            state.closeSearch()
        }
    }

    private func projectDetail(_ p: SearchModel.ProjectGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 16)).foregroundColor(Theme.onSurfaceVariant)
                Text(p.name).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
            }
            if p.id != "—" {
                Text(p.id).font(.fvMono).foregroundColor(Theme.onSurfaceVariant)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            Text(L(.searchProjectSummary(p.count, p.sessions.count)))
                .font(.fvBody).foregroundColor(Theme.onSurface)
            Text(model.isExpanded(p) ? L(.searchProjectOpenHint) : L(.searchProjectClosedHint))
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Helpers

    private func projectName(_ path: String) -> String {
        path == "—" ? L(.unknownProject) : (path as NSString).lastPathComponent
    }

    /// One line, collapsed and windowed onto the first match — a matched prompt is often a wall of
    /// pasted text, and taking the first 240 characters of one regularly showed no match at all.
    private func snippet(_ body: String) -> String {
        let flat = body.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        let width = 240
        guard flat.count > width else { return flat }
        guard let hit = firstMatch(in: flat) else { return String(flat.prefix(width)) + "…" }
        let lead = 60
        var start = flat.index(hit, offsetBy: -lead, limitedBy: flat.startIndex) ?? flat.startIndex
        if flat.distance(from: start, to: flat.endIndex) < width {
            start = flat.index(flat.endIndex, offsetBy: -width)
        }
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end]
            + (end < flat.endIndex ? "…" : "")
    }

    private func firstMatch(in text: String) -> String.Index? {
        SearchIndex.terms(model.query)
            .compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }
            .min()
    }

    private func highlighted(_ text: String, base: Color) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = base
        markTerms(in: &a, query: model.query)
        return a
    }

    /// "2026-07-29T02:23:30.123Z" → "07-29 10:23", in this Mac's time zone. Transcripts stamp
    /// UTC, and cutting the string apart showed the UTC clock — eight hours off in Beijing.
    private func shortDate(_ iso: String) -> String {
        guard let d = Self.iso.date(from: iso) ?? Self.isoPlain.date(from: iso) else {
            guard iso.count >= 16 else { return "" }
            return "\(iso.prefix(10).suffix(5)) \(iso.dropFirst(11).prefix(5))"
        }
        return Self.short.string(from: d)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

/// Dragging a row onto the board opens it there, the same gesture the session tree uses. A long
/// threshold: a click that slips a few points must stay a click, now that a click is how you select.
private struct HitDrag: ViewModifier {
    let item: SearchPanel.Item
    let state: AppState

    func body(content: Content) -> some View {
        if case .hit(let hit, _) = item {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 16, coordinateSpace: .named("fleet"))
                    .onChanged { state.searchDragChanged(hit: hit, location: $0.location) }
                    .onEnded { state.treeDragEnded(at: $0.location) }
            )
        } else {
            content
        }
    }
}

/// Mark every search term in `a`. Each term is marked on its own because that is what the query
/// means — two words are two AND-ed terms, not one substring.
func markTerms(in a: inout AttributedString, query: String) {
    for term in SearchIndex.terms(query) where !term.isEmpty {
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: term, options: .caseInsensitive) {
            a[r].backgroundColor = Theme.tertiaryContainer
            a[r].foregroundColor = Theme.onTertiaryContainer
            from = r.upperBound
        }
    }
}

/// A message as it was written: inline Markdown (bold, code, links) rendered, line breaks kept,
/// search terms marked. Agents answer in Markdown, and showing it raw put `**` and backticks in
/// front of every point that mattered.
func markdownText(_ raw: String, query: String = "", base: Color) -> AttributedString {
    var a = (try? AttributedString(markdown: raw, options: .init(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(raw)
    a.foregroundColor = base
    markTerms(in: &a, query: query)
    return a
}
