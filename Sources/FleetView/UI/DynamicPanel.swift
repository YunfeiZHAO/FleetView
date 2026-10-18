import SwiftUI
import WebKit

/// The region at the top of FleetView's content column (to the right of the sidebar) that renders
/// the agent-authored dynamic panel
/// (`~/.fleetview/ui/panel.html`, served at `/panel`). Shown only when a panel file exists; polls its
/// mtime and reloads the web view when the agent rewrites it. Collapsible. Read-only (v1).
struct DynamicPanel: View {
    @EnvironmentObject var state: AppState
    @State private var collapsed = false
    /// A version pinned from the history menu; `nil` means "follow the newest".
    @State private var pinned: PanelVersions.Summary?
    @State private var history: [PanelVersions.Summary] = []

    var body: some View {
        // `panelExists` / `panelVersion` are published by AppState's file watcher, so the panel shows
        // up (and reloads) the moment an agent writes the file — this view owns no timer of its own.
        Group {
            if state.panelExists, state.web.port > 0, let url = panelURL {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 13))
                            .foregroundColor(Theme.onSurfaceVariant)
                        Text(pinned.map { "面板 · \($0.label)" } ?? "面板").font(.fvLabel)
                            .foregroundColor(Theme.onSurface).lineLimit(1)
                        Spacer()
                        historyMenu
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                                .rotationEffect(.degrees(collapsed ? -90 : 0))
                                .foregroundColor(Theme.onSurfaceVariant)
                                .frame(width: 28, height: 28).contentShape(Circle())
                        }
                        .buttonStyle(.plain).help(collapsed ? "展开面板" : "收起面板")
                    }
                    .padding(.leading, 16).padding(.trailing, 6)
                    .frame(height: Theme.controlHeight)
                    .background(Theme.surfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .padding(.horizontal, 20).padding(.top, 4)
                    if !collapsed {
                        // Keyed on the version uuid, not on mtime: touching the file no longer
                        // reflows the panel for nothing.
                        WebPanelView(url: url, reloadToken: pinned?.uuid ?? state.panelVersion)
                            .frame(height: 240)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// Every version an agent ever wrote is kept, so the menu is a real history, not a cache.
    private var historyMenu: some View {
        Menu {
            Button("实时（最新版本）") { pinned = nil }
            if !history.isEmpty { Divider() }
            ForEach(history) { version in
                Button(version.label) { pinned = version }
            }
        } label: {
            Image(systemName: "clock").font(.system(size: 13))
                .foregroundColor(pinned == nil ? Theme.onSurfaceVariant : Theme.primary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("面板的历史版本")
        .onAppear { history = PanelVersions.shared.recentSummaries() }
        .onChange(of: state.panelVersion) { _ in history = PanelVersions.shared.recentSummaries() }
    }

    private var panelURL: URL? {
        var path = "http://127.0.0.1:\(state.web.port)/panel"
        if let pinned { path += "?v=\(pinned.uuid)" }
        return URL(string: path)
    }
}

/// A WKWebView that (re)loads `url` whenever `reloadToken` changes (the archived version's uuid).
private struct WebPanelView: NSViewRepresentable {
    let url: URL
    let reloadToken: String

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.setValue(false, forKey: "drawsBackground")   // transparent to the panel's own background
        context.coordinator.load(wv, url, reloadToken)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.load(wv, url, reloadToken)   // no-op unless the token changed
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var lastToken: String?
        func load(_ wv: WKWebView, _ url: URL, _ token: String) {
            guard token != lastToken else { return }
            lastToken = token
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = comps?.queryItems ?? []
            items.append(URLQueryItem(name: "t", value: token.isEmpty ? "0" : token))   // cache-bust
            comps?.queryItems = items
            wv.load(URLRequest(url: comps?.url ?? url))
        }
    }
}
