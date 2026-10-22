import SwiftUI
import AdmiralCore

/// Settings → Watchdog. The trigger→template rules that keep a session driving a standing
/// directive (idle → forced-format probe → templated nag until it reports done), plus the
/// idle threshold that fires a probe and the timeout that reclaims an ignored one. Saved
/// on every change; the service re-reads the store each tick, so edits apply live.
struct WatchdogSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var config: WatchdogConfig = .default
    @State private var goals: GoalsNudgeConfig = .default
    /// The editable goal-writing guidance. Empty means "use the built-in" — the same meaning
    /// the file has, so the box and the file never disagree about what a blank one implies.
    @State private var guidance = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("Goals",
                             "Separate from the watchdog: a session with goals set over the "
                                + "bridge is probed once it has been idle past the threshold, "
                                + "and nagged with whatever is still open. The probe's answer "
                                + "is what marks a goal done. A session only ever gets one "
                                + "nudge at a time — the watchdog goes first.") {
                    Toggle("Nudge sessions with open goals", isOn: $goals.enabled)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-goals-toggle")
                    Stepper("Probe after \(goals.idleThresholdMinutes) min idle",
                            value: $goals.idleThresholdMinutes, in: 1...120)
                        .font(.system(size: 12))
                    Stepper("Reclaim unanswered probe after \(goals.probeTimeoutMinutes) min",
                            value: $goals.probeTimeoutMinutes, in: 1...60)
                        .font(.system(size: 12))
                }

                SettingsCard("How goals should be written",
                             "Goes into the `set_goal` tool description a session reads when "
                                + "it sets goals — the lever for getting outcomes (\"the panel "
                                + "hides itself when there are no tasks\") instead of commands "
                                + "(\"run the tests\"). Leave it empty for the built-in text. "
                                + "Sessions read it when they start, so an edit reaches the "
                                + "next one. Stored at "
                                + "~/Library/Application Support/Admiral/goal-guidance.txt, "
                                + "so a session can edit it too.") {
                    FieldEditor(text: $guidance,
                                placeholder: "Empty: sessions get the built-in guidance. Load built-in copies it here to edit.",
                                monospaced: true, height: 140, identifier: "settings-goal-guidance")
                    HStack {
                        Text(guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "Using the built-in guidance." : "Using your guidance.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Load built-in") { guidance = GoalGuidance.builtIn }
                            .font(.system(size: 11))
                        Button("Reset") { guidance = "" }
                            .font(.system(size: 11))
                    }
                }

                SettingsCard("Watchdog",
                             "Watches every hosted session's prompts for a rule's trigger "
                                + "phrase. Once armed, a session idle past the threshold is "
                                + "probed for a structured status answer; anything short of "
                                + "`done` gets the rule's nag injected. Disarm via `done`, "
                                + "or right-click a session row.") {
                    Toggle("Enable Watchdog", isOn: $config.enabled)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-watchdog-toggle")
                    Stepper("Probe after \(config.idleThresholdMinutes) min idle",
                            value: $config.idleThresholdMinutes, in: 1...120)
                        .font(.system(size: 12))
                    Stepper("Reclaim unanswered probe after \(config.probeTimeoutMinutes) min",
                            value: $config.probeTimeoutMinutes, in: 1...60)
                        .font(.system(size: 12))
                }

                SettingsCard("Rules",
                             "First matching trigger wins (case-insensitive substring). "
                                + "Templates support `{trigger}`, `{prompt}`, `{status}`, "
                                + "`{reason}`, and `{idle_minutes}`.") {
                    ForEach($config.rules) { $rule in
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsField(label: "Trigger", text: $rule.trigger,
                                          identifier: "watchdog-rule-trigger", onCommit: {})
                            templateEditor("Probe", text: $rule.probeTemplate)
                            templateEditor("Nag", text: $rule.nagTemplate)
                            Button("Remove Rule", role: .destructive) {
                                config.rules.removeAll { $0.id == rule.id }
                            }
                            .font(.system(size: 11))
                        }
                        .padding(10)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button("Add Rule") {
                        config.rules.append(WatchRule(trigger: "", probeTemplate: "", nagTemplate: ""))
                    }
                    .accessibilityIdentifier("settings-watchdog-add-rule")
                }
            }
            .padding(20)
        }
        .onAppear {
            config = model.watchdogConfigStore.load()
            goals = model.goalsNudgeConfigStore.load()
            // The box shows the override only. Blank = no override, which is exactly what an
            // absent file means — so what you see is what is stored, not the effective text.
            guidance = GoalGuidance.isCustomized(base: model.sessions.supportDir)
                ? (try? String(contentsOf: GoalGuidance.file(base: model.sessions.supportDir),
                               encoding: .utf8)) ?? "" : ""
        }
        .onChange(of: config) { _, newValue in model.watchdogConfigStore.save(newValue) }
        .onChange(of: goals) { _, newValue in model.goalsNudgeConfigStore.save(newValue) }
        .onChange(of: guidance) { _, newValue in
            GoalGuidance.set(newValue, base: model.sessions.supportDir)
        }
    }

    private func templateEditor(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .frame(width: 96, alignment: .leading)
            TextField("", text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...5)
        }
    }
}
