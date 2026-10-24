import SwiftUI
import AdmiralCore

/// Settings → Bridge & API → Trusted hosts: the built-in hosts as read-only rows, one editable
/// row per extra host, a Docker Desktop preset, and an add field. Every add or remove is saved
/// at once (`model.trustedHosts` persists and applies to `TrustedHosts`), so there is nothing to
/// commit and nothing to lose by closing the window.
struct TrustedHostsList: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Allow Docker Desktop (\(TrustedHosts.dockerDesktop))", isOn: dockerBinding)
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings-trusted-hosts-docker")

            VStack(alignment: .leading, spacing: 4) {
                ForEach(TrustedHosts.builtIn, id: \.self) { host in
                    row(host, removable: false)
                }
                ForEach(model.trustedHosts, id: \.self) { host in
                    row(host, removable: true)
                }
            }

            HStack(spacing: 8) {
                TextField("hostname or IP", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(add)
                    .accessibilityIdentifier("settings-trusted-hosts-field")
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add host")
                .accessibilityIdentifier("settings-trusted-hosts-add")
            }
            .frame(maxWidth: 420)

            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings-trusted-hosts-error")
            }
        }
    }

    private func row(_ host: String, removable: Bool) -> some View {
        HStack(spacing: 8) {
            Text(host)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(removable ? Theme.primaryText : Theme.secondaryText)
            if !removable {
                Text("built in").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if removable {
                Button {
                    model.trustedHosts.removeAll { $0 == host }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(host)")
                .accessibilityIdentifier("settings-trusted-hosts-remove-\(host)")
            }
        }
        .frame(maxWidth: 420)
        .accessibilityIdentifier("settings-trusted-hosts-row-\(host)")
    }

    private func add() {
        switch TrustedHosts.validate(draft, existing: model.trustedHosts) {
        case .success(let host):
            model.trustedHosts.append(host)
            draft = ""
            problem = nil
        case .failure(let reason):
            problem = reason.message
        }
    }

    private var dockerBinding: Binding<Bool> {
        Binding(
            get: { model.trustedHosts.contains(TrustedHosts.dockerDesktop) },
            set: { on in
                if on {
                    if !model.trustedHosts.contains(TrustedHosts.dockerDesktop) {
                        model.trustedHosts.append(TrustedHosts.dockerDesktop)
                    }
                } else {
                    model.trustedHosts.removeAll { $0 == TrustedHosts.dockerDesktop }
                }
            })
    }
}
