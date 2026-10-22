import AppIntents
import AppKit
import AdmiralCore

// MARK: - Helpers

@MainActor
private func requireModel() throws -> AppModel {
    guard let model = AppState.shared.model else { throw AdmiralIntentError.notRunning }
    return model
}

/// The single "resolve the live session by id, else fail" decision, shared by the
/// intents that take a session parameter.
@MainActor
private func requireSession(_ id: UUID) throws -> (model: AppModel, session: AgentSession) {
    let model = try requireModel()
    guard let session = model.sessions.sessions.first(where: { $0.id == id }) else {
        throw AdmiralIntentError.sessionNotFound
    }
    return (model, session)
}

// MARK: - List / status (read-only)

struct ListSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Sessions"
    static var description = IntentDescription("List the Claude Code sessions Admiral is hosting.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[AgentSessionEntity]> {
        let entities = try await AgentSessionQuery().allEntities()
        let dialog: IntentDialog = entities.isEmpty
            ? "No sessions are running."
            : "\(entities.count) session\(entities.count == 1 ? "" : "s"): \(entities.map(\.callsign).joined(separator: ", "))."
        return .result(value: entities, dialog: dialog)
    }
}

struct GetSessionStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Session Status"
    static var description = IntentDescription("Report what a session is doing and its plan progress.")

    @Parameter(title: "Session") var session: AgentSessionEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = try await MainActor.run { () -> String in
            let (model, live) = try requireSession(session.id)
            let convo = model.sessions.conversations[live.id]
            var parts = ["\(live.displayTitle) is \(live.status.rawValue)"]
            if let plan = convo?.plan {
                parts.append("step \(plan.progress.done + 1) of \(plan.progress.total)")
                if let current = plan.items.first(where: { $0.state == .inProgress }) {
                    parts.append("— \(current.title)")
                }
            }
            return parts.joined(separator: ", ")
        }
        return .result(dialog: "\(line).")
    }
}

// MARK: - Send free text (confirmation-guarded)

struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Message to Session"
    static var description = IntentDescription("Type a message into a session and submit it.")

    @Parameter(title: "Session") var session: AgentSessionEntity
    @Parameter(title: "Message") var message: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            result: .result(dialog: "Send “\(message)” to \(session.callsign)?")
        )
        try await MainActor.run {
            let model = try requireModel()
            model.sessions.send(session.id, text: message)
        }
        return .result(dialog: "Sent to \(session.callsign).")
    }
}

struct SetGoalIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Session Goal"
    static var description = IntentDescription("Set a completion goal on a session.")

    @Parameter(title: "Session") var session: AgentSessionEntity
    @Parameter(title: "Goal") var goal: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Through the bridge, not a bare injection: goals set by Siri have to land in the
        // store too, or the panel and the nudge never learn about them.
        let outcome = try await MainActor.run { () -> BridgeResult in
            let model = try requireModel()
            guard let target = model.sessions.sessions.first(where: { $0.id == session.id })
            else { return .failure("that session is gone") }
            return model.bridge.setGoal(fromToken: target.token, to: target.displayTitle,
                                        goals: [goal])
        }
        return .result(dialog: "\(outcome.message)")
    }
}

// MARK: - Bridge messaging

struct HailIntent: AppIntent {
    static var title: LocalizedStringResource = "Hail a Station"
    static var description = IntentDescription("Send a message from one session to another by callsign.")

    @Parameter(title: "From") var from: AgentSessionEntity
    @Parameter(title: "To callsign") var to: String
    @Parameter(title: "Message") var body: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Typed into another session as a prompt: confirmed first, like SendMessage.
        try await requestConfirmation(
            result: .result(dialog: "Send “\(body)” from \(from.callsign) to @\(to)?")
        )
        let result = try await MainActor.run { () -> BridgeResult in
            let (model, sender) = try requireSession(from.id)
            return model.bridge.hail(fromToken: sender.token, to: to, body: body)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct BroadcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Broadcast to Fleet"
    static var description = IntentDescription("Message every peer station from a session.")

    @Parameter(title: "From") var from: AgentSessionEntity
    @Parameter(title: "Message") var body: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Typed into every peer session as a prompt: confirmed first, like SendMessage.
        try await requestConfirmation(
            result: .result(dialog: "Broadcast “\(body)” from \(from.callsign) to every station?")
        )
        let result = try await MainActor.run { () -> BridgeResult in
            let (model, sender) = try requireSession(from.id)
            return model.bridge.broadcast(fromToken: sender.token, body: body)
        }
        return .result(dialog: "\(result.message)")
    }
}

// MARK: - Commission / focus (open the app)

struct CommissionSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Commission Session"
    static var description = IntentDescription("Launch a new Claude Code session in a directory.")
    static var openAppWhenRun = true

    @Parameter(title: "Callsign") var callsign: String
    @Parameter(title: "Directory") var directory: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The new session runs claude unattended in that folder: only an existing folder,
        // and only once the user confirms, like SendMessage.
        guard let cwd = CommissionDirectory.resolve(
            directory, home: FileManager.default.homeDirectoryForCurrentUser.path)
        else { throw AdmiralIntentError.notADirectory(directory ?? "") }
        try await requestConfirmation(
            result: .result(dialog: "Launch a new session \(callsign) in \(cwd)?")
        )
        try await MainActor.run {
            let model = try requireModel()
            model.sessions.commission(callsign: callsign, cwd: cwd)
        }
        return .result(dialog: "Commissioned \(callsign).")
    }
}

struct FocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Session"
    static var description = IntentDescription("Bring Admiral forward focused on a session.")
    static var openAppWhenRun = true

    @Parameter(title: "Session") var session: AgentSessionEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MainActor.run {
            let model = try requireModel()
            model.sessions.selectedID = session.id
            NSApp.activate(ignoringOtherApps: true)
        }
        return .result(dialog: "Opened \(session.callsign).")
    }
}
