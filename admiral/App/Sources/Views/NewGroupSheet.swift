import SwiftUI
import AdmiralCore

/// A name and a checklist of the open (non-scratch) tabs. Create needs 2; a taken name is said
/// inline. On success the model selects the new group and clears `newGroupSheet`.
struct NewGroupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: NewGroupRequest

    @State private var name = ""
    @State private var picked: Set<UUID>
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(request: NewGroupRequest) {
        self.request = request
        _picked = State(initialValue: Set(request.preselected))
    }

    private var tabs: [AgentSession] { model.sessions.sessions.filter { !$0.scratch } }
    /// Ticked tabs that are still open, in sidebar order.
    private var members: [UUID] { tabs.map { model.memberKey(for: $0) }.filter(picked.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Group").font(.system(size: 15, weight: .semibold))

            GroupSheetField(title: "Name") {
                TextField("e.g. Checkout fix", text: $name)
                    .textFieldStyle(.plain).focused($nameFocused)
                    .onSubmit { if members.count >= 2 { create() } }
                    .accessibilityIdentifier("new-group-name")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Tabs").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tabs) { tab in row(tab) }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chipBackground))
            }
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("new-group-error")
            }
            HStack {
                Text("\(members.count) \(members.count == 1 ? "tab" : "tabs") selected")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Cancel") { model.newGroupSheet = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(members.count < 2)
                    .accessibilityIdentifier("new-group-create")
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.contentBackground)
        .onAppear { nameFocused = true }
        .onChange(of: name) { error = nil }
    }

    private func row(_ tab: AgentSession) -> some View {
        let key = model.memberKey(for: tab)
        let on = picked.contains(key)
        return Button {
            if on { picked.remove(key) } else { picked.insert(key) }
        } label: {
            HStack(spacing: 9) {
                Avatar(session: tab, size: 20)
                Text(tab.displayTitle).font(.system(size: 13)).foregroundStyle(Theme.primaryText).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-group-tab-\(tab.callsign)")
    }

    private func create() {
        switch model.createGroup(name: name, members: members) {
        case .success: dismiss()
        case .failure(let refusal): error = refusal.description
        }
    }
}

/// Rename a group; a taken name is said inline.
struct RenameGroupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let group: ChatGroup

    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(group: ChatGroup) {
        self.group = group
        _name = State(initialValue: group.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Group").font(.system(size: 15, weight: .semibold))
            GroupSheetField(title: "Name") {
                TextField("Name", text: $name).textFieldStyle(.plain).focused($focused)
                    .onSubmit(rename)
            }
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.contentBackground)
        .onAppear { focused = true }
    }

    private func rename() {
        switch model.renameGroup(group.id, to: name) {
        case .success: dismiss()
        case .failure(let refusal): error = refusal.description
        }
    }
}

/// The New… forms' field chrome (label over a chip-filled field), as PromoteTabSheet draws it.
private struct GroupSheetField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
            content
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chipBackground))
        }
    }
}
