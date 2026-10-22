import Foundation

/// Where a goal ended up. Three states rather than a `done` flag, because "no longer
/// applies" is a real outcome and is not the same as "achieved" — collapsing them is how a
/// goal quietly disappears without anyone deciding it should.
public enum GoalStatus: String, Codable, Sendable {
    case open, met, cancelled

    /// The nudge's probe answers in booleans (met / not yet) — it has no way to say "no
    /// longer applies", which is what `update_goals` is for. One mapping site, so the
    /// probe and the tool cannot drift on what a `true` means.
    public static func statuses(fromDone completions: [String: Bool]) -> [String: GoalStatus] {
        completions.mapValues { $0 ? .met : .open }
    }
}

/// One goal on a session: a short completion condition the session is expected to meet.
public struct SessionGoal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var text: String
    public var status: GoalStatus
    /// When it stopped being open (met or cancelled).
    public var resolvedAt: Date?

    public var done: Bool { status == .met }
    /// Cancelled goals stay in the file as a record but leave the panel and the reminder.
    public var isVisible: Bool { status != .cancelled }

    public init(id: String, text: String, status: GoalStatus = .open, resolvedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.resolvedAt = resolvedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, status, resolvedAt
        case done, completedAt   // pre-status files
    }

    /// Decodes both shapes: a file written before goals had statuses stores `done`/`completedAt`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        if let status = try container.decodeIfPresent(GoalStatus.self, forKey: .status) {
            self.status = status
        } else {
            self.status = (try container.decodeIfPresent(Bool.self, forKey: .done) ?? false) ? .met : .open
        }
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
            ?? container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
    }
}

/// Why a proposed goal list was refused. The messages are what the caller sees at the MCP
/// tool boundary, so they name the offending goal rather than just the rule.
public enum GoalError: Error, Equatable {
    case tooMany(count: Int)
    case tooLong(index: Int, count: Int)
    case blank(index: Int)
    /// Replacing the list would drop these while they are still open.
    case wouldDropOpenGoals([SessionGoal])

    public var message: String {
        switch self {
        case let .tooMany(count):
            return "too many goals (\(count)) — keep it to \(SessionGoals.maxCount) or fewer; "
                + "a longer list is a plan, and the task list already shows that"
        case let .tooLong(index, count):
            return "goal \(index + 1) is \(count) characters — keep each goal to "
                + "\(SessionGoals.maxLength) or fewer"
        case let .blank(index):
            return "goal \(index + 1) is blank"
        case let .wouldDropOpenGoals(dropped):
            let list = dropped.map { "  \($0.id)) \($0.text)" }.joined(separator: "\n")
            let it = dropped.count == 1 ? "it" : "them"
            // Naming the way OUT comes before the reason, and the easy way first. A session
            // told only to resolve-then-replace concludes it cannot add a goal at all while
            // any is open, and carries the new one in its head instead — which is the one
            // outcome this refusal was never meant to cause.
            return "refusing: \(dropped.count) goal\(dropped.count == 1 ? " is" : "s are") still "
                + "open and this list would drop \(it) silently:\n\(list)\n"
                + "If you meant to ADD, call `add_goals` with only the new ones — it never "
                + "touches these. If you meant to REPLACE, say what happened to \(it) first: "
                + "`update_goals` with each id in `done` (achieved) or `cancelled` (no longer "
                + "applies), then set the new list. Restating \(it) in the list you send also "
                + "works — the refusal only fires when an open goal would vanish."
        }
    }
}

/// A session's goals. Setting goals replaces the list wholesale — goals are a directive,
/// not a backlog — but a replacement may not quietly drop one that is still open.
public struct SessionGoals: Codable, Equatable, Sendable {
    /// Tweet-sized. Long enough for a real completion condition, short enough to read in
    /// a 280px panel at a glance.
    public static let maxLength = 280
    public static let maxCount = 10

    public var goals: [SessionGoal]
    public var setAt: Date

    public init(goals: [SessionGoal], setAt: Date) {
        self.goals = goals
        self.setAt = setAt
    }

    /// The one place a caller's strings become goals: normalize, refuse what doesn't fit,
    /// and hand back a numbered list. Every entry point (MCP tool, tests) goes through it,
    /// so the limits cannot drift between them.
    ///
    /// An empty list is valid and means "clear this session's goals".
    public static func make(from texts: [String], now: Date = Date()) -> Result<SessionGoals, GoalError> {
        guard texts.count <= maxCount else { return .failure(.tooMany(count: texts.count)) }
        var goals: [SessionGoal] = []
        for (index, raw) in texts.enumerated() {
            let text = normalized(raw)
            guard !text.isEmpty else { return .failure(.blank(index: index)) }
            guard text.count <= maxLength else {
                return .failure(.tooLong(index: index, count: text.count))
            }
            goals.append(SessionGoal(id: "g\(index + 1)", text: text))
        }
        return .success(SessionGoals(goals: goals, setAt: now))
    }

    /// Build the list that replaces `existing`.
    ///
    /// Refuses when an open goal would vanish — the caller has to decide whether it was met
    /// or no longer applies, rather than letting a new directive erase the old one. Goals
    /// carried over keep the outcome they already had, so re-stating a list you have partly
    /// finished doesn't reopen the finished half.
    ///
    /// Identity is `sameGoal`, not `==`, because the caller restating a list is a language
    /// model and it paraphrases: it resends a goal with the evidence clause trimmed off the
    /// end and, under exact matching, that reads as a goal deleted. The refusal then fires on
    /// the one caller doing exactly what it was told to do.
    public static func replacing(_ existing: SessionGoals?, with texts: [String],
                                 now: Date = Date()) -> Result<SessionGoals, GoalError> {
        guard case var .success(fresh) = make(from: texts, now: now) else {
            return make(from: texts, now: now)
        }
        guard let existing else { return .success(fresh) }

        let dropped = existing.goals.filter { previous in
            previous.status == .open && !fresh.goals.contains { sameGoal($0.text, previous.text) }
        }
        guard dropped.isEmpty else { return .failure(.wouldDropOpenGoals(dropped)) }

        for index in fresh.goals.indices {
            guard let previous = existing.goals.first(where: { sameGoal($0.text, fresh.goals[index].text) })
            else { continue }
            fresh.goals[index].status = previous.status
            fresh.goals[index].resolvedAt = previous.resolvedAt
        }
        return .success(fresh)
    }

    /// Append `texts` to `existing`, skipping any that name a goal already there. Nothing is
    /// dropped, so this can never be refused — which is the point: "add a goal" is a request
    /// in its own right, and making it go through a full restatement of the list is what
    /// turns it into an argument about what the other goals said.
    public static func adding(_ texts: [String], to existing: SessionGoals?,
                              now: Date = Date()) -> Result<SessionGoals, GoalError> {
        let kept = existing?.goals ?? []
        let fresh = texts.map(normalized).filter { candidate in
            !candidate.isEmpty && !kept.contains { sameGoal($0.text, candidate) }
        }
        switch make(from: kept.map(\.text) + fresh, now: existing?.setAt ?? now) {
        case var .success(merged):
            // Re-numbering is positional, and the kept goals lead, so their ids never move.
            for index in kept.indices {
                merged.goals[index].status = kept[index].status
                merged.goals[index].resolvedAt = kept[index].resolvedAt
            }
            return .success(merged)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Do two texts name the same goal?
    ///
    /// Exact after normalization, or agreeing on the first 80% of the shorter one. A restated
    /// goal keeps its opening and loses or reworks the tail — "…and reads back with its
    /// 123-question shape intact" comes back as "…and reads back intact" — so the head is
    /// what survives paraphrase and the tail is what does not. Strings under 24 characters
    /// must match exactly, which keeps "ship it" and "ship it to prod" two goals.
    ///
    /// It errs toward calling them the same. A false merge quietly absorbs one goal; a false
    /// split refuses a caller that did exactly what it was told, which is the failure this
    /// exists to end.
    static func sameGoal(_ a: String, _ b: String) -> Bool {
        let x = comparable(a), y = comparable(b)
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard short.count >= 24 else { return false }
        let shared = zip(short, long).prefix { $0 == $1 }.count
        return Double(shared) >= 0.8 * Double(short.count)
    }

    private static func comparable(_ text: String) -> String {
        String(normalized(text).lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }).split(separator: " ").joined(separator: " ")
    }

    /// A goal is injected on one prompt line — the nudge's probe and nag list goals inline —
    /// so a newline inside it would submit early.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { goals.isEmpty }
    /// Everything a reader should see — cancelled goals are kept as a record, not shown.
    public var visible: [SessionGoal] { goals.filter(\.isVisible) }
    public var outstanding: [SessionGoal] { goals.filter { $0.status == .open } }
    /// True only when there was something to meet and all of it is met. A list that was
    /// entirely cancelled is finished, but nobody achieved anything — don't congratulate it.
    public var isComplete: Bool { !visible.isEmpty && outstanding.isEmpty }

    /// "1 / 3" — met over the goals that still count (cancelled ones drop out of both).
    public var progress: (done: Int, total: Int) {
        let visible = self.visible
        return (visible.filter(\.done).count, visible.count)
    }

    /// Merge an outcome per goal id. Ids the list doesn't know are ignored, so a stale answer
    /// that arrives after the goals were replaced cannot resurrect them. Returns how many
    /// goals actually changed, which is what tells the caller whether anything moved.
    @discardableResult
    public mutating func apply(statuses: [String: GoalStatus], now: Date = Date()) -> Int {
        var changed = 0
        for index in goals.indices {
            guard let status = statuses[goals[index].id], status != goals[index].status else { continue }
            goals[index].status = status
            goals[index].resolvedAt = status == .open ? nil : now
            changed += 1
        }
        return changed
    }
}
