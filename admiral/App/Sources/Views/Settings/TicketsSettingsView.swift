import SwiftUI
import AdmiralCore

/// Settings → Tickets. Patterns that find ticket keys in a session's chat (shown in the
/// Footprint panel), the URL a key opens, and connectors that add status. Non-secrets are
/// saved to `<support dir>/config.json`; the client secret and OAuth tokens live only
/// in the Keychain.
struct TicketsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tickets = AdmiralConfig.TicketsConfig()
    @State private var secret = ""
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("Patterns",
                             "Regular expressions matched against the session's chat — prompts, "
                                + "replies and questions. Every match is a ticket key, listed "
                                + "above the repos in Footprint. Invalid patterns are skipped.") {
                    ForEach(tickets.patterns.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            TextField("", text: patternBinding(i))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .accessibilityIdentifier("tickets-pattern-\(i)")
                            if !isValid(tickets.patterns[i]) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.busyAmber).help("Invalid regular expression")
                            }
                            Button { tickets.patterns.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .disabled(tickets.patterns.count <= 1)
                                .help("Remove pattern")
                        }
                    }
                    HStack {
                        Button("Add Pattern") { tickets.patterns.append("") }
                        Button("Reset to Default") {
                            tickets.patterns = [AdmiralConfig.TicketsConfig.defaultPattern]
                        }
                    }
                    .font(.system(size: 11))
                }

                SettingsCard("Open URL",
                             "Clicking a ticket opens this URL with `{key}` replaced. Leave it "
                                + "empty to use the Jira site URL + `/browse/{key}`.") {
                    SettingsField(label: "Template", text: $tickets.openURLTemplate,
                                  identifier: "tickets-open-url", onCommit: {})
                }

                SettingsCard("Jira",
                             "Connect to show each ticket's status. Create an OAuth 2.0 (3LO) "
                                + "app at developer.atlassian.com, add the Jira API scope "
                                + "`read:jira-work`, and set its callback URL to "
                                + "`admiral://oauth/jira`. Paste the app's Client ID and "
                                + "Secret here; the secret and tokens are kept in the Keychain. "
                                + "Without a connection, keys still show — just no status.") {
                    SettingsField(label: "Site URL", text: $tickets.jira.siteURL,
                                  identifier: "tickets-jira-site", onCommit: {})
                    SettingsField(label: "Client ID", text: $tickets.jira.clientId,
                                  identifier: "tickets-jira-client-id", onCommit: {})
                    HStack(spacing: 10) {
                        Text("Secret").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            .frame(width: 96, alignment: .leading)
                        SecureField(model.jiraHasClientSecret ? "Stored in Keychain" : "", text: $secret)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(saveSecret)
                            .accessibilityIdentifier("tickets-jira-secret")
                        Button("Save") { saveSecret() }.disabled(secret.isEmpty)
                    }
                    HStack(spacing: 10) {
                        Circle().fill(model.ticketsConnected ? Theme.checkGreen : Theme.pendingGray)
                            .frame(width: 8, height: 8)
                        Text(model.ticketsConnected ? "Connected" : (model.jiraConnecting ? "Connecting…" : "Not connected"))
                            .font(.system(size: 12))
                            .accessibilityIdentifier("tickets-jira-status")
                        Spacer()
                        if model.ticketsConnected {
                            Button("Disconnect") { model.disconnectJira() }
                                .accessibilityIdentifier("tickets-jira-disconnect")
                        } else {
                            Button("Connect") { save(); saveSecret(); model.connectJira() }
                                .disabled(model.jiraConnecting || tickets.jira.clientId.isEmpty
                                          || (!model.jiraHasClientSecret && secret.isEmpty))
                                .accessibilityIdentifier("tickets-jira-connect")
                        }
                    }
                    if let error = model.jiraAuthError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Disconnect removes the tokens and the secret from the Keychain.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(20)
        }
        .onAppear {
            tickets = model.config.tickets
            DispatchQueue.main.async { loaded = true }
        }
        .onChange(of: tickets) { _, _ in if loaded { save() } }
    }

    private func patternBinding(_ i: Int) -> Binding<String> {
        Binding(get: { tickets.patterns.indices.contains(i) ? tickets.patterns[i] : "" },
                set: { if tickets.patterns.indices.contains(i) { tickets.patterns[i] = $0 } })
    }

    private func isValid(_ pattern: String) -> Bool {
        pattern.isEmpty || (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// Saved on every edit; blank patterns are dropped (all blank → the default).
    private func save() {
        var cleaned = tickets
        cleaned.patterns = tickets.patterns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if cleaned.patterns.isEmpty { cleaned.patterns = [AdmiralConfig.TicketsConfig.defaultPattern] }
        cleaned.openURLTemplate = cleaned.openURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.jira.siteURL = cleaned.jira.siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.jira.clientId = cleaned.jira.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != model.config.tickets else { return }
        model.updateTicketsConfig(cleaned)
    }

    private func saveSecret() {
        guard !secret.isEmpty else { return }
        model.setJiraClientSecret(secret)
        secret = ""
    }
}
