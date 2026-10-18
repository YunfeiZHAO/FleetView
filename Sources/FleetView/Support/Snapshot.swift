import AppKit
import SwiftUI

/// `FleetView --snapshot <dir>`: draw the board with sample data to PNGs and exit.
///
/// The app cannot be launched to look at a UI change — a second instance steals the running one's
/// hook events (see CLAUDE.md) — and a redesign is nothing but UI changes. This draws the real views
/// in an offscreen window instead: no AppDelegate, no hooks, no web server, no tmux, nothing read
/// from or written to the user's state.
///
/// It refuses to run unless `CFFIXED_USER_HOME` points somewhere other than the real home, which is
/// what Foundation (and so `FV.home`) resolves the home directory from. Anything a view might touch
/// on disk then lands in that scratch home, never in `~/.fleetview`.
enum Snapshot {
    static var outputDir: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor static func run(into dir: String) -> Never {
        guard let fake = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              !fake.isEmpty, fake != NSHomeDirectoryForUser(NSUserName()) else {
            FileHandle.standardError.write(Data(
                "--snapshot needs CFFIXED_USER_HOME set to a scratch directory, so nothing touches ~/.fleetview\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let state = AppState()
        fill(state)
        let size = NSSize(width: 1512, height: 949)
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            state.dialog = nil
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/board-\(suffix).png")
            // The whole board, scrolled or not: what sits below the first screen matters too.
            shoot(DashboardView().environmentObject(state), size: NSSize(width: size.width, height: 2000),
                  appearance: appearance, to: "\(dir)/board-tall-\(suffix).png")
            state.dialog = .webLink(terminalId: state.terminals.first { $0.status == .working }?.id)
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/dialog-web-\(suffix).png")
            state.dialog = .closeAll
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/dialog-close-\(suffix).png")
            // Mid-drag: FleetView-1 lifted over the web-store-1 card's neighbourhood, the dock up.
            if let dragged = state.terminals.first(where: { $0.name == "FleetView-1" }),
               let target = state.terminals.first(where: { $0.name == "web-store-1" }) {
                state.dialog = nil
                state.draggingTerminalId = dragged.id
                state.dragLocation = CGPoint(x: 900, y: 560)
                state.clusterDrop = .project(target.projectId)
                shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                      to: "\(dir)/drag-\(suffix).png")
                state.draggingTerminalId = nil
                state.clusterDrop = nil
            }
            // The session tree, when a real transcript is named (read only): FV_SNAPSHOT_TRANSCRIPT.
            if let path = ProcessInfo.processInfo.environment["FV_SNAPSHOT_TRANSCRIPT"],
               let i = state.terminals.firstIndex(where: { $0.name == treeTerminal }) {
                state.dialog = nil
                state.terminals[i].transcriptPath = path
                state.openSessionTree(state.terminals[i].id)
                let deadline = Date().addingTimeInterval(15)
                while (state.treeModel.loading || state.treeModel.rows.isEmpty), Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                      to: "\(dir)/tree-\(suffix).png")
                // A pinned turn: the one before the current leaf, so there are rows on both sides of
                // it; the root when the path is a single turn.
                let tree = state.treeModel.tree
                let leaf = tree.activeLeafNode ?? state.treeModel.rows.compactMap(\.nodeUuid).first
                if let leaf, case let u = tree.nodes[leaf]?.parent ?? leaf,
                   !(tree.nodes[u]?.answer.isEmpty ?? true) {
                    state.treeModel.selected = u
                    state.treeModel.focus.focusY = 420
                    shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                          to: "\(dir)/tree-pinned-\(suffix).png")
                    state.treeModel.selected = nil
                }
                state.closeSessionTree()
            }
            state.dialog = nil
            state.searchModel.app = state
            state.searchOpen = true
            state.searchModel.query = "FleetView"
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/search-\(suffix).png")
            state.searchOpen = false
            state.searchModel.reset()
        }
        exit(0)
    }

    /// Re-dates the sample's fresh changes before every shot: they are fresh for ten seconds, and a
    /// full run of shots takes longer than that.
    @MainActor private static var freshen: () -> Void = {}

    @MainActor private static func shoot<V: View>(_ view: V, size: NSSize,
                                                  appearance: NSAppearance.Name, to path: String) {
        freshen()
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        // Let SwiftUI lay out and settle (preferences, GeometryReaders) before drawing.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    /// The terminal the session tree is drawn for when `FV_SNAPSHOT_TRANSCRIPT` names a transcript.
    private static let treeTerminal = "ride-tracker"

    /// A board with one of everything: needs-you, running, idle, shell, exited, closed, a cluster,
    /// a marked card, dormant projects, notes.
    ///
    /// Also what the README's screenshots are drawn from, so it is invented, worded in the language
    /// the UI is drawn in, and names nothing on this machine: run it with `-AppleLanguages "(en)"`
    /// or `"(zh-Hans)"` for each README.
    @MainActor private static func fill(_ s: AppState) {
        let now = Date()
        func w(_ en: String, _ zh: String) -> String { Lang.current == .zh ? zh : en }
        let fv = Project(name: "FleetView", path: "/Users/me/dev/FleetView", isGit: true)
        let shop = Project(name: "web-store", path: "/Users/me/dev/web-store", isGit: true)
        let data = Project(name: "data-pipeline", path: "/Users/me/dev/data-pipeline", isGit: true)
        let rides = Project(name: "ride-tracker", path: "/Users/me/dev/ride-tracker", isGit: true)
        let tmp = Project(name: "scratch", path: "/Users/me/scratch", isGit: false)
        s.projects = [fv, shop, data, rides, tmp]

        func t(_ p: Project, _ name: String, _ status: TermStatus, _ agent: AgentKind, ago: Double,
               prompt: String, tokens: Int = 0, running: Double? = nil) -> TerminalSession {
            var x = TerminalSession(projectId: p.id, name: name, cwd: p.path)
            x.status = status
            x.agentKind = agent
            x.lastPrompt = prompt
            x.newTokens = tokens
            x.lastActivity = now.addingTimeInterval(-ago)
            if let running { x.runningSince = now.addingTimeInterval(-running) }
            return x
        }
        var fv1 = t(fv, "FleetView-1", .idle, .claude, ago: 1500, prompt: w("Deploy and push", "部署并 push"),
                    tokens: 412_000)
        fv1.subtaskDone = true
        let cluster = Cluster(name: "backfill")
        var d1 = t(data, "backfill-a", .idle, .claude, ago: 345_600,
                   prompt: w("Backfill September's events into the warehouse, one partition per day",
                             "把九月的事件回填到数仓，按天分区"), tokens: 9_300_000)
        d1.clusterId = cluster.id
        var d2 = t(data, "backfill-b", .idle, .codex, ago: 432_000,
                   prompt: w("Same task, another way: re-run only the days that failed",
                             "同一个任务换个做法：只重跑失败的那几天"), tokens: 3_700_000)
        d2.clusterId = cluster.id
        s.clusters = [cluster]
        s.terminals = [
            t(fv, "FleetView-3", .needsYou, .codex, ago: 60,
              prompt: w("Allow swift build? It needs to write to .build/", "允许运行 swift build？需要写入 .build/ 目录"),
              tokens: 230_000),
            t(fv, "FleetView-2", .working, .claude, ago: 5,
              prompt: w("Rework the colours and labels so a card's state reads from its shape and colour alone",
                        "重新设计配色和标签，让卡片的状态只看形状和颜色就能分辨"),
              tokens: 64_000, running: 132),
            fv1,
            t(fv, "web-check", .exited, .claude, ago: 7200,
              prompt: w("Make the web panel reconnect with exponential backoff", "把 Web 面板的断线重连改成指数退避"),
              tokens: 38_000),
            t(fv, "release-notes", .closed, .claude, ago: 259_200,
              prompt: w("Draft the 0.9 release notes", "整理 0.9 版本的更新说明"), tokens: 12_000),
            t(shop, "checkout-e2e", .working, .codex, ago: 2,
              prompt: w("Run the checkout e2e suite and group the failures by module in report.md",
                        "跑完结账流程的端到端测试，把失败用例按模块归类，写到 report.md"),
              tokens: 1_200_000, running: 847),
            t(shop, "web-store-1", .working, .claude, ago: 1,
              prompt: w("Add a loading skeleton to the product grid", "给商品网格加一个加载骨架屏"),
              tokens: 3_100_000, running: 2),
            t(shop, "dev-server", .shell, .unknown, ago: 3600, prompt: "npm run dev"),
            d1, d2,
            t(rides, treeTerminal, .idle, .claude, ago: 518_400,
              prompt: w("The GPS tracks from my last two rides keep drifting — take a look",
                        "最近两次骑行的 GPS 轨迹总是漂，帮我看看"),
              tokens: 3_900_000),
            t(tmp, "probe", .shell, .unknown, ago: 18_000,
              prompt: "curl -s localhost:8080/state | jq '.terminals | length'"),
            t(tmp, "load-test", .closed, .unknown, ago: 18_000,
              prompt: "for i in $(seq 50); do curl -s localhost:8123/health; done"),
        ]
        // One run that has just started (web-store-1) and one that has just finished (FleetView-1),
        // so both fresh colours are in every shot.
        freshen = { [weak s] in
            guard let s else { return }
            if let i = s.terminals.firstIndex(where: { $0.name == "web-store-1" }) {
                s.terminals[i].runningSince = Date().addingTimeInterval(-2)
            }
            if let fv1 = s.terminals.first(where: { $0.name == "FleetView-1" }) {
                s.runEndedAt[fv1.id] = Date().addingTimeInterval(-2)
            }
        }
        s.notes = [Note(text: "claude --dangerously-skip-permissions"),
                   Note(text: "claude --resume"),
                   Note(text: "~/dev/FleetView/docs/design"),
                   Note(text: "ssh mini.local 'tmux -L fleetview ls'")]
        s.showRecentStrip = true
    }
}
