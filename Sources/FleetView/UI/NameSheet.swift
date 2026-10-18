import SwiftUI

/// Small dialog to name a new terminal (before it opens) or rename an existing one.
struct NameSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: AppState.NameSheetRequest

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.fvTitleMedium).foregroundColor(Theme.onSurface)

            TextField("名称", text: $name)
                .textFieldStyle(.plain).font(.fvBody)
                .padding(.horizontal, 14).frame(height: 40)
                .background(Theme.surfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .foregroundColor(Theme.onSurface)
                .focused($focused)
                .onSubmit(confirm)

            HStack {
                Spacer()
                Button("取消") { state.nameSheet = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmLabel, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Theme.surfaceContainerHigh)
        .onAppear {
            name = request.initialName
            DispatchQueue.main.async { focused = true }
        }
    }

    private func confirm() {
        state.confirmName(name)
        dismiss()
    }
}
