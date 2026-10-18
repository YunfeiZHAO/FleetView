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

    @MainActor private static func shoot<V: View>(_ view: V, size: NSSize,
                                                  appearance: NSAppearance.Name, to path: String) {
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

    /// A board with one of everything: needs-you, running, idle, shell, exited, closed, a cluster,
    /// a marked card, a hidden window, notes.
    @MainActor private static func fill(_ s: AppState) {
        let now = Date()
        let fv = Project(name: "FleetView", path: "/tmp/FleetView", isGit: true)
        let cs = Project(name: "code_sense", path: "/tmp/code_sense", isGit: true)
        let home = Project(name: "home_puzhen", path: "/tmp/home_puzhen", isGit: true)
        let tmp = Project(name: "临时", path: "/tmp/临时", isGit: false)
        s.projects = [fv, cs, home, tmp]

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
        var fv1 = t(fv, "FleetView-1", .idle, .claude, ago: 1500, prompt: "部署 push", tokens: 412_000)
        fv1.subtaskDone = true
        let cluster = Cluster(name: "home_puzhen-1")
        var h1 = t(home, "home_puzhen-1", .idle, .claude, ago: 345_600,
                   prompt: "把 Mac mini 上 qc150 的结果拉回来，按领域汇总分数", tokens: 9_300_000)
        h1.clusterId = cluster.id
        var h2 = t(home, "home_puzhen-1 ⑂", .idle, .claude, ago: 432_000,
                   prompt: "同一任务的第二种做法：只重跑低于 7 分的题", tokens: 3_700_000)
        h2.clusterId = cluster.id
        s.clusters = [cluster]
        s.terminals = [
            t(fv, "FleetView-3", .needsYou, .codex, ago: 60, prompt: "允许运行 swift build？需要写入 .build/ 目录",
              tokens: 230_000),
            t(fv, "FleetView-2", .working, .claude, ago: 5,
              prompt: "现在帮我看看 fleetview 的配色，设计，以及标签名称，很多地方都不规范，不好看，帮我研究一下看看",
              tokens: 64_000, running: 132),
            fv1,
            t(fv, "web-check", .exited, .claude, ago: 7200, prompt: "把 Web 面板的断线重连改成指数退避", tokens: 38_000),
            t(fv, "release-notes", .closed, .claude, ago: 259_200, prompt: "整理 0.9 版本的更新说明", tokens: 12_000),
            t(cs, "CS104 astra r1", .working, .codex, ago: 2,
              prompt: "跑完第一轮 astra 评测，把失败用例按模块归类，写到 report.md", tokens: 1_200_000, running: 847),
            t(cs, "code_sense-1", .idle, .claude, ago: 60,
              prompt: "Monitor 事件：continuous fleet tracking 已就绪，下一步对比两轮结果", tokens: 3_100_000),
            t(cs, "code_sense-4", .shell, .unknown, ago: 3600, prompt: "tail -f logs/relay.log"),
            h1, h2,
            t(home, "手表app", .idle, .claude, ago: 518_400, prompt: "我发现最近两套的轨迹，gps经常不准确，看看",
              tokens: 3_900_000),
            t(tmp, "probe4", .shell, .unknown, ago: 18_000,
              prompt: "ipconfig getifaddr en0; nmap -p 22,8080 192.168.2.0/24"),
            t(tmp, "hawait", .closed, .unknown, ago: 18_000, prompt: "for i in 1 2 3 4 5; do curl -s localhost:8123; done"),
        ]
        s.notes = [Note(text: "claude --dangerously-skip-permissions"),
                   Note(text: "claude --dangerously-skip-permissions --resume"),
                   Note(text: ".claude/skills/experiential-demo-to-fwdg-task/SKILL.md"),
                   Note(text: "~/PycharmProjects/datagen_vision2web/template_generation/docs")]
        s.showRecentStrip = true
    }
}
