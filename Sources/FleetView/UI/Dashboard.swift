import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    /// Is a level-1 surface up, so the dashboard should recede? (See LayerConfig for the depths.)
    ///
    /// A drag whose target IS the dashboard does not recede at all: dropping a tree node or a
    /// search hit lands on the board or on a card, and neither is aimable through a wash.
    private var dashboardReceded: Bool {
        if state.treeDrag != nil { return false }
        return state.treePanelTerminalId != nil
            || state.searchOpen
            || state.dialog != nil
            || state.draggingTerminalId != nil
    }

    /// A dragged card recedes the board but must not blur it. It used not to matter — a card's
    /// targets were the action dock and the tree edge, both drawn above the wash — but a card can
    /// now be dropped on another card, so the board is a target again and has to stay readable.
    private var dashboardBlurred: Bool { state.draggingTerminalId == nil }

    var body: some View {
        HStack(spacing: 0) {
            let receded = dashboardReceded
            HStack(spacing: 0) {
                Sidebar().frame(width: state.sidebarWidth)
                SidebarDivider()
                VStack(spacing: 0) {
                    DynamicPanel()      // agent-authored dynamic UI — tops the content column, beside the sidebar
                    TopBar()
                    // A peer's board replaces this Mac's rather than floating over it: the two look
                    // alike enough that anything less than taking the whole column would leave you
                    // unsure which fleet you are looking at — and these boards start terminals.
                    if let peer = state.peerSelected {
                        PeerWebBoard(peer: peer).id(peer.id)
                    } else {
                        MainArea()
                            .background(GeometryReader { g in     // the tree-drag drop area ("fleet" space)
                                Color.clear.preference(key: BoardFrameKey.self,
                                                       value: g.frame(in: .named("fleet")))
                            })
                    }
                }
            }
            .receded(receded, blurred: dashboardBlurred)
            if state.treePanelTerminalId != nil {
                TreePanelDivider()
                SessionTreePanel(model: state.treeModel)
                    .frame(width: state.treePanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.22), value: state.treePanelTerminalId != nil)
        .background(Theme.bg)
        .frame(minWidth: 960, minHeight: 580)
        .overlay { treeInspector }     // interactive: text selection + scrolling
        .overlay { dragOverlay }
        .overlay { searchOverlay }
        .overlay { DialogHost() }
        .animation(.easeOut(duration: 0.16), value: state.dialog)
        .coordinateSpace(name: "fleet")
        .onPreferenceChange(BoardFrameKey.self) { state.boardFrame = $0 }
        .onPreferenceChange(CardFramesKey.self) { state.cardFrames = $0 }
        .onPreferenceChange(ClusterFramesKey.self) { state.clusterFrames = $0 }
        .onPreferenceChange(ProjectFramesKey.self) { state.projectFrames = $0 }
        .sheet(item: $state.nameSheet) { req in
            NameSheet(request: req).environmentObject(state)
        }
        // ⌘F opens search; Tab widens its scope. The session tree binds ⌘F to its own node filter,
        // which is find-in-this-panel and the right meaning while you are in it — so ⌘F defers to it
        // and ⌘K stays the accelerator that always reaches search.
        .background {
            if state.treePanelTerminalId == nil {
                Button("") { state.toggleSearch() }
                    .keyboardShortcut("f", modifiers: .command).hidden()
            }
            Button("") { state.toggleSearch() }
                .keyboardShortcut("k", modifiers: .command).hidden()
        }
    }

    /// Search floats over the whole board rather than docking beside a terminal: a hit can come
    /// from any project, including one with nothing open.
    ///
    /// While a result is being dragged the panel gets out of the way — it covers the very board
    /// the node is being dropped onto. It stays mounted (opacity, not removal) because the drag
    /// gesture lives on the row and would be cancelled the moment the row disappeared.
    @ViewBuilder private var searchOverlay: some View {
        if state.searchOpen {
            let dragging = state.treeDrag?.hit != nil
            ZStack {
                // Catcher only — the dashboard's own recede supplies the dimming. A click on empty
                // space closes the deepest layer first: the preview (2) before the panel (1).
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { state.closeSearch() }
                    .allowsHitTesting(!dragging)
                SearchPanel(model: state.searchModel).environmentObject(state)
                    .opacity(dragging ? 0.12 : 1)
                    .scaleEffect(dragging ? 0.97 : 1)
            }
            .animation(.easeOut(duration: 0.16), value: dragging)
            .transition(.opacity)
        }
    }

    /// The floating node inspector. It observes the tree model directly (see TreeInspector):
    /// AppState only holds it as a plain reference, so a card whose visibility was decided here
    /// would never react to hovering, pinning, or the tree finishing its load.
    @ViewBuilder private var treeInspector: some View {
        if state.treePanelTerminalId != nil {
            TreeInspector(model: state.treeModel,
                          focus: state.treeModel.focus,
                          boardFrame: state.boardFrame,
                          dragging: state.treeDrag != nil,
                          onClosePanel: { state.closeSessionTree() })
        }
    }

    /// What releasing here would do, in the words of the thing it would land on. Nil when nothing
    /// is under the cursor, so the chip never promises an outcome that isn't there.
    private var dropHint: String? {
        switch state.clusterDrop {
        case .cluster(let id):
            return "松开：加入「\(state.cluster(id)?.name ?? "cluster")」"
        case .card(let id):
            guard let t = state.terminals.first(where: { $0.id == id }) else { return nil }
            return "松开：与「\(t.name)」组成 cluster"
        case .leaveCluster:
            let name = state.terminals.first { $0.id == state.draggingTerminalId }?
                .clusterId.flatMap { state.cluster($0)?.name }
            return "松开：移出「\(name ?? "cluster")」"
        case .project(let id):
            let name = state.projects.first { $0.id == id }?.name ?? "project"
            return "松开：移到「\(name)」"
        case nil:
            return nil
        }
    }

    /// The second line of the chip, and only for the drop that earns one. A move relocates the
    /// conversation on disk and restarts the agent to pick it up again, which is more than the
    /// gesture looks like — so it says so while there is still time to let go somewhere else.
    ///
    /// Read off the card's own fields, never from disk: this is recomputed on every frame of a
    /// drag, and resolving a transcript walks a directory.
    private var dropNote: String? {
        guard case .project = state.clusterDrop,
              let t = state.terminals.first(where: { $0.id == state.draggingTerminalId })
        else { return nil }
        // An agent mid-turn is the one thing worth saying ahead of everything else: the move kills
        // the session to reopen it, and the turn in flight does not survive that.
        if t.status == .working { return "agent 正在跑，会被打断后带着记录重开" }
        if t.agentKind == .codex {
            // Codex files rollouts by date, so there is no path to move — saying "the history moves
            // too" would be describing something that never happens.
            return "Codex 记录按日期存放，不用搬；会在新项目里重新打开"
        }
        guard t.transcriptPath != nil else { return "还没有对话记录，只是换个项目" }
        return "对话记录一起搬过去，然后重新打开这段对话"
    }

    /// One outline around something on the board, in "fleet" coordinates.
    ///
    /// Clipped to the board because every rect here is a laid-out frame, not a visible one: a card
    /// scrolled half under the top bar still reports its whole height, and a ring drawn across the
    /// header outlines nothing that is there.
    /// `alpha`/`fill`/`glow` are all read against `tint` at full strength — passing a pre-faded
    /// colour would multiply instead, and a 0.35 stroke with a 0.06 fill would quietly become 0.02.
    @ViewBuilder
    private func ring(_ rect: CGRect, radius: CGFloat, tint: Color, width: CGFloat,
                      alpha: Double = 1, dash: [CGFloat] = [],
                      fill: Double = 0, glow: Double = 0) -> some View {
        let f = rect.intersection(state.boardFrame)
        if !f.isNull, !f.isEmpty {
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.opacity(fill))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .stroke(tint.opacity(alpha), style: StrokeStyle(lineWidth: width, dash: dash)))
                .shadow(color: tint.opacity(glow), radius: 12)
                .frame(width: f.width, height: f.height)
                .position(x: f.midX, y: f.midY)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var dragOverlay: some View {
        ZStack {
            if let dragId = state.draggingTerminalId {
                // No scrim of its own: the dashboard already receded (see dashboardReceded), and a
                // second wash on top of it also fell over the zones, which are the thing you are
                // aiming at.
                SessionTreeDropEdge(hot: state.hoveredTreeZone, frame: state.sessionTreeZoneFrame)
                // What is being landed on — a whole cluster box, or a single card. Drawn HERE, not
                // on the target itself, because the board lies under the dim wash and a highlight
                // that is dimmed along with everything else is not a highlight.
                //
                // Clipped to the board: a target scrolled half under the top bar still reports its
                // whole frame, and an accent ring drawn across the header highlights nothing.
                // Where the card came from, drawn first and drawn quietly: the loudest thing on the
                // board has to be what will happen, not what already is.
                if let c = state.dragSourceClusterFrame {
                    ring(c, radius: 14, tint: Theme.accent, width: 2, alpha: 0.35)
                }
                ForEach(Array(state.dragSourceCardFrames.enumerated()), id: \.offset) { _, r in
                    ring(r, radius: 12, tint: Theme.accent, width: 1.5, alpha: 0.5,
                         dash: [5, 4], fill: 0.06)
                }
                // …and what releasing here would do. Joining fills and glows; leaving is a dashed
                // amber outline — the colour the dock's Leave Cluster zone already uses, and
                // deliberately not the solid accent, because walking out of a task is the opposite
                // outcome and must not read as landing in one.
                if let target = state.clusterDropFrame {
                    ring(target.rect, radius: target.radius,
                         tint: target.leaving ? Theme.amber : Theme.accent, width: 2.5,
                         dash: target.leaving ? [7, 5] : [],
                         fill: target.leaving ? 0.05 : 0.16,
                         glow: target.leaving ? 0 : 0.5)
                }
                VStack { Spacer(); ActionDock(terminalId: dragId).environmentObject(state) }
                if let t = state.terminals.first(where: { $0.id == dragId }) {
                    DragPreviewChip(name: t.name, status: t.status, hint: dropHint, note: dropNote)
                        .position(x: state.dragLocation.x, y: state.dragLocation.y - 16)
                }
            }
            if let d = state.treeDrag {
                // Board glow: release here → fork-open the node standalone.
                if state.treeBoardHot {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.accent, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.045)))
                        .frame(width: max(0, state.boardFrame.width - 14),
                               height: max(0, state.boardFrame.height - 14))
                        .position(x: state.boardFrame.midX, y: state.boardFrame.midY)
                }
                // The only hint is on the chip itself, and it names what THIS spot will do.
                TreeDragChip(prompt: d.prompt, action: state.treeDropCardId != nil ? .joinCluster
                                                     : (state.treeBoardHot ? .newTerminal : .none))
                    .position(x: d.location.x, y: d.location.y - 22)
            }
        }
        .allowsHitTesting(false)   // purely visual; the drag is driven by the card gesture
        .animation(.easeOut(duration: 0.16), value: state.draggingTerminalId)
        .animation(.easeOut(duration: 0.12), value: state.treeBoardHot)
        .animation(.spring(response: 0.24, dampingFraction: 0.75), value: state.clusterDrop)
        .onPreferenceChange(ZoneFrameKey.self) { state.setZoneFrames($0) }
    }

    static func pickFolder(into state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        // Starting a project you haven't created yet is a normal thing to want, and the panel's own
        // New Folder button does it without FleetView inventing a second dialog for naming and
        // placing a directory — it is the same control every other Mac app offers here.
        panel.canCreateDirectories = true
        panel.prompt = "Open Project"
        panel.message = "Pick a folder for this project — or make a new one."
        if panel.runModal() == .OK { for url in panel.urls { state.addProject(path: url.path) } }
    }

    /// Make a folder and open it as a project. The open panel's own New Folder button does this too,
    /// but only for people who know it is there — starting a project from nothing is common enough
    /// to be worth a button of its own.
    static func newFolder(into state: AppState) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "new-project"
        panel.prompt = "Create"
        panel.message = "Name the new project folder."
        // Where this user's projects actually live; the panel falls back to its own last location
        // when that folder is absent.
        let projectsHome = FV.home.appendingPathComponent("PycharmProjects")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectsHome.path, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = projectsHome
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // `withIntermediateDirectories: true` also means "already exists is fine". The save
            // panel offers to replace an existing name, and that must never become deleting a
            // directory someone already has work in — it is opened as-is instead.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            state.addProject(path: url.path)
        } catch {
            FV.log("new folder failed: \(url.path): \(error.localizedDescription)")
            NSAlert(error: error).runModal()
        }
    }
}

/// Board-wide actions that need an answer before they run.
///
/// Here rather than duplicated in the menu and the top bar: two copies of a confirmation are two
/// chances for one of them to understate what it is about to do.
@MainActor
enum BoardActions {
    /// Close every terminal. The cards survive, so this is recoverable and the caller's own UI
    /// (the top-bar panel) is confirmation enough; the menu item, which has no such panel, asks.
    static func confirmCloseAll(_ state: AppState, reason: String) {
        let open = state.openTerminalCount
        let a = NSAlert()
        a.messageText = open > 0 ? "关闭 \(open) 个终端？" : "关闭所有终端？"
        a.informativeText = "正在运行的 agent 会被停止。终端卡片会留在看板上——点击卡片可以重新打开并继续原来的会话。"
        a.addButton(withTitle: "关闭全部")
        a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        state.closeAllTerminals(reason: reason)
    }

    /// Empty the board. Always asks, from every entry point: this is the one action on the board
    /// that nothing can put back.
    static func confirmClear(_ state: AppState, reason: String) {
        let p = state.projects.count, t = state.terminals.count
        guard p > 0 || t > 0 else { return }
        let a = NSAlert()
        a.messageText = "清空看板？"
        // Says what goes and what stays. "This cannot be undone" alone leaves people guessing
        // whether their conversations are about to be deleted — they are not.
        a.informativeText = """
        \(p) 个项目和 \(t) 个终端会从 FleetView 移除，正在运行的 agent 会被停止。终端名称、mark 和 cluster 分组会一并丢失，无法撤销。

        对话历史不受影响：它们保存在 Claude / Codex 自己的记录里，⌘K 仍然可以搜索并打开。项目文件夹本身也不会被删除。
        """
        a.addButton(withTitle: "清空看板")
        a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        state.clearBoard(reason: reason)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var state: AppState
    @State private var showingClone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.onPrimary)
                    .frame(width: 24, height: 24)
                    .background(Theme.primary).clipShape(RoundedRectangle(cornerRadius: 8))
                Text("FleetView").font(.fvTitleMedium).foregroundColor(Theme.onSurface)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            // Terminals (collapsible) — the selected peer's while one is being viewed, so the
            // sidebar turns to that machine along with the board rather than describing this one.
            sectionHeader(title: "终端",
                          count: state.peerSelected == nil ? state.tasks.count
                                                           : state.peerTerminals.count,
                          collapsed: state.tasksCollapsed) {
                withAnimation(.easeOut(duration: 0.18)) { state.tasksCollapsed.toggle() }
                state.save()
            }
            if !state.tasksCollapsed {
                if let peer = state.peerSelected {
                    PeerTaskList(peer: peer)
                } else if state.taskGroups.isEmpty {
                    // "No terminals yet" is a lie when there are plenty and the filter is hiding them.
                    Text(state.showOnlyMarked && !state.terminals.isEmpty
                         ? "没有加了书签的终端" : "还没有终端")
                        .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                        .padding(.horizontal, 18).padding(.top, 6)
                    Spacer(minLength: 0)
                } else {
                    taskList
                }
            }

            Divider().overlay(Theme.outlineVariant).padding(.horizontal, 12)

            // Notes (collapsible) — sits above the footer; grows to fill when the terminals are collapsed.
            NotesSection(fill: state.tasksCollapsed)
            if state.tasksCollapsed && state.notesCollapsed { Spacer(minLength: 0) }

            Divider().overlay(Theme.outlineVariant).padding(.horizontal, 12)
            // Icons only: three words side by side truncated at the sidebar's default width, and
            // each of these is a once-in-a-while action with its name in the tooltip.
            HStack(spacing: 0) {
                footerButton("folder", help: "打开文件夹作为项目") { DashboardView.pickFolder(into: state) }
                footerButton("folder.badge.plus", help: "新建文件夹并作为项目打开") {
                    DashboardView.newFolder(into: state)
                }
                footerButton("square.and.arrow.down", help: "克隆 GitHub 仓库") { showingClone = true }
            }
            .padding(.vertical, 6)
        }
        .background(Theme.surfaceContainerLow)
        .sheet(isPresented: $showingClone) { CloneSheet().environmentObject(state) }
    }

    @State private var showDormant = false

    private var taskList: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let groups = state.taskGroups
                let active = groups.filter { !state.isDormant($0.project.id, now: ctx.date) }
                let dormant = groups.filter { state.isDormant($0.project.id, now: ctx.date) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(active) { group in groupView(group) }
                    // The projects the board has folded, folded here too: one line naming them,
                    // and the rows only when you ask.
                    if !dormant.isEmpty {
                        Button { withAnimation(.easeOut(duration: 0.18)) { showDormant.toggle() } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(showDormant ? 90 : 0))
                                Text(dormant.map(\.project.name).joined(separator: " · "))
                                    .font(.fvLabelSmall).lineLimit(1).truncationMode(.tail)
                            }
                            .foregroundColor(Theme.onSurfaceVariant.opacity(0.8))
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("两小时内没动过的项目")
                        if showDormant {
                            ForEach(dormant) { group in groupView(group) }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func groupView(_ group: TaskGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12))
            Text(group.project.name).font(.fvLabelSmall).lineLimit(1)
        }
        .foregroundColor(Theme.onSurfaceVariant)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        ForEach(group.tasks) { task in TaskRow(task: task) }
    }

    /// A collapsible section header (chevron + title + count).
    private func sectionHeader(title: String, count: Int, collapsed: Bool,
                               toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.onSurfaceVariant)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title).font(.fvLabel).foregroundColor(Theme.onSurfaceVariant)
                Spacer()
                Text("\(count)").font(.fvLabel).monospacedDigit().foregroundColor(Theme.onSurfaceVariant)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18).padding(.vertical, 9)
    }

    private func footerButton(_ icon: String, help: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(Theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Draggable divider that resizes the sidebar (so long task titles can be revealed).
struct SidebarDivider: View {
    @EnvironmentObject var state: AppState
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.primary : Theme.outlineVariant)
            .frame(width: hovering ? 2 : 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { h in
                        hovering = h
                        if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if startWidth == nil { startWidth = state.sidebarWidth }
                                let base = startWidth ?? state.sidebarWidth
                                state.sidebarWidth = min(520, max(180, base + v.translation.width))
                            }
                            .onEnded { _ in startWidth = nil; state.save() }
                    )
            )
    }
}

struct TaskRow: View {
    @EnvironmentObject var state: AppState
    let task: TaskItem
    @State private var hover = false

    private var terminal: TerminalSession? {
        if case .terminal(let id) = task { return state.terminals.first { $0.id == id } }
        return nil
    }
    private var cluster: Cluster? {
        if case .cluster(let id) = task { return state.clusters.first { $0.id == id } }
        return nil
    }
    private var isCluster: Bool { if case .cluster = task { return true }; return false }
    private var isSelected: Bool {
        if let t = terminal { return state.highlightedTerminalId == t.id }
        if let c = cluster  { return state.highlightedClusterId == c.id }
        return false
    }

    private var name: String { terminal?.name ?? cluster?.name ?? "" }
    private var status: TermStatus {
        if let t = terminal { return t.status }
        if let c = cluster { return state.clusterAggregateStatus(c.id) }
        return .closed
    }
    private var done: Bool {
        if let t = terminal { return t.subtaskDone }
        if let c = cluster { return state.clusterDone(c.id) }
        return false
    }
    private var ended: Bool { status == .exited || status == .closed }
    private var memberCount: Int { cluster.map { state.members(ofCluster: $0.id).count } ?? 0 }

    /// A Material navigation-drawer item: shape, name, and — only while it runs — the clock.
    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(status: status)
            HStack(spacing: 6) {
                Text(name).font(.fvBody).lineLimit(1)
                    .foregroundColor(isSelected ? Theme.onSecondaryContainer
                                     : (ended ? Theme.onSurfaceVariant : Theme.onSurface))
                if isCluster {
                    HStack(spacing: 2) {
                        Image(systemName: "square.stack").font(.system(size: 11))
                        Text("\(memberCount)").font(.fvLabelSmall).monospacedDigit()
                    }
                    .foregroundColor(Theme.onSurfaceVariant)
                    .help("\(memberCount) 个终端")
                }
                if done {
                    Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundColor(Theme.tertiary)
                }
            }
            Spacer(minLength: 4)
            if status == .working, let since = terminal?.runningSince {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(RelativeTime.clock(since: since, now: ctx.date))
                        .font(.fvLabel).monospacedDigit().foregroundColor(Theme.primary)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(isSelected ? Theme.secondaryContainer
                    : (hover ? Theme.surfaceContainerHigh : Color.clear))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture { state.focusTask(task) }   // highlight + scroll, do not raise the window
        .help("\(name) · \(status.label)")
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var jobs = BackgroundJobs.shared
    /// Which address the QR is currently of. The Mac can have two and the phone is only ever on
    /// one of them, so the code has to be able to follow.
    @State private var showJobs = false

    private var working: Int { state.terminals.filter { $0.status == .working }.count }
    private var needs: Int { state.terminals.filter { $0.status == .needsYou }.count }

    var body: some View {
        HStack(spacing: 8) {
            // Which fleet you are looking at comes first: everything to the right acts on it.
            if state.peerStripVisible {
                PeerStrip(fleet: state.peerFleet)
            } else {
                peersButton
            }
            Spacer(minLength: 12)
            if needs > 0 { statusBadge(.needsYou, needs) }
            if working > 0 { statusBadge(.working, working) }
            jobsButton
            updateButton
            searchField
            markFilterButton
            recentStripButton
            webButton
            powerButton
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(height: 64)
        .background(Theme.surface)
    }

    /// One control in the bar. Every one is `controlHeight` tall and every one has a container —
    /// a bar whose controls are half filled and half bare reads as two different heights even when
    /// they are not.
    private func barButton(_ symbol: String, text: String? = nil, on: Bool = false, help: String,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14))
                if let text { Text(text).font(.fvLabel).monospacedDigit() }
            }
            .foregroundColor(on ? Theme.onSecondaryContainer : Theme.onSurfaceVariant)
            .padding(.horizontal, text == nil ? 0 : 14)
            .frame(minWidth: Theme.controlHeight, minHeight: Theme.controlHeight)
            .background(on ? Theme.secondaryContainer : Theme.surfaceContainerHigh)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(help)
    }

    /// How many need you / are running, as the shapes the cards use, in their container colours.
    private func statusBadge(_ status: TermStatus, _ n: Int) -> some View {
        let (bg, fg) = status == .needsYou ? (Theme.warnContainer, Theme.onWarnContainer)
                                           : (Theme.primaryContainer, Theme.onPrimaryContainer)
        return HStack(spacing: 6) {
            StatusGlyph(status: status, size: 15, onColor: fg)
            Text("\(n)").font(.fvLabel).monospacedDigit()
        }
        .foregroundColor(fg)
        .padding(.horizontal, 14)
        .frame(height: Theme.controlHeight)
        .background(bg).clipShape(Capsule())
        .help("\(n) 个\(status.label)")
    }

    /// The way in to conversation search, drawn as the field it opens.
    private var searchField: some View {
        Button { state.toggleSearch() } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14))
                Text("搜索").font(.fvBody)
                Spacer(minLength: 8)
                Text("⌘K").font(.fvLabelSmall)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.surfaceContainerHighest).clipShape(Capsule())
            }
            .foregroundColor(Theme.onSurfaceVariant)
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(width: 200, height: Theme.controlHeight)
            .background(state.searchOpen ? Theme.secondaryContainer : Theme.surfaceContainerHigh)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("搜索所有 Claude / Codex 对话历史 (⌘K)")
    }

    /// Background work — a clone, a self-update — with a bar on it and a way out of it. Present
    /// only while something is running or has failed; the rest of the time there is nothing to say
    /// and a permanently parked "0 tasks" chip would be one more thing in a row that is already full.
    /// Show or hide the RECENTLY USED strip.
    ///
    /// It lives up here, not on the strip: a control inside the thing it hides disappears with it,
    /// and then there is no way back. Only shown once there is something for the strip to hold, so
    /// it stays off a board that has just been opened.
    @ViewBuilder private var recentStripButton: some View {
        if state.terminals.contains(where: { $0.status != .working && $0.lastActivity != nil }) {
            barButton("clock.arrow.circlepath", on: state.showRecentStrip,
                      help: state.showRecentStrip ? "隐藏「最近使用」" : "显示「最近使用」") {
                state.showRecentStrip.toggle(); state.save()
            }
        }
    }

    @ViewBuilder private var jobsButton: some View {
        if !jobs.jobs.isEmpty {
            let broken = !jobs.failed.isEmpty
            Button { showJobs.toggle() } label: {
                HStack(spacing: 5) {
                    if broken {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                    } else if jobs.running.isEmpty {
                        // Finished, and lingering for its three seconds. A spinner next to "Done"
                        // would be the pill contradicting itself on its way out.
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                    } else if let fraction = jobs.overall {
                        JobRing(fraction: fraction)
                    } else {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                            .frame(width: 11, height: 11)
                    }
                    Text(jobs.pillLabel).font(.fvLabel).monospacedDigit()
                }
                .foregroundColor(broken ? Theme.onErrorContainer : Theme.onPrimaryContainer)
                .padding(.horizontal, 14).frame(height: Theme.controlHeight)
                .background(broken ? Theme.errorContainer : Theme.primaryContainer).clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("后台任务 — 点击查看进度或取消")
            .popover(isPresented: $showJobs, arrowEdge: .bottom) { jobsPopover }
        }
    }

    private var jobsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("后台任务").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
            ForEach(jobs.jobs) { job in JobRowView(job: job) }
            Text("这些任务在后台跑，看板、终端和正在工作的 agent 都不受影响。")
                .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 320)
    }

    /// Shown only when a newer release exists. A pill rather than a dialog: an update is worth
    /// noticing, not worth interrupting a fleet of running agents for. Clicking opens the release
    /// page; the × means "not this version" and it will not come back until the next one.
    @ViewBuilder private var updateButton: some View {
        // Silent while an install runs: the job pill beside it is saying so, with a bar and a way
        // out, and two pills for one thing is how they drift into disagreeing about it.
        if state.updates.status == nil, let r = state.updates.available {
            HStack(spacing: 5) {
                // Same alert the menu item shows — one offer, not two that can drift apart.
                Button { UpdateUI.present(.newer(r), updates: state.updates) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(r.version).font(.fvLabel)
                    }
                    .foregroundColor(Theme.onAccent)
                    .padding(.leading, 14).frame(height: Theme.controlHeight)
                }
                .buttonStyle(.plain)
                .help("FleetView \(r.version) 已发布 — 点击安装")
                Button { state.updates.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.onAccent.opacity(0.7))
                }
                .buttonStyle(.plain).padding(.trailing, 12)
                .help("忽略这个版本")
            }
            .background(Theme.accent).clipShape(Capsule())
        }
    }

    private var marked: Int { state.terminals.filter(\.subtaskDone).count }

    /// Show only marked terminals. Filled bookmark + a count while it is on, because a board that is
    /// hiding most of itself has to say so somewhere that is always visible — the alternative is
    /// wondering where your terminals went. It stays out of the way when nothing is marked at all.
    @ViewBuilder private var markFilterButton: some View {
        if marked > 0 || state.showOnlyMarked {
            barButton(state.showOnlyMarked ? "bookmark.fill" : "bookmark", text: "\(marked)",
                      on: state.showOnlyMarked,
                      help: state.showOnlyMarked ? "显示全部终端" : "只显示加了书签的终端") {
                state.showOnlyMarked.toggle(); state.save()
            }
        }
    }

    /// Stop the whole fleet. A dialog rather than a bare button, because this is one click away
    /// from ending every running agent — the dialog is the confirmation, and it is also where the
    /// "do this on quit too" setting lives, next to the thing it automates.
    private var powerButton: some View {
        let open = state.openTerminalCount
        return barButton("power", text: open > 0 ? "\(open)" : nil, help: "关闭所有终端 / 退出时关闭") {
            state.dialog = .closeAll
        }
    }

    /// Opens the LAN switcher. The count appears once a scan has run — before that there is nothing
    /// honest to put there, and a "0" would read as "nobody is out there" rather than "not looked".
    private var peersButton: some View {
        let others = state.peerFleet.found.filter { !$0.isSelf }.count
        return barButton("network", text: state.peerFleet.scanned && others > 0 ? "\(others)" : nil,
                         help: "局域网里的其他 FleetView") {
            state.togglePeerStrip()
        }
    }

    private var webButton: some View {
        barButton("iphone", help: "在手机上打开看板") { state.dialog = .webLink(terminalId: nil) }
    }

}

// MARK: - Main area (all projects + terminals, always visible)

struct MainArea: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.projects.isEmpty {
            EmptyState(icon: "square.grid.2x2",
                       title: "Open a project to get started",
                       subtitle: "Every project can launch clean terminal windows for your agents.",
                       button: "Open Folder") { DashboardView.pickFolder(into: state) }
        } else if state.showOnlyMarked && state.visibleProjects.isEmpty {
            // The filter is on and nothing is marked. Offering the way out here matters: this screen
            // is otherwise indistinguishable from having lost every terminal.
            EmptyState(icon: "bookmark",
                       title: "No marked terminals",
                       subtitle: "The board is filtered to marked terminals only. Mark one from its card, or show everything again.",
                       button: "Show all terminals") { state.showOnlyMarked = false; state.save() }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Re-sorted once a minute as well as on every change: a project goes quiet by
                    // the clock, not by any event.
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        let active = state.visibleProjects.filter { !state.isDormant($0.id, now: ctx.date) }
                        let dormant = state.visibleProjects.filter { state.isDormant($0.id, now: ctx.date) }
                        VStack(alignment: .leading, spacing: 24) {
                            RunningStrip()
                            RecentStrip()
                            ForEach(active) { p in
                                ProjectSection(project: p).id(p.id)
                            }
                            if !dormant.isEmpty {
                                DormantZone(projects: dormant)
                            }
                        }
                        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onChange(of: state.scrollToId) { _, id in
                    if let id { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }
}

/// The board's grid, the same everywhere a card is laid out, so a card is the same size wherever it
/// appears.
enum BoardGrid {
    static let columns = [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 12)]
    static let spacing: CGFloat = 12
    /// A card in a sideways strip, where there is no grid to size it.
    static let stripCardWidth: CGFloat = 300
}

/// A zone's heading: an optional mark, a name, a count. Sentence case — the all-caps labels these
/// replace ("RUNNING NOW") shouted the structure louder than the cards.
struct ZoneHeader: View {
    var icon: String? = nil
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
            }
            Text(title).font(.fvTitleSmall).foregroundColor(Theme.onSurface)
            Text("\(count)").font(.fvTitleSmall).monospacedDigit().foregroundColor(Theme.onSurfaceVariant)
            Spacer()
        }
    }
}

/// "进行中": everything that needs you, then everything that is working, lifted to the top of the
/// board and out of its project.
///
/// The board is grouped by project because that is how work is organised; this answers the other
/// question — what wants me, what is moving — which otherwise means scanning every section. Needs-you
/// comes first because it is the only state that is waiting on you. The cards are the same cards,
/// drawn with their container colour (see CardEmphasisKey) — the only coloured cards on the board —
/// and each carries the project it came from, because that is the one thing the grouping used to say
/// and this zone cannot.
///
/// Absent, not empty, when nothing qualifies: a permanent "nothing is running" header is a line of
/// furniture that is wrong most of the time.
struct RunningStrip: View {
    @EnvironmentObject var state: AppState

    private var live: [TerminalSession] {
        let v = state.visible(state.terminals.filter { $0.status == .working || $0.status == .needsYou })
        return v.filter { $0.status == .needsYou } + v.filter { $0.status == .working }
    }

    var body: some View {
        if !live.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ZoneHeader(title: "进行中", count: live.count)
                LazyVGrid(columns: BoardGrid.columns, alignment: .leading, spacing: BoardGrid.spacing) {
                    ForEach(live) { t in
                        VStack(alignment: .leading, spacing: 6) {
                            ProjectTag(terminal: t)
                            TerminalCardView(terminal: t)
                        }
                    }
                }
                .environment(\.cardEmphasis, true)
            }
        }
    }
}

/// Where a card lives when it is not here. Double-click opens that folder, the same gesture the
/// project header answers to — this label says "project" and so it should behave like one.
///
/// Shared by both strips: each one lifts cards out of the grouping that would otherwise say which
/// project they belong to, so each one owes the reader this line.
struct ProjectTag: View {
    @EnvironmentObject var state: AppState
    let terminal: TerminalSession

    var body: some View {
        let name = state.projects.first { $0.id == terminal.projectId }?.name ?? "—"
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 12))
            Text(name).font(.fvLabelSmall).lineLimit(1)
        }
        .foregroundColor(Theme.onSurfaceVariant)
        .padding(.leading, 2)
        // The whole tag, not just the text: hitting only the characters would be a worse target
        // than the thing looks.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.openInFinder(terminal.projectId) }
        .help("双击在 Finder 中打开 \(name)")
    }
}

/// The cards you used most recently, on a tray of their own above the projects.
///
/// Same cards again, at the same size, so a terminal reached from here drags, marks and opens
/// exactly like the one in its project section — a second place to find a terminal, not a second
/// kind of terminal. The tray is what tells this row apart from a project's grid; the cards are not
/// restyled for it.
///
/// Whatever is already in "进行中" is left out: the same card twice within one screen reads as two
/// terminals. So is a card that has never been used. Capped, because this is a shortcut and not a
/// second board; one row, scrolled sideways, because a shortcut that grows a second row pushes the
/// board itself off screen.
struct RecentStrip: View {
    @EnvironmentObject var state: AppState

    private static let limit = 6

    private var recent: [TerminalSession] {
        state.visible(state.terminals.filter {
            $0.status != .working && $0.status != .needsYou && $0.lastActivity != nil
        })
        .sorted {
            let (a, b) = ($0.lastActivity ?? .distantPast, $1.lastActivity ?? .distantPast)
            // `sort` is not stable, and this list is rebuilt on every activity tick.
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
        .prefix(Self.limit)
        .map { $0 }
    }

    var body: some View {
        if state.showRecentStrip && !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ZoneHeader(icon: "clock.arrow.circlepath", title: "最近使用", count: recent.count)
                    .padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: BoardGrid.spacing) {
                        ForEach(recent) { t in
                            VStack(alignment: .leading, spacing: 6) {
                                ProjectTag(terminal: t)
                                TerminalCardView(terminal: t)
                            }
                            .frame(width: BoardGrid.stripCardWidth)
                        }
                    }
                    // A focus ring that a tight clip would cut.
                    .padding(.vertical, 2)
                }
            }
            .padding(12)
            .background(Theme.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet))
        }
    }
}

/// The projects nobody has touched in two hours, one line each, below the rest of the board.
///
/// A line says what the project is and how its terminals stand — the same shapes the cards use,
/// in a row — and when it was last used. Clicking it opens the full section in place for this
/// session (`wokenProjects`).
struct DormantZone: View {
    @EnvironmentObject var state: AppState
    let projects: [Project]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.outlineVariant).padding(.bottom, 4)
            ZoneHeader(title: "两小时内没动过", count: projects.count)
            ForEach(projects) { p in
                if state.wokenProjects.contains(p.id) {
                    ProjectSection(project: p, woken: true).id(p.id)
                } else {
                    DormantRow(project: p).id(p.id)
                }
            }
        }
    }
}

struct DormantRow: View {
    @EnvironmentObject var state: AppState
    let project: Project
    @State private var hovering = false

    private var terminals: [TerminalSession] { state.visible(state.terminals(inProject: project.id)) }
    private var last: Date? { terminals.compactMap(\.lastActivity).max() }
    private var tokens: Int { state.projectNewTokens(project.id) }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { _ = state.wokenProjects.insert(project.id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.onSurfaceVariant)
                Text(project.name).font(.fvTitleSmall).foregroundColor(Theme.onSurface)
                    .lineLimit(1)
                    .frame(minWidth: 140, alignment: .leading)
                // Every terminal as its status shape — the project's state at a glance, without
                // a single card. Capped so a big project does not run the row off the edge.
                HStack(spacing: 3) {
                    ForEach(terminals.prefix(24)) { t in StatusGlyph(status: t.status, size: 12) }
                    if terminals.count > 24 {
                        Text("+\(terminals.count - 24)").font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                    }
                }
                Spacer(minLength: 12)
                if tokens > 0 {
                    Text(TokenUsage.short(tokens)).font(.fvLabel).monospacedDigit()
                        .foregroundColor(Theme.onSurfaceVariant)
                        .help("\(tokens) tokens")
                }
                if let last {
                    Text(RelativeTime.compact(last)).font(.fvLabel).monospacedDigit()
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(minWidth: 28, alignment: .trailing)
                        .help("最后活动")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(hovering ? Theme.surfaceContainer : Theme.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(project.path)\n点开查看这个项目的终端")
    }
}

struct ProjectSection: View {
    @EnvironmentObject var state: AppState
    let project: Project
    /// Opened from the dormant zone: offers to fold it back into its one-line row.
    var woken: Bool = false

    // A cluster with no marked member is dropped whole rather than left as an empty frame.
    private var clusters: [Cluster] {
        state.clustersInProject(project.id).filter { !state.visible(state.members(ofCluster: $0.id)).isEmpty }
    }
    private var standalone: [TerminalSession] {
        state.visible(state.standaloneTerminals(inProject: project.id))
    }
    private var total: Int { state.terminals(inProject: project.id).count }
    private var newTokens: Int { state.projectNewTokens(project.id) }
    private var deltas: [TokenSample] { state.projectTokenDeltas(project.id) }
    private var lastTokenTime: Date? { state.projectLastTokenTime(project.id) }
    @State private var showChart = true
    @State private var copied = false
    @State private var gripHot = false
    /// A fixed point for the rate chip's 5s schedule. Held in @State so it survives the re-renders
    /// it would otherwise be reset by; the actual instant is irrelevant, only that it stops moving.
    @State private var rateEpoch = Date()
    // Scanned rather than observed: a skill is files on disk, with no event to subscribe to.
    //
    // Two levels, because they cost different amounts. `skillCount` is a directory listing and runs
    // for every project as its section appears — that is all the header needs. The SKILL.md bodies
    // are only read when the drawer is opened, which is also the moment a stale list would be
    // noticed, so the refresh and the laziness are the same act.
    @State private var skillCount = 0
    @State private var skills: [SkillInfo] = []
    @State private var showSkills = false
    @State private var pickedSkill: SkillInfo?

    private var archived: [TerminalArchive] { state.archived(inProject: project.id) }

    private var collapsed: Bool { state.isCollapsed(project.id) }
    // Counted over every terminal in the project, not the filtered list: what the header reports
    // about hidden work has to be the truth about all of it.
    private var needsYou: Int { state.terminals(inProject: project.id).filter { $0.status == .needsYou }.count }
    private var working: Int { state.terminals(inProject: project.id).filter { $0.status == .working }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The board proper starts here: a full-width rule above every project is what tells
            // these sections apart from the "进行中" and "最近使用" zones above them.
            Divider().overlay(Theme.outlineVariant).padding(.bottom, 4)
            header
            // Not gated on `collapsed`: folding a project puts its *terminals* away, and looking up
            // what a skill does is exactly the kind of thing you do without wanting the cards back.
            if showSkills { skillsPanel }
            // Folded: the header alone, which still carries the terminal count and the token
            // figures — a project you have put away should still be able to tell you it is busy.
            if !collapsed {
                if showChart && deltas.count > 1 {
                    ProjectTokenChart(samples: deltas, lastUpdated: lastTokenTime)
                }
                if total == 0 {
                    emptyRow
                } else {
                    ForEach(clusters) { c in ClusterContainer(clusterId: c.id).id(c.id) }
                    if !standalone.isEmpty {
                        LazyVGrid(columns: BoardGrid.columns,
                                  alignment: .leading, spacing: BoardGrid.spacing) {
                            ForEach(standalone) { t in TerminalCardView(terminal: t).id(t.id) }
                        }
                    }
                }
            }
        }
        // The whole section is the drop target, not just its header: while you drag a project past
        // one with six cards open, the header is the smallest part of it you could be aiming at.
        .onDrop(of: [.text], delegate: ProjectReorderDrop(target: project.id, state: state))
        // And the same area answers a dragged *card* — released here, that terminal moves into this
        // project (see ProjectFramesKey).
        .background(GeometryReader { g in
            Color.clear.preference(key: ProjectFramesKey.self,
                                   value: [project.id: [g.frame(in: .named("fleet"))]])
        })
        .onAppear { skillCount = ProjectSkills.count(projectPath: project.path) }
    }

    /// The skills drawer: names down the left, the picked one explained on the right.
    ///
    /// The absolute path is both selectable and copyable by button. Two ways to the same string
    /// because they answer different needs — dragging out part of a path to paste into a command,
    /// versus taking the whole thing without aiming.
    /// Eight rows, then scroll. A row is pinned to a fixed height rather than left to size itself:
    /// a ScrollView needs a definite height to stop at, and deriving that from a guess at the text's
    /// intrinsic size is how the ninth row ends up sliced in half along the bottom edge.
    private static let skillRowHeight: CGFloat = 24
    private static let skillRowGap: CGFloat = 1
    private static let skillsShown = 8

    private var skillsPanel: some View {
        let rows = min(skills.count, Self.skillsShown)
        let listHeight = CGFloat(rows) * Self.skillRowHeight
            + CGFloat(max(0, rows - 1)) * Self.skillRowGap
        return HStack(alignment: .top, spacing: 10) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Self.skillRowGap) {
                    ForEach(skills) { s in
                        let picked = (pickedSkill ?? skills.first)?.id == s.id
                        Button { pickedSkill = s } label: {
                            Text(s.name)
                                .font(.system(size: 12, weight: picked ? .semibold : .regular))
                                .foregroundColor(picked ? Theme.accent : Theme.text)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: Self.skillRowHeight)
                                .background(picked ? Theme.accent.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 190, height: listHeight)
            Divider()
            if let s = pickedSkill ?? skills.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
                    Text(s.description.isEmpty ? "SKILL.md declares no description." : s.description)
                        .font(.system(size: 11)).foregroundColor(Theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(s.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.subtext.opacity(0.75))
                            .textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                        Button { copyToClipboard(s.path) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                                .foregroundColor(Theme.subtext).padding(3)
                        }
                        .buttonStyle(.plain).help("Copy the absolute path")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .background(Theme.card.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
    }

    /// When anything last happened in this project.
    private var lastActivity: Date? {
        state.terminals(inProject: project.id).compactMap(\.lastActivity).max()
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant.opacity(gripHot ? 1 : 0.35))
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
                    .onHover { gripHot = $0 }
                    .help("拖动调整项目顺序")
                    .onDrag {
                        // AppKit calls this on the main thread; the closure is simply not typed for it.
                        MainActor.assumeIsolated { state.draggingProjectId = project.id }
                        return NSItemProvider(object: project.id.uuidString as NSString)
                    }
                // Same chevron idiom as the sidebar's section headers, pointing at the same thing.
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { state.toggleProjectCollapsed(project.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "展开这个项目" : "折叠这个项目")
            }
            // lineLimit(1): a name that wraps changes the header's height, and the figures next to
            // it re-measure every few seconds.
            Text(project.name).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                .lineLimit(1)
                .onTapGesture(count: 2) { state.openInFinder(project.id) }
                .onTapGesture { copyToClipboard(project.name) }
                .help("\(project.path)\n单击复制名称 · 双击在 Finder 中打开")
            // Folded, the cards can no longer speak for themselves, and a terminal waiting on an
            // answer behind a closed section is the one thing folding could genuinely cost you.
            // The header shows it — as the same shapes the cards use, not as words.
            if collapsed {
                if needsYou > 0 { glyphCount(.needsYou, needsYou) }
                if working > 0 { glyphCount(.working, working) }
            }
            // Figures pinned to one line at their intrinsic width: squeezed, they took a second line,
            // the header grew, and every card below moved — once every five seconds.
            HStack(spacing: 14) {
                meta("rectangle.on.rectangle", "\(total)", help: "\(total) 个终端")
                if newTokens > 0 {
                    meta("sum", TokenUsage.short(newTokens),
                         help: "\(newTokens) tokens（输入 + 输出，不含缓存读取）")
                    // Anchored on a date this view keeps, never on `.now` — `.now` is re-evaluated
                    // on every body pass, which handed the timeline a new schedule each render.
                    TimelineView(.periodic(from: rateEpoch, by: 5)) { context in
                        let recent = state.projectTokensRecent(project.id, now: context.date)
                        if recent > 0 {
                            meta("chart.line.uptrend.xyaxis", "\(TokenUsage.short(recent))/m",
                                 tint: Theme.primary, help: "最近一分钟新增的 tokens")
                        }
                    }
                }
                if let lastActivity {
                    TimelineView(.periodic(from: lastActivity, by: 30)) { ctx in
                        Text(RelativeTime.compact(lastActivity, now: ctx.date))
                            .font(.fvLabel).monospacedDigit()
                            .foregroundColor(Theme.onSurfaceVariant)
                            .help("最后活动")
                    }
                }
            }
            .lineLimit(1).fixedSize()
            if copied {
                Text("已复制").font(.fvLabelSmall)
                    .foregroundColor(Theme.onPrimary).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.primary).clipShape(Capsule()).transition(.opacity)
            }
            Spacer(minLength: 10)
            // Standard icon buttons: no container on any of them (a row's controls either all have
            // one or none do). Hidden when there is nothing behind them.
            HStack(spacing: 2) {
                if skillCount > 0 {
                    iconButton("wand.and.stars", count: skillCount, on: showSkills,
                               help: showSkills ? "收起技能" : ".claude/skills 里有 \(skillCount) 个技能") {
                        withAnimation(.easeOut(duration: 0.18)) { showSkills.toggle() }
                        if showSkills {
                            skills = ProjectSkills.scan(projectPath: project.path)
                            skillCount = skills.count
                        }
                    }
                }
                if !archived.isEmpty {
                    iconButton("archivebox", count: archived.count,
                               help: "\(archived.count) 个已移除的终端：在搜索里打开，拖回看板即可恢复") {
                        state.openArchive(projectId: project.id)
                    }
                }
                if deltas.count > 1 {
                    iconButton("chart.bar.xaxis", on: showChart,
                               help: showChart ? "隐藏 token 图表" : "显示 token 图表") {
                        withAnimation(.easeOut(duration: 0.18)) { showChart.toggle() }
                    }
                }
                if woken {
                    iconButton("arrow.down.right.and.arrow.up.left", help: "收回成一行") {
                        withAnimation(.easeOut(duration: 0.18)) { _ = state.wokenProjects.remove(project.id) }
                    }
                }
                iconButton("folder", help: "在 Finder 中显示") { state.openInFinder(project.id) }
                iconButton("plus", help: "新终端") { state.requestNewTerminal(projectId: project.id) }
                Menu {
                    Button("在 Finder 中显示") { state.openInFinder(project.id) }
                    Button("复制路径") { copyToClipboard(project.path) }
                    Divider()
                    Button("从 FleetView 移除项目", role: .destructive) { state.removeProject(project.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("更多")
            }
        }
        .frame(height: 40)
    }

    private func glyphCount(_ status: TermStatus, _ n: Int) -> some View {
        HStack(spacing: 4) {
            StatusGlyph(status: status, size: 14)
            Text("\(n)").font(.fvLabel).monospacedDigit().foregroundColor(Theme.statusColor(status))
        }
        .help("\(n) 个\(status.label)")
    }

    private func meta(_ symbol: String, _ text: String, tint: Color = Theme.onSurfaceVariant,
                      help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(text).font(.fvLabel).monospacedDigit()
        }
        .foregroundColor(tint)
        .help(help)
    }

    private func iconButton(_ symbol: String, count: Int? = nil, on: Bool = false, help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 14))
                if let count { Text("\(count)").font(.fvLabel).monospacedDigit() }
            }
            .foregroundColor(on ? Theme.onSecondaryContainer : Theme.onSurfaceVariant)
            .padding(.horizontal, count == nil ? 0 : 10)
            .frame(minWidth: Theme.controlHeight, minHeight: Theme.controlHeight)
            .background(on ? Theme.secondaryContainer : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(help)
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }

    private var emptyRow: some View {
        Button { state.requestNewTerminal(projectId: project.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 14))
                Text("新终端").font(.fvLabel)
            }
            .foregroundColor(Theme.onSurfaceVariant)
            .padding(.horizontal, 16).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundColor(Theme.outlineVariant))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Drag-to-reorder for the board's project sections.
///
/// The move happens on `dropEntered` — the board rearranges live under the cursor — rather than on
/// release. A section is as tall as the terminals it holds, so an insertion line drawn at its edge
/// would frequently be scrolled out of view; seeing the sections themselves swap is the feedback.
///
/// SwiftUI hands these callbacks to a plain (nonisolated) struct even though it only ever calls
/// them on the main thread, hence `assumeIsolated` rather than a hop, which would reorder after
/// the drag has already moved on.
struct ProjectReorderDrop: DropDelegate {
    let target: UUID
    let state: AppState

    /// Only our own drags reorder: without the id check, any text dragged in from another app
    /// would shuffle the board.
    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { state.draggingProjectId != nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragged = state.draggingProjectId else { return }
            withAnimation(.easeInOut(duration: 0.18)) { state.moveProject(dragged, onto: target) }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { state.draggingProjectId = nil }
        return true      // the order was already committed (and saved) on the way in
    }
}

// MARK: - Cluster container (a task served by multiple terminals)

struct ClusterContainer: View {
    @EnvironmentObject var state: AppState
    let clusterId: UUID

    private var name: String { state.cluster(clusterId)?.name ?? "" }
    private var allMembers: [TerminalSession] { state.members(ofCluster: clusterId) }
    private var members: [TerminalSession] { state.visible(allMembers) }
    private var highlighted: Bool { state.highlightedClusterId == clusterId }

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                Text(name)
                    .font(.fvTitleSmall).foregroundColor(Theme.onSurface).lineLimit(1)
                    .onTapGesture(count: 2) { state.requestRenameCluster(clusterId) }
                    .help("双击重命名")
                // The cluster's real size, with what the filter is showing of it — the header must
                // not claim a two-terminal task when the task has six.
                Text(members.count == allMembers.count ? "\(allMembers.count)"
                                                       : "\(members.count) / \(allMembers.count)")
                    .font(.fvTitleSmall).monospacedDigit().foregroundColor(Theme.onSurfaceVariant)
                    .help(members.count == allMembers.count ? "\(allMembers.count) 个终端"
                                                            : "显示了 \(allMembers.count) 个里的 \(members.count) 个")
                Spacer()
                HStack(spacing: 2) {
                    clusterButton("pencil", help: "重命名这个组") { state.requestRenameCluster(clusterId) }
                    clusterButton("plus", help: "给这个任务再加一个 agent") { state.addToCluster(clusterId) }
                }
                .opacity(hovering ? 1 : 0)
            }
            .frame(height: 28)

            LazyVGrid(columns: BoardGrid.columns,
                      alignment: .leading, spacing: BoardGrid.spacing) {
                ForEach(members) { t in TerminalCardView(terminal: t) }
            }
        }
        .padding(12)
        // An outline and nothing else: the group is a frame around cards, not a coloured block.
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet)
            .strokeBorder(highlighted ? Theme.primary : Theme.outlineVariant, lineWidth: highlighted ? 2 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The whole box is a drop target for a dragged card — the task is the thing you are aiming
        // at, not whichever member card happens to be under the cursor.
        .background(GeometryReader { g in
            Color.clear.preference(key: ClusterFramesKey.self,
                                   value: [clusterId: [g.frame(in: .named("fleet"))]])
        })
    }

    private func clusterButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 42, weight: .light)).foregroundColor(Theme.subtext.opacity(0.7))
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.text)
            Text(subtitle).font(.system(size: 13)).foregroundColor(Theme.subtext)
            Button(action: action) {
                Text(button).font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundColor(Theme.onAccent)
            .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

// MARK: - Session-tree drag plumbing

/// The fleet board's frame in the "fleet" space — the standalone drop target for tree nodes.
struct BoardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

/// Every terminal card's frame — same-project cards double as drop targets, both for a tree node
/// and for another card being dragged onto them.
///
/// A *list* of frames per terminal, because one terminal can be on screen twice: a running card is
/// drawn in the RUNNING NOW strip and again in its own project section. Keyed to a single rect the
/// two overwrote each other, so whichever the reduce saw last was the only one you could drop on —
/// and the strip, being the first thing at the top of the board, was the one that lost.
struct CardFramesKey: PreferenceKey {
    static var defaultValue: [UUID: [CGRect]] = [:]
    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

/// Every cluster container's frame. A dragged card landing anywhere inside one joins that task, so
/// the box — not its member cards — is what lights up and what the drop resolves against.
struct ClusterFramesKey: PreferenceKey {
    static var defaultValue: [UUID: [CGRect]] = [:]
    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

/// Every project section's frame. A card released anywhere inside one that is not its own moves
/// into that project (see `moveTerminal(_:toProject:)`). A list per project for the same reason
/// cards keep one — the reduce merges rather than overwrites, so a section drawn twice is still
/// two targets rather than whichever one the traversal happened to see last.
struct ProjectFramesKey: PreferenceKey {
    static var defaultValue: [UUID: [CGRect]] = [:]
    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

/// The right edge turns into a drop target while a card is dragged — release there to open that
/// terminal's session tree, on the side the panel itself comes from.
struct SessionTreeDropEdge: View {
    let hot: Bool
    let frame: CGRect

    var body: some View {
        if frame != .zero {
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(hot ? .white : Theme.accent)
                Text("会话树")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(hot ? .white : Theme.accent.opacity(0.9))
            }
            .frame(width: frame.width, height: frame.height)
            .background(
                LinearGradient(colors: [Theme.accent.opacity(hot ? 0.42 : 0.13), .clear],
                               startPoint: .trailing, endPoint: .leading)
            )
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.accent.opacity(hot ? 1 : 0.5)).frame(width: hot ? 3 : 1.5)
            }
            .position(x: frame.midX, y: frame.midY)
            .animation(.easeOut(duration: 0.12), value: hot)
        }
    }
}

/// The chip that follows the cursor while dragging a tree node. Its second line is the whole
/// hint system: it names what releasing HERE will do, and says nothing when there's no target.
struct TreeDragChip: View {
    enum Action { case none, newTerminal, joinCluster
        var label: String? {
            switch self {
            case .none:        return nil
            case .newTerminal: return "松开：以此节点开新终端"
            case .joinCluster: return "松开：开新终端并加入该 cluster"
            }
        }
    }
    let prompt: String
    let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.accent)
                Text(prompt.replacingOccurrences(of: "\n", with: " ").prefix(24))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.text)
                    .lineLimit(1)
            }
            if let label = action.label {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(action.label == nil ? Theme.stroke : Theme.accent, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        .animation(.easeOut(duration: 0.1), value: action.label)
    }
}

/// One background job: what it is, how far along, and the way out of it.
private struct JobRowView: View {
    let job: BackgroundJobs.Job
    @ObservedObject private var jobs = BackgroundJobs.shared

    private var broken: Bool { job.failure != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: broken ? "exclamationmark.triangle.fill"
                                         : (job.done ? "checkmark.circle.fill" : job.kind.icon))
                    .font(.system(size: 10))
                    .foregroundColor(broken ? Theme.red : (job.done ? Theme.green : Theme.accent))
                Text(job.title).font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if !broken, let fraction = job.fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundColor(Theme.subtext)
                }
                // ✕ means two things here and both are wanted: stop the work while it runs, clear
                // the row once it has failed — a failed row is the only one that outlives its job.
                if job.cancel != nil || broken {
                    Button {
                        if job.cancel != nil { jobs.cancel(job.id) } else { jobs.dismiss(job.id) }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.subtext)
                    }
                    .buttonStyle(.plain)
                    .help(job.cancel != nil ? "取消" : "清除")
                }
            }
            if !broken {
                if let fraction = job.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
            // The detail line is git's own output while it runs and the failure once it stops, so
            // it is selectable either way: the useful half of a clone failure is a URL or a repo
            // name someone is about to paste somewhere else.
            Text(job.failure ?? job.detail)
                .font(.system(size: 10, design: broken ? .monospaced : .default))
                .foregroundColor(broken ? Theme.red : Theme.subtext.opacity(0.85))
                .lineLimit(broken ? 6 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: broken)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let label = job.recoverLabel, let recover = job.recover {
                Button { recover() } label: {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// A determinate ring for the top-bar pill. `ProgressView(value:)` draws a full-width bar on macOS,
/// which is the wrong shape for something 11 points tall inside a capsule.
private struct JobRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.onAccent.opacity(0.3), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.03, fraction))
                .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .frame(width: 11, height: 11)
    }
}
