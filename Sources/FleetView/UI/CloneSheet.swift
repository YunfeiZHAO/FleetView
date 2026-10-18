import SwiftUI
import AppKit

struct CloneSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var repo = ""
    @State private var parentDir = FV.home.appendingPathComponent("PycharmProjects").path
    @State private var error: String?

    private var destPreview: String {
        (parentDir as NSString).appendingPathComponent(Git.repoName(from: repo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(Theme.accent)
                Text(L(.cloneTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
            }

            field(label: L(.cloneRepo)) {
                TextField(L(.cloneRepoPlaceholder), text: $repo)
                    .textFieldStyle(.plain).onSubmit(startClone)
            }

            field(label: L(.cloneInto)) {
                HStack(spacing: 8) {
                    TextField("", text: $parentDir).textFieldStyle(.plain)
                    Button { pickParent() } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).foregroundColor(Theme.subtext)
                }
            }

            if !repo.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("→ \(destPreview)")
                    .font(.fvMono).foregroundColor(Theme.onSurfaceVariant)
                    .lineLimit(1).truncationMode(.middle)
            }

            if let error {
                Text(error).font(.fvMono)
                    .foregroundColor(Theme.error).lineLimit(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Label(L(.cloneBackground), systemImage: "info.circle")
                    .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L(.cancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: startClone) { Text(L(.cloneButton)).fontWeight(.medium) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.surfaceContainerHigh)
    }

    @ViewBuilder private func field<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.fvLabel).foregroundColor(Theme.onSurfaceVariant)
            content()
                .font(.fvBody)
                .padding(.horizontal, 12).frame(height: 40)
                .background(Theme.surfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .foregroundColor(Theme.text)
        }
    }

    /// Hands the clone to the background and gets out of the way. Only what can be answered
    /// instantly is answered here — an empty field, a destination that already exists — because
    /// those are the two failures worth having a dialog still open for (see `Git.precheck`).
    private func startClone() {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        error = nil
        do {
            try Git.precheck(repo: r, into: parentDir)
        } catch {
            self.error = error.localizedDescription
            return
        }
        state.cloneRepository(r, into: parentDir)
        dismiss()
    }

    private func pickParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: parentDir)
        panel.prompt = L(.choose)
        if panel.runModal() == .OK, let url = panel.url { parentDir = url.path }
    }
}
