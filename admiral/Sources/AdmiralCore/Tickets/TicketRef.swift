import Foundation

/// A ticket key discovered in chat, optionally enriched with status from a connector.
public struct TicketRef: Identifiable, Equatable, Sendable, Hashable {
    public var id: String { key }
    public var key: String
    public var summary: String?
    public var statusName: String?
    public var statusCategory: StatusCategory

    public enum StatusCategory: String, Equatable, Sendable, Hashable {
        case todo
        case inProgress
        case done
        case unknown
    }

    public init(
        key: String,
        summary: String? = nil,
        statusName: String? = nil,
        statusCategory: StatusCategory = .unknown
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.statusCategory = statusCategory
    }

    /// Map Jira Cloud `status.statusCategory.key` (`new` / `indeterminate` / `done`).
    public static func category(fromJiraKey raw: String?) -> StatusCategory {
        switch raw?.lowercased() {
        case "new": return .todo
        case "indeterminate": return .inProgress
        case "done": return .done
        default: return .unknown
        }
    }
}
