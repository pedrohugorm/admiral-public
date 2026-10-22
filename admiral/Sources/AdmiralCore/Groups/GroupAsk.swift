import Foundation

/// A member's question (through the bridge's `AskUserQuestion` mirror), shown in the group
/// window as a message from that member. It comes from the member's chat ledger, never from
/// the group log: asking wakes nobody and is not a `GroupMessage`.
public struct GroupAsk: Identifiable, Equatable, Sendable {
    /// The asking member's key.
    public let member: UUID
    /// The question's ledger line, so an item keeps its identity as the ledger grows.
    public let ledgerID: Int
    public let ts: Date
    public let questions: [AskQuestion]
    /// Still waiting on an answer. Derived exactly as the tab's own card is (`ChatFolder`):
    /// a later prompt in the member's session answers it, whichever surface typed that prompt.
    public let open: Bool

    public var id: String { "ask:\(member.uuidString):\(ledgerID)" }

    public init(member: UUID, ledgerID: Int, ts: Date, questions: [AskQuestion], open: Bool) {
        self.member = member
        self.ledgerID = ledgerID
        self.ts = ts
        self.questions = questions
        self.open = open
    }
}

/// One row of the group window: a logged message, or a member's question.
public enum GroupTimelineItem: Identifiable, Equatable, Sendable {
    case message(GroupMessage)
    case ask(GroupAsk)

    public var id: String {
        switch self {
        case .message(let message): return "msg:\(message.seq)"
        case .ask(let ask): return ask.id
        }
    }

    public var ts: Date {
        switch self {
        case .message(let message): return message.ts
        case .ask(let ask): return ask.ts
        }
    }
}

extension GroupTimeline {
    /// What a message's bubble shows: its text, led by `@name` for each addressee the text does
    /// not already tag — so an answer logged "to @member" reads that way in the window too.
    public static func displayText(_ message: GroupMessage, names: [UUID: String]) -> String {
        guard case .members(let ids) = message.target else { return message.text }
        let handles = ids.compactMap { id in names[id].map { GroupMention.Handle(id: id, name: $0) } }
        let tagged = Set(GroupMention.parse(message.text, handles: handles).ids)
        let missing = handles.filter { !tagged.contains($0.id) }.map { "@" + $0.name }
        return missing.isEmpty ? message.text : missing.joined(separator: " ") + " " + message.text
    }
}

/// Ledger records + group membership → the group window's timeline. Pure.
public enum GroupAsks {
    /// The member's questions, answered or not, folded from its ledger the way its tab folds them.
    public static func asks(member: UUID, ledger: [ChatEvent]) -> [GroupAsk] {
        ChatFolder.fold(ledger).items.compactMap { item in
            guard case let .ask(id, questions, ts, open) = item, let when = ChatHistory.date(ts) else { return nil }
            return GroupAsk(member: member, ledgerID: id, ts: when, questions: questions, open: open)
        }
    }

    /// The group's messages with its members' questions merged in by time (a message and a
    /// question at the same instant: the message first). `ledgers` maps member keys to their
    /// ledger events; a key that is not a member of `group` contributes nothing.
    ///
    /// An answered question older than the group's first message predates the group and is
    /// left out; an open one always shows, since the group is a place to answer it.
    public static func timeline(group: ChatGroup, messages: [GroupMessage],
                                ledgers: [UUID: [ChatEvent]]) -> [GroupTimelineItem] {
        let since = messages.first?.ts
        let asks = group.members
            .flatMap { member in asks(member: member, ledger: ledgers[member] ?? []) }
            .filter { ask in ask.open || since.map { ask.ts >= $0 } ?? false }
        // Reactions are drawn on the message they are on (`GroupReaction.chips`), not as rows.
        let items = messages.filter { !$0.isReaction }.map(GroupTimelineItem.message) + asks.map(GroupTimelineItem.ask)
        return items.enumerated()
            .sorted { l, r in l.element.ts == r.element.ts ? l.offset < r.offset : l.element.ts < r.element.ts }
            .map(\.element)
    }

    /// Day dividers over the merged timeline: the ids of the first item of each calendar day.
    public static func dayBreaks(_ items: [GroupTimelineItem], calendar: Calendar = .current) -> Set<String> {
        var breaks: Set<String> = []
        var previous: Date?
        for item in items {
            if previous.map({ !calendar.isDate($0, inSameDayAs: item.ts) }) ?? true { breaks.insert(item.id) }
            previous = item.ts
        }
        return breaks
    }
}
