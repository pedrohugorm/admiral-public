import SwiftUI
import AdmiralCore

/// Settings → Notifications. The master switch and the per-kind toggles are all enforced in
/// one place, `NotificationService.post(kind:…)` (via `NotificationPolicy`), so nothing that
/// posts can bypass them.
struct NotificationsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(NotificationPolicy.questionKey) private var question = true
    @AppStorage(NotificationPolicy.needsInputKey) private var needsInput = true
    @AppStorage(NotificationPolicy.terminalKey) private var terminal = true
    @AppStorage(NotificationPolicy.doneKey) private var done = true
    @AppStorage(NotificationPolicy.nudgeKey) private var nudge = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("Notifications",
                             "Master switch for every native notification Admiral posts to "
                                + "Notification Center — terminal, hook, `notify` tool, "
                                + "watchdog and goals nudges. Clicking one focuses that "
                                + "session. Requires Admiral to have notification permission "
                                + "in System Settings. Existing tabs pick up hook changes "
                                + "when restarted.") {
                    Toggle("Notifications", isOn: $model.notificationsEnabled)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-notifications-toggle")
                }
                SettingsCard("What to notify about",
                             "A question always notifies. Permission/input and terminal "
                                + "notifications are skipped while Admiral is frontmost and that "
                                + "tab is selected. All are off when the master switch is.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Claude asks a question (AskUserQuestion)", isOn: $question)
                            .accessibilityIdentifier("settings-notify-question")
                        Toggle("Needs permission / input", isOn: $needsInput)
                            .accessibilityIdentifier("settings-notify-needs-input")
                        Toggle("Terminal notifications (OSC)", isOn: $terminal)
                            .accessibilityIdentifier("settings-notify-terminal")
                        Toggle("Tab finished (watchdog done / all goals met)", isOn: $done)
                            .accessibilityIdentifier("settings-notify-done")
                        Toggle("Nudges (Watchdog/Goals) — off by default", isOn: $nudge)
                            .accessibilityIdentifier("settings-notify-nudge")
                    }
                    .toggleStyle(.switch)
                    .disabled(!model.notificationsEnabled)
                }
            }
            .padding(20)
        }
    }
}
