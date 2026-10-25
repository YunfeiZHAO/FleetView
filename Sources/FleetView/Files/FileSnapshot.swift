import AppKit
import SwiftUI
import WebKit

/// `FV_SNAPSHOT_FILES=<folder> FleetView --snapshot <dir>`: draw a file window on that folder to PNGs.
///
/// The board's snapshot mode, for the file window: the real views and the real editor page, in an
/// offscreen window, with no hooks, no web server and nothing written to `~/.fleetview` (the same
/// `CFFIXED_USER_HOME` guard applies). The editor is a web view, which `cacheDisplay` cannot see, so
/// its own snapshot is drawn into the picture where it sits.
///
/// `FV_SNAPSHOT_OPEN`: files to open, comma-separated, relative to the folder (the last is shown).
/// `FV_SNAPSHOT_EXPAND`: folders to open in the tree. `FV_SNAPSHOT_JS`: script run in the page after
/// the files are open — how a test types into the editor.
@MainActor
enum FileSnapshot {
    static func run(root: String, into dir: String) -> Never {
        let env = ProcessInfo.processInfo.environment
        let open = (env["FV_SNAPSHOT_OPEN"] ?? "").split(separator: ",").map(String.init)
        let expand = (env["FV_SNAPSHOT_EXPAND"] ?? "").split(separator: ",").map(String.init)
        let script = env["FV_SNAPSHOT_JS"]
        let state = AppState()
        let project = Project(name: (root as NSString).lastPathComponent, path: root, isGit: true)
        state.projects = [project]
        for (suffix, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: name)
            shoot(project, state: state, open: open, expand: expand, script: script, appearance: name,
                  to: "\(dir)/files-\(suffix).png")
        }
        exit(0)
    }

    private static func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func shoot(_ project: Project, state: AppState, open: [String], expand: [String], script: String?,
                              appearance: NSAppearance.Name, to path: String) {
        let size = NSSize(width: 1280, height: 800)
        let model = FileBrowserModel(project: project, app: state)
        let host = NSHostingView(rootView: FileBrowserView(model: model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        model.window = window
        model.start()
        spin(8) { model.editor.ready && !model.rows.isEmpty }
        for d in expand { model.toggle(d); spin(0.4) }
        for f in open { model.open(f, pin: true); spin(1.2) }
        if let script {
            var finished = false
            model.editor.webView.evaluateJavaScript(script) { _, _ in finished = true }
            spin(5) { finished }
        }
        spin(2.5)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let web = model.editor.webView
        var shot: NSImage?
        var done = false
        web.takeSnapshot(with: nil) { image, _ in shot = image; done = true }
        spin(5) { done }
        if let shot, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let r = web.convert(web.bounds, to: host)
            let y = host.isFlipped ? host.bounds.height - r.maxY : r.minY
            shot.draw(in: NSRect(x: r.minX, y: y, width: r.width, height: r.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        // What the page reported, for a test to read: the tabs and their state.
        let tabs = model.tabs.map { "\($0.path) dirty=\($0.dirty) mode=\($0.mode.rawValue) ro=\($0.readOnly ?? "-")" }
        print("files snapshot \(path): rows=\(model.rows.count) marks=\(model.marks.count) repo=\(model.repo != nil) tabs=\(tabs) banners=\(model.banners) status=\(model.status)")
        model.stop()
        window.contentView = nil
    }
}
