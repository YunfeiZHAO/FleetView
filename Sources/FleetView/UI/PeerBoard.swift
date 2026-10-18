import SwiftUI
import WebKit

/// A peer's own web dashboard, embedded.
///
/// Nothing here re-implements the remote board: that page already exists, is served by the machine
/// it belongs to, and is the same UI a phone gets — cards, terminal view, the prompt bar, and the
/// Notes list as quick-command chips. Mirroring `/state` into native cards instead would mean a
/// second renderer to keep in step with this one, for a view you look at rather than work in.
struct PeerWebBoard: NSViewRepresentable {
    let peer: Peer

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: String?
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Each peer gets the shared store, so a session cookie set by one machine's dashboard
        // survives switching away and back.
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")   // let Theme.bg show through while loading
        load(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        load(view, context.coordinator)
    }

    /// Keyed on the peer, not on `view.url`: once the page navigates internally (opening a terminal
    /// pushes its own URL) `view.url` no longer equals what we asked for, and comparing the two
    /// would reload the dashboard out from under whatever you had opened.
    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        let target = peer.url + "/"
        guard coordinator.loaded != target, let url = URL(string: target) else { return }
        coordinator.loaded = target
        view.load(URLRequest(url: url))
    }
}

/// The selected peer's terminals, in the sidebar's TASKS slot.
///
/// Grouped by project and read-only. The rows do not open anything: a terminal on another machine
/// is reached through that machine's board, which is already filling the content column beside
/// this list — a second, subtly different way in would only be a way to be surprised.
struct PeerTaskList: View {
    @EnvironmentObject var state: AppState
    let peer: Peer

    /// Project name → its terminals, in the order the peer reported them.
    private var groups: [(name: String, terms: [PeerTerminal])] {
        var order: [String] = []
        var byProject: [String: [PeerTerminal]] = [:]
        for t in state.peerTerminals {
            let key = t.project.isEmpty ? "—" : t.project
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(t)
        }
        return order.map { ($0, byProject[$0] ?? []) }
    }

    var body: some View {
        if state.peerTerminals.isEmpty {
            Text(state.peerNotesLoading ? "Reading \(peer.label)…"
                                        : "No terminals on \(peer.label)")
                .font(.system(size: 12)).foregroundColor(Theme.subtext.opacity(0.55))
                .padding(.horizontal, 16).padding(.top, 6)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(groups.enumerated()), id: \.element.name) { idx, g in
                        if idx > 0 { DashedLine().padding(.horizontal, 12).padding(.vertical, 7) }
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill").font(.system(size: 8))
                                .foregroundColor(Theme.subtext.opacity(0.55))
                            Text(g.name.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Theme.subtext.opacity(0.6)).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.bottom, 3)
                        ForEach(g.terms) { t in row(t) }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 2)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ t: PeerTerminal) -> some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.statusColor(TermStatus(rawValue: t.status) ?? .closed))
                .frame(width: 7, height: 7)
            Text(t.name.isEmpty ? String(t.id.prefix(8)) : t.name)
                .font(.system(size: 12.5)).foregroundColor(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(TermStatus(rawValue: t.status)?.label ?? t.status)
                .font(.system(size: 10))
                .foregroundColor(Theme.statusColor(TermStatus(rawValue: t.status) ?? .closed))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// The switcher under the top bar: this machine, then every FleetView found on the LAN.
struct PeerStrip: View {
    @EnvironmentObject var state: AppState
    /// Observed explicitly: discovery publishes from its own object, and a view watching only
    /// AppState would sit on an empty list while the scan filled it in.
    @ObservedObject var fleet: PeerFleet

    private var others: [Peer] { fleet.found.filter { !$0.isSelf } }

    /// Two FleetViews run by the same account would both be called by that account's name, and a
    /// tab you cannot tell apart from its neighbour is one you will click by mistake. Then the host
    /// is added, which is the thing that actually differs.
    private func title(_ p: Peer) -> String {
        others.filter { $0.label == p.label }.count > 1 ? "\(p.label) · \(p.host)" : p.label
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                tab(title: "本机", detail: nil, active: state.peerSelected == nil) {
                    state.selectPeer(nil)
                }
                ForEach(others) { p in
                    tab(title: title(p), detail: "\(p.terminals)",
                        active: state.peerSelected?.id == p.id) {
                        state.selectPeer(p)
                    }
                    .help(p.working > 0 ? "\(p.url) · \(p.terminals) 个终端，\(p.working) 个运行中"
                                        : "\(p.url) · \(p.terminals) 个终端")
                }
            }
            .padding(3)
            .frame(height: Theme.controlHeight)
            .background(Theme.surfaceContainerHigh).clipShape(Capsule())
            if fleet.scanning {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("正在扫描 \(fleet.sweepSize) 个地址…")
                    .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
            } else if fleet.scanned && others.isEmpty {
                Text("局域网里没有其他 FleetView")
                    .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
            }
            // Said out loud, always — a sweep that quietly covered a slice of a large network would
            // otherwise let "none found" be read as "none there".
            if fleet.scanned && fleet.narrowed {
                Text("网段太大，只扫描了本机所在的 /24")
                    .font(.fvLabelSmall).foregroundColor(Theme.warn)
            }
            if let p = state.peerSelected {
                // Which machine you are driving is the one thing that must never be a guess — every
                // instruction sent from here lands in somebody else's live session.
                Text(p.url).font(.fvMono)
                    .foregroundColor(Theme.onSurfaceVariant).textSelection(.enabled).lineLimit(1)
                stripButton("arrow.up.forward.square", help: "在浏览器里打开这台机器的看板") {
                    NSWorkspace.shared.open(URL(string: p.url + "/")!)
                }
            }
            stripButton("arrow.clockwise", help: "重新扫描局域网") { Task { await state.rescanPeers() } }
                .disabled(fleet.scanning)
            stripButton("xmark", help: "收起") { state.togglePeerStrip() }
        }
    }

    private func tab(title: String, detail: String?, active: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.fvLabel).lineLimit(1)
                if let detail {
                    Text(detail).font(.fvLabelSmall).monospacedDigit()
                        .foregroundColor(active ? Theme.onSecondaryContainer.opacity(0.75) : Theme.onSurfaceVariant)
                }
            }
            .foregroundColor(active ? Theme.onSecondaryContainer : Theme.onSurface)
            .padding(.horizontal, 12).frame(height: Theme.controlHeight - 6)
            .background(active ? Theme.secondaryContainer : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func stripButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .background(Theme.surfaceContainerHigh).clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}
