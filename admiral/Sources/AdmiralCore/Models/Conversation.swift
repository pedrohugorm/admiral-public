import Foundation

/// The rendered model of a Claude session transcript — what the Transcript View draws.
public struct Conversation: Sendable, Equatable {
    public var title: String?
    public var turns: [Turn]
    public var plan: PlanModel?

    public init(title: String? = nil, turns: [Turn] = [], plan: PlanModel? = nil) {
        self.title = title
        self.turns = turns
        self.plan = plan
    }

    public static let empty = Conversation()
}

/// One renderable unit of the conversation.
public enum Turn: Sendable, Equatable, Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, markdown: String, model: String?)
    case thinking(id: String, text: String)
    case tool(id: String, name: String, params: String, result: String?, state: ToolState)

    public var id: String {
        switch self {
        case let .user(id, _): return "u-\(id)"
        case let .assistant(id, _, _): return "a-\(id)"
        case let .thinking(id, _): return "t-\(id)"
        case let .tool(id, _, _, _, _): return "x-\(id)"
        }
    }
}

/// Outcome of a tool call. One enum, rendered in one place.
public enum ToolState: String, Sendable, Equatable {
    case running
    case success
    case error
}

/// The plan/todo card model — folded from Task*/TodoWrite events.
public struct PlanModel: Sendable, Equatable {
    public var title: String?
    public var items: [PlanItem]

    public init(title: String? = nil, items: [PlanItem]) {
        self.title = title
        self.items = items
    }

    /// "2/3" — completed over total.
    public var progress: (done: Int, total: Int) {
        (items.filter { $0.state == .completed }.count, items.count)
    }
}

public struct PlanItem: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var state: PlanItemState

    public init(id: String, title: String, state: PlanItemState) {
        self.id = id
        self.title = title
        self.state = state
    }
}

public extension Array where Element == PlanItem {
    /// Display order for a checklist: open work first, met items sunk to the bottom, each
    /// group keeping its original order. The panel is small, and what's left matters more
    /// than what's done — so the list reads as a to-do, not a history.
    var openFirst: [PlanItem] {
        filter { $0.state != .completed } + filter { $0.state == .completed }
    }
}

public enum PlanItemState: String, Sendable, Equatable {
    case pending
    case inProgress
    case completed

    /// Map a Claude status string ("completed"/"in_progress"/else) — one decision site
    /// shared by both Task* and TodoWrite sources.
    public init(statusString: String?) {
        switch statusString {
        case "completed": self = .completed
        case "in_progress": self = .inProgress
        default: self = .pending
        }
    }
}
