import SwiftUI
import AppKit

/// A centred dialog over the window. One at a time; `AppState.dialog` says which.
///
/// These were popovers, and a popover leaves the board behind it at full strength, so a QR code
/// floating over a grid of cards read as one more card. A dialog recedes everything behind it the
/// same way search and the session tree do (see `DashboardView.dashboardReceded`), and closes the
/// same way: Esc, or a click on the dimmed area.
enum AppDialog: Identifiable, Equatable {
    /// Open the dashboard on a phone. With a terminal, the link goes straight to that terminal's
    /// conversation (`#t=<id>`), exactly where tapping its card on the dashboard would land.
    case webLink(terminalId: UUID?)
    /// Stop every terminal (and optionally the board), with the quit setting beside it.
    case closeAll

    var id: String {
        switch self {
        case .webLink(let t): return "webLink-\(t?.uuidString ?? "board")"
        case .closeAll:       return "closeAll"
        }
    }
}

/// Hosts whatever `state.dialog` holds: the click catcher, the Esc binding, and the card.
struct DialogHost: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let dialog = state.dialog {
            ZStack {
                // Catcher only — the dashboard's recede supplies the dimming.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { state.dialog = nil }
                Group {
                    switch dialog {
                    case .webLink(let terminalId):
                        WebLinkDialog(terminalId: terminalId)
                    case .closeAll:
                        CloseAllDialog()
                    }
                }
                .background(Theme.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dialog))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            }
            .background {
                Button("") { state.dialog = nil }.keyboardShortcut(.cancelAction).hidden()
            }
            .transition(.opacity)
        }
    }
}

/// "在手机上打开": a QR code for the web dashboard, or for one terminal's conversation on it.
///
/// It used to hand out the terminal's raw ttyd page on a port of its own, which is not what tapping
/// that terminal on the dashboard shows and needed ttyd installed. The dashboard link needs only the
/// web server, and the chat is the view a phone is actually for.
struct WebLinkDialog: View {
    @EnvironmentObject var state: AppState
    let terminalId: UUID?

    @State private var pick: String?
    @State private var qr: NSImage?
    @State private var copied = false

    private var terminal: TerminalSession? {
        terminalId.flatMap { id in state.terminals.first { $0.id == id } }
    }

    /// The `#t=` suffix the web page reads to open a conversation directly.
    private var suffix: String { terminalId.map { "#t=\($0.uuidString)" } ?? "" }

    var body: some View {
        let addresses = state.webDashboardAddresses
        let picked = addresses.first { $0.url == pick } ?? addresses.first
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.system(size: 16)).foregroundColor(Theme.accent)
                Text("在手机上打开").font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Spacer()
                Button { state.dialog = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.onSurfaceVariant).frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(.plain).help("关闭 (Esc)")
            }
            Text(subtitle)
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4).padding(.bottom, 14)

            if let picked {
                if addresses.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(addresses) { address in
                            let on = address.url == picked.url
                            Button { select(address.url) } label: {
                                Text(address.label).font(.fvLabel)
                                    .foregroundColor(on ? Theme.onSecondaryContainer : Theme.onSurfaceVariant)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(on ? Theme.secondaryContainer : Color.clear)
                                    .clipShape(Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(address.reach)
                        }
                    }
                    .padding(3)
                    .background(Theme.surfaceContainerHighest).clipShape(Capsule())
                    .padding(.bottom, 14)
                }
                if let qr {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 168, height: 168)
                        .padding(10).background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 14)
                }
                HStack(spacing: 6) {
                    Text(picked.url + suffix)
                        .font(.fvMono)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .foregroundColor(Theme.onSurface)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: Theme.controlHeight, alignment: .leading)
                        .background(Theme.surfaceContainerHighest).clipShape(Capsule())
                    roundButton(copied ? "checkmark" : "doc.on.doc", help: "复制链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(picked.url + suffix, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    // Deliberately localhost: opening it on the Mac that serves it should not depend
                    // on the Mac routing back to itself through Tailscale or the router.
                    roundButton("arrow.up.right.square", help: "在这台 Mac 的浏览器里打开") {
                        if let url = URL(string: "http://localhost:\(state.web.port)/\(suffix)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Label(picked.reach + "。能访问这个地址的设备都能操作" + (terminalId == nil ? "所有终端" : "这个终端"),
                      systemImage: "info.circle")
                    .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            } else {
                Text("没有联网，或者 Web 服务没有启动。连上网络后再打开这里。")
                    .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 22)
        .frame(width: 404)
        .onAppear {
            // Re-read on every open: the tailnet goes up and down, and Wi-Fi changes address.
            select(addresses.first { $0.url == pick }?.url ?? addresses.first?.url)
        }
    }

    private var subtitle: String {
        if let terminal {
            return "\(terminal.name) · 打开后直接进入它的聊天视图，和在 Web 看板上点开这张卡片一样"
        }
        return "打开后能看到所有终端，点一张卡片就能操作它"
    }

    private func select(_ url: String?) {
        pick = url
        qr = url.flatMap { QRCode.image(for: $0 + suffix) }
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .background(Theme.surfaceContainerHighest).clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// "关闭所有终端": what it stops, what it keeps, and the quit-time setting that automates it.
struct CloseAllDialog: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let open = state.openTerminalCount
        let working = state.terminals.filter { $0.status == .working }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "power").font(.system(size: 16)).foregroundColor(Theme.error)
                Text("关闭所有终端").font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Spacer()
            }
            .padding(.bottom, 12)
            Text(open > 0 ? "\(open) 个终端正在运行。关闭会停止它们的 agent 进程，tmux 会话一并销毁。"
                          : "当前没有打开的终端。仍会清理可能残留的 tmux 会话。")
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            // The one thing that makes this safe to press: nothing is lost from the board.
            Label("卡片会保留。点击卡片可以重新打开，并接着原来的 Claude / Codex 会话。",
                  systemImage: "arrow.uturn.backward")
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if working > 0 {
                Label("\(working) 个 agent 正在工作，会被打断。", systemImage: "exclamationmark.triangle.fill")
                    .font(.fvBodySmall).foregroundColor(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            Toggle(isOn: Binding(get: { state.closeTerminalsOnQuit },
                                 set: { state.closeTerminalsOnQuit = $0; state.save() })) {
                Text("退出 FleetView 时也关闭所有终端").font(.fvBodySmall).foregroundColor(Theme.onSurface)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 16)
            Text(state.closeTerminalsOnQuit ? "退出即结束整个 fleet。"
                                            : "默认关闭：退出后终端继续在后台运行，下次启动自动重新接上。")
                .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 8) {
                // Secondary by design, and behind its own alert: it sits beside the main action and
                // does something that action explicitly does not — throw the board away.
                Button {
                    state.dialog = nil
                    BoardActions.confirmClear(state, reason: "topbar")
                } label: {
                    Text("清空看板…").font(.fvLabel).foregroundColor(Theme.error)
                        .padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("移除全部项目与终端卡片（对话历史不受影响）")
                Spacer()
                Button { state.dialog = nil } label: {
                    Text("取消").font(.fvLabel).foregroundColor(Theme.primary)
                        .padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    state.dialog = nil
                    state.closeAllTerminals(reason: "topbar")
                } label: {
                    Text("关闭全部终端").font(.fvLabel).foregroundColor(Theme.onPrimary)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(Theme.error).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 420)
    }
}
