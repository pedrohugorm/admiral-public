import SwiftUI
import UniformTypeIdentifiers
import AdmiralCore

/// The shared New Claude Code / New Bash form: name the session and choose the working
/// directory (type a path or browse). `model.newSessionMode` decides which kind is
/// created. A "New Bash" just opens a plain `zsh` login shell in the folder.
struct NewTerminalForm: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var agentName = ""
    @State private var folder = "~/"
    @State private var picking = false
    /// Off = this tab talks to Anthropic exactly as before. On = it launches on `provider`,
    /// and on that alone: no other tab, running or future, is touched.
    @State private var useCustomModel = false
    /// Starts at the Settings → Sessions choice; the chevron lets this one tab deviate.
    @State private var providerID: String?
    @State private var showingProviderPicker = false
    /// Starts at the Settings → Bridge & API "new tabs are scratch" choice.
    @State private var scratch = false
    @FocusState private var nameFocused: Bool

    private var isBash: Bool { model.newSessionMode == .bash }

    /// A plain shell carries no `--settings` file, so there is nothing to inject a provider
    /// through — the control belongs to claude sessions only.
    private var canUseCustomModel: Bool { !isBash && !model.ccSwitchProviders.isEmpty }
    private var provider: CCSwitchProvider? { model.ccSwitchProvider(id: providerID) }

    private var expandedFolder: String { (folder as NSString).expandingTildeInPath }
    private var folderValid: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: expandedFolder, isDirectory: &isDir) && isDir.boolValue
    }
    private var canCreate: Bool {
        !agentName.trimmingCharacters(in: .whitespaces).isEmpty && folderValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isBash ? "New Bash" : "New Claude Code").font(.system(size: 15, weight: .semibold))

            labeled("Name", required: true) {
                TextField(isBash ? "e.g. shell" : "e.g. worker-1", text: $agentName)
                    .textFieldStyle(.plain).focused($nameFocused)
                    .onSubmit { if canCreate { create() } }
            }
            labeled("Folder", required: true) {
                HStack(spacing: 8) {
                    TextField("~/", text: $folder).textFieldStyle(.plain)
                    Button("Choose…") { picking = true }
                }
            }
            if !folder.isEmpty && !folderValid {
                Text("Not a folder: \(expandedFolder)")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            if canUseCustomModel { customModelRow }
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: $scratch) {
                    Text("Scratch tab").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("new-session-scratch")
                Text("Small row at the bottom of the sidebar, not restored on relaunch, closed after "
                     + "\(model.scratchTabIdleMinutes) min idle once its goals are done. Promote it to keep it.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.contentBackground)
        .onAppear {
            nameFocused = true
            // CC Switch is edited next door while Admiral runs, so the list is read when the
            // form opens, not once at launch. The Settings choice is the starting point.
            model.refreshCCSwitchProviders()
            providerID = model.launchOptionsStore.load().providerID
            scratch = model.scratchByDefault
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { folder = url.path }
        }
    }

    /// The provider's name rides on the checkbox itself, so you know what you are about to
    /// launch without opening Settings. The chevron deviates for this tab only.
    @ViewBuilder
    private var customModelRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Toggle(isOn: $useCustomModel) {
                    Text("Use custom model")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("new-session-custom-model")

                if let provider {
                    Text("— \(provider.name)")
                        .font(.system(size: 12))
                        .foregroundStyle(useCustomModel ? Theme.primaryText : Theme.secondaryText)
                        .lineLimit(1)
                }
                Button {
                    showingProviderPicker.toggle()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Use a different CC Switch config for this tab")
                .accessibilityIdentifier("new-session-provider-chevron")
                .popover(isPresented: $showingProviderPicker, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.ccSwitchProviders) { candidate in
                            Button {
                                providerID = candidate.id
                                useCustomModel = true
                                showingProviderPicker = false
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: candidate.id == providerID ? "checkmark" : "")
                                        .font(.system(size: 9, weight: .bold)).frame(width: 10)
                                    Text(candidate.name).font(.system(size: 12))
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10).frame(minWidth: 220)
                }
                Spacer(minLength: 0)
            }
            if useCustomModel, let url = provider?.baseURL {
                Text("→ \(url)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private func create() {
        model.newSession(
            name: agentName, cwd: expandedFolder,
            provider: useCustomModel ? provider : nil,
            scratch: scratch
        )
        dismiss()
    }

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
