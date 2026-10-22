import SwiftUI
import AdmiralCore

/// Promotion form for a scratch tab — the New… sheet's rename step: the name; the
/// folder is fixed because the session is already running there.
/// Color and icon are edited afterwards via the avatar popover, like any tab.
struct PromoteTabSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: AgentSession

    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(session: AgentSession) {
        self.session = session
        _name = State(initialValue: session.displayTitle)
    }

    private var canPromote: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Promote to Permanent Tab").font(.system(size: 15, weight: .semibold))

            labeled("Name", required: true) {
                TextField("e.g. worker-1", text: $name)
                    .textFieldStyle(.plain).focused($nameFocused)
                    .onSubmit { if canPromote { promote() } }
            }
            labeled("Folder", required: false) {
                Text(session.cwd).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Promote") { promote() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPromote)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.contentBackground)
        .onAppear { nameFocused = true }
    }

    private func promote() {
        model.promote(session.id, name: name)
        dismiss()
    }

    // Same field chrome as NewTerminalForm (duplicated deliberately — two small
    // App-layer views; extract only if a third form appears).
    @ViewBuilder
    private func labeled<Content: View>(
        _ title: String, required: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                if required { Text("*").font(.system(size: 11)).foregroundStyle(.red) }
            }
            content()
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chipBackground))
        }
    }
}
