import AppIntents

/// Spoken phrases for Siri / Spotlight. (System registration requires an Xcode build
/// with a Developer Team; the intents themselves run regardless.)
struct AdmiralShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListSessionsIntent(),
            phrases: ["List my sessions in \(.applicationName)"],
            shortTitle: "List Sessions",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: GetSessionStatusIntent(),
            phrases: [
                "What is \(\.$session) doing in \(.applicationName)",
                "Ask \(.applicationName) about \(\.$session)",
            ],
            shortTitle: "Session Status",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: ["Tell \(\.$session) to do something in \(.applicationName)"],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: SetGoalIntent(),
            phrases: ["Set a goal for \(\.$session) in \(.applicationName)"],
            shortTitle: "Set Goal",
            systemImageName: "target"
        )
        AppShortcut(
            intent: BroadcastIntent(),
            phrases: ["Broadcast to the fleet in \(.applicationName)"],
            shortTitle: "Broadcast",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: CommissionSessionIntent(),
            phrases: ["Commission a session in \(.applicationName)"],
            shortTitle: "Commission",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: FocusSessionIntent(),
            phrases: ["Open \(\.$session) in \(.applicationName)"],
            shortTitle: "Open Session",
            systemImageName: "macwindow"
        )
    }
}
