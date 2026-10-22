import AppIntents
import CoreSpotlight
import AdmiralCore

/// The App Intents view of a session. `agentType` is a first-class `@Property`, so
/// Siri/Shortcuts can see and filter on `claude_code`. Conforms to `IndexedEntity` so
/// sessions land in Spotlight's semantic index and are referenceable in natural language.
struct AgentSessionEntity: AppEntity, IndexedEntity, Identifiable {
    let id: UUID

    @Property(title: "Callsign") var callsign: String
    @Property(title: "Agent Type") var agentType: String
    @Property(title: "Status") var status: String
    @Property(title: "Working Directory") var cwd: String
    @Property(title: "Branch") var branch: String
    @Property(title: "Title") var title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Agent Session" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(agentType)")
    }

    /// Extend the default attribute set (don't replace it) with the session's context so
    /// Spotlight can match on directory, branch, status, and agent type.
    var attributeSet: CSSearchableItemAttributeSet {
        let attrs = defaultAttributeSet
        attrs.contentDescription = "\(agentType) · \(status) · \(cwd)"
        attrs.keywords = [callsign, agentType, status, "claude", "session", "admiral"]
        if !branch.isEmpty { attrs.comment = "branch: \(branch)" }
        return attrs
    }

    static var defaultQuery = AgentSessionQuery()

    init(id: UUID, callsign: String, agentType: String, status: String, cwd: String, branch: String, title: String) {
        self.id = id
        self.callsign = callsign
        self.agentType = agentType
        self.status = status
        self.cwd = cwd
        self.branch = branch
        self.title = title
    }

    @MainActor
    init(_ session: AgentSession) {
        self.init(
            id: session.id,
            callsign: session.callsign,
            agentType: session.agentType.id,
            status: session.status.rawValue,
            cwd: session.cwd,
            branch: session.gitBranch ?? "",
            title: session.displayTitle
        )
    }
}

struct AgentSessionQuery: EntityQuery, EnumerableEntityQuery, EntityStringQuery {
    func allEntities() async throws -> [AgentSessionEntity] {
        await MainActor.run { (AppState.shared.model?.sessions.sessions ?? []).map(AgentSessionEntity.init) }
    }

    func entities(for identifiers: [UUID]) async throws -> [AgentSessionEntity] {
        await MainActor.run {
            (AppState.shared.model?.sessions.sessions ?? [])
                .filter { identifiers.contains($0.id) }
                .map(AgentSessionEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [AgentSessionEntity] {
        await MainActor.run {
            (AppState.shared.model?.sessions.sessions ?? [])
                .filter {
                    $0.callsign.localizedCaseInsensitiveContains(string)
                        || $0.displayTitle.localizedCaseInsensitiveContains(string)
                }
                .map(AgentSessionEntity.init)
        }
    }

    func suggestedEntities() async throws -> [AgentSessionEntity] {
        try await allEntities()
    }
}

enum AdmiralIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case sessionNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: return "Admiral is not running."
        case .sessionNotFound: return "That session was not found."
        }
    }
}
