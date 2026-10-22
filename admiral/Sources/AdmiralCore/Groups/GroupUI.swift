import Foundation

// The group window's and sidebar's decisions, pure so `swift test` covers them. The views in
// App only draw what these return.

/// The one word the group's working capsule shows, changing every `period` seconds.
public enum GroupWorkingWords {
    public static let words = ["Pondering", "Cogitating", "Noodling", "Percolating", "Simmering",
                               "Tinkering", "Untangling", "Mulling", "Brewing", "Ruminating",
                               "Spelunking", "Marinating"]
    public static let period: TimeInterval = 2.8

    /// Which word shows `elapsed` seconds after the capsule appeared: the first for a full
    /// period, then the next, wrapping.
    public static func index(elapsed: TimeInterval, period: TimeInterval = period) -> Int {
        // In whole milliseconds, so 12 × 2.8 s lands on the 13th tick and not a hair before it.
        let ms = Int((elapsed * 1000).rounded()), step = Int((period * 1000).rounded())
        guard ms > 0, step > 0 else { return 0 }
        return (ms / step) % words.count
    }

    public static func word(elapsed: TimeInterval, period: TimeInterval = period) -> String {
        words[index(elapsed: elapsed, period: period)] + "…"
    }

    /// ChatView's elapsed format: "42s", then "1m 05s".
    public static func elapsedLabel(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(String(format: "%02d", s % 60))s"
    }
}

/// The `@` picker above the group composer: when it opens, what it lists, and what picking
/// one does to the text.
public enum GroupMentionPicker {
    /// What is being typed after an `@` at the end of the text.
    public struct Query: Equatable, Sendable {
        /// Character offset of the `@`.
        public let offset: Int
        /// The letters typed after it (may be empty).
        public let partial: String
    }

    public struct Candidate: Equatable, Sendable {
        public let name: String
        /// nil = the `all` row.
        public let id: UUID?
        public init(name: String, id: UUID?) { self.name = name; self.id = id }
        public var isAll: Bool { id == nil }
    }

    /// The open query: the text ends in `@` + handle characters, and that `@` starts a word.
    /// The composer has no caret position to read, so the picker follows the end of the text.
    public static func query(in text: String) -> Query? {
        let chars = Array(text)
        var i = chars.count
        while i > 0, isHandleChar(chars[i - 1]) { i -= 1 }
        guard i > 0, chars[i - 1] == "@" else { return nil }
        let at = i - 1
        guard at == 0 || chars[at - 1].isWhitespace || "([{\"'".contains(chars[at - 1]) else { return nil }
        return Query(offset: at, partial: String(chars[i...]))
    }

    /// Members whose callsign starts with the partial first, then those containing it, in
    /// member order; `all` last when it matches. Case-insensitive.
    public static func candidates(_ partial: String, members: [Candidate]) -> [Candidate] {
        let p = partial.lowercased()
        guard !p.isEmpty else { return members + [Candidate(name: "all", id: nil)] }
        let prefix = members.filter { $0.name.lowercased().hasPrefix(p) }
        let inside = members.filter { !$0.name.lowercased().hasPrefix(p) && $0.name.lowercased().contains(p) }
        let all = "all".hasPrefix(p) ? [Candidate(name: "all", id: nil)] : []
        return prefix + inside + all
    }

    /// The text with the query replaced by `@name ` — ready for the next word.
    public static func insert(_ name: String, into text: String, at query: Query) -> String {
        String(Array(text)[..<query.offset]) + "@" + name + " "
    }

    /// ↑/↓ in the list, wrapping.
    public static func move(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    private static func isHandleChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "."
    }
}

/// The sidebar group tile: a 2×2 of member avatars.
public enum GroupTile {
    public static let capacity = 4

    /// Exactly four cells: the first four members in order, nil for the empty ones.
    public static func cells<T>(_ members: [T]) -> [T?] {
        let shown: [T?] = members.prefix(capacity).map { $0 }
        return shown + Array(repeating: nil, count: capacity - shown.count)
    }
}

/// Dropping a dragged sidebar row on another: the edge bands reorder (as before groups); the
/// middle band of a TAB row, with a TAB dragged onto it, proposes a new group of the two.
public enum SidebarDropZone: Equatable, Sendable {
    case reorder
    case group

    public static let band: ClosedRange<Double> = 0.3...0.7

    /// `y` is from the row's top. Flag off, or either side not a tab: always reorder.
    public static func zone(y: Double, height: Double, draggedIsTab: Bool, targetIsTab: Bool,
                            groupsEnabled: Bool) -> SidebarDropZone {
        guard groupsEnabled, draggedIsTab, targetIsTab, height > 0 else { return .reorder }
        let fraction = y / height
        return fraction > band.lowerBound && fraction < band.upperBound ? .group : .reorder
    }
}

/// Which group affordances the sidebar shows. One place decides, so flag off cannot leave a
/// stray row, button or menu item behind.
public enum GroupUIGate {
    public enum FooterAction: Equatable, Sendable {
        case newClaudeCode, newBash, newGroup, apiServer, schedules, settings
    }

    public static func footer(groupsEnabled: Bool, apiServer: Bool) -> [FooterAction] {
        var actions: [FooterAction] = [.newClaudeCode, .newBash]
        if groupsEnabled { actions.append(.newGroup) }
        if apiServer { actions.append(.apiServer) }
        return actions + [.schedules, .settings]
    }

    public enum TabMenuItem: Equatable, Sendable {
        case newGroupWithTab
        /// "Add to group ▸" with these groups (the ones the tab is not in yet).
        case addToGroup([UUID])
    }

    /// The group entries of a tab's context menu.
    public static func tabMenu(groupsEnabled: Bool, member: UUID, groups: [ChatGroup]) -> [TabMenuItem] {
        guard groupsEnabled else { return [] }
        let open = groups.filter { !$0.members.contains(member) }.map(\.id)
        return [.newGroupWithTab] + (open.isEmpty ? [] : [.addToGroup(open)])
    }
}

/// The human's read position per group — "new since you last looked" for the sidebar dot.
/// Kept in the app's defaults, never in the group files the agents' hook reads.
public final class GroupSeenCursor {
    private let defaults: UserDefaults
    private let key = "admiral.groupSeen.v1"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func seen(_ group: UUID) -> Int {
        (defaults.dictionary(forKey: key) as? [String: Int])?[group.uuidString] ?? 0
    }

    /// Never moves backwards.
    public func markSeen(_ group: UUID, through seq: Int) {
        var all = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
        guard seq > (all[group.uuidString] ?? 0) else { return }
        all[group.uuidString] = seq
        defaults.set(all, forKey: key)
    }

    /// Unread: a message the human hasn't seen, written by someone other than the human.
    public static func isUnread(_ messages: [GroupMessage], seen: Int) -> Bool {
        messages.contains { $0.seq > seen && !$0.isHuman && !$0.isReaction }
    }
}

/// The group timeline's day dividers: the first message of each calendar day.
public enum GroupTimeline {
    public static func dayBreaks(_ messages: [GroupMessage], calendar: Calendar = .current) -> Set<Int> {
        var breaks: Set<Int> = []
        var previous: Date?
        for message in messages {
            if previous.map({ !calendar.isDate($0, inSameDayAs: message.ts) }) ?? true { breaks.insert(message.seq) }
            previous = message.ts
        }
        return breaks
    }

    /// The ISO string the chat's time labels take.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }
}
