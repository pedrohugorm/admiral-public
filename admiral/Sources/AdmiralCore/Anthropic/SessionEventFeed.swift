import Foundation

/// One thing a follower of `GET /sessions/<callsign>/events` is told.
public enum FeedEvent: Equatable, Sendable {
    case prompt(id: String, text: String)
    case message(id: String, text: String)
    case tool(id: String, name: String, state: ToolState, params: String, result: String?)
    case status(SessionStatus)
    /// The turn ended. `turnID` is the assistant message carrying the final reply.
    case stop(turnID: String, text: String)
    /// One turn's answer to the tab's output schema (`round` counts turns): `fulfilled` with
    /// the validated `result`, or `failed` once the budget ran out. `at` is when it settled, `turn`
    /// the turn part of the event's SSE id (the last turn the feed had reached), `violations` why
    /// a failed round failed (empty when fulfilled) and `callsign` the tab it belongs to.
    /// `redacted` means `result` is the `admiral` mod's PHI-redacted copy (Settings → Bridge &
    /// API); a round the mod could not redact goes out `failed` with a null result.
    case output(round: Int, fulfilled: Bool, result: JSONValue?,
                at: Date? = nil, turn: String? = nil, violations: [String] = [], callsign: String? = nil,
                redacted: Bool = false)

    /// The SSE `event:` name.
    public var name: String {
        switch self {
        case .prompt: "prompt"
        case .output: "output"
        case .message: "message"
        case .tool: "tool"
        case .status: "status"
        case .stop: "stop"
        }
    }

    /// The turn part of the SSE `id:`; `SessionEventFeed` adds the output-round count. Status
    /// and output have none of their own (status is re-announced on connect).
    public var sseID: String? {
        switch self {
        case let .prompt(id, _), let .message(id, _), let .tool(id, _, _, _, _): id
        case let .stop(turnID, _): turnID + SessionEventFeed.stopSuffix
        case .status, .output: nil
        }
    }

    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    /// The SSE `data:` — one line of JSON, keys sorted so the bytes are stable.
    public var data: Data {
        let body: [String: Any]
        switch self {
        case let .prompt(_, text), let .message(_, text), let .stop(_, text):
            body = ["text": text]
        case let .output(round, fulfilled, result, at, turn, violations, callsign, redacted):
            let resultObject = result.flatMap { try? JSONEncoder().encode($0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            body = ["round": round, "status": fulfilled ? "fulfilled" : "failed",
                    "result": resultObject ?? NSNull(),
                    "at": at.map { Self.iso8601.string(from: $0) } as Any? ?? NSNull(),
                    "turn": turn as Any? ?? NSNull(),
                    "violations": fulfilled ? [] : violations,
                    "callsign": callsign as Any? ?? NSNull(),
                    "redacted": redacted]
        case let .tool(_, name, state, params, result):
            body = ["name": name, "state": state.rawValue, "params": params,
                    "result": result as Any? ?? NSNull()]
        case let .status(status):
            body = ["status": status.rawValue]
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// One output round's PHI-redacted copy, as the `admiral` mod wrote it (`output-<round>.json`):
/// the round's outcome with every string in `result` redacted. `failed` means the model could
/// not redact it, so the round goes out failed with no result — nothing raw is sent.
public struct RedactedOutput: Codable, Equatable, Sendable {
    public var round: Int
    public var status: StructuredOutputState.Status
    public var result: JSONValue?
    public var completedAt: Date?
    public var violations: [String]?
    public var failed: Bool

    public init(round: Int, status: StructuredOutputState.Status, result: JSONValue? = nil,
                completedAt: Date? = nil, violations: [String]? = nil, failed: Bool = false) {
        self.round = round
        self.status = status
        self.result = result
        self.completedAt = completedAt
        self.violations = violations
        self.failed = failed
    }

    static let redactionFailed = "the PHI redaction of this round's result failed"
}

/// An event with the full SSE `id:` it goes out under.
public struct FeedFrame: Equatable, Sendable {
    public let event: FeedEvent
    public let id: String?
}

/// Turns successive reads of one session (its transcript tail, status, and its output rounds)
/// into the events a follower has not seen yet. Pure — every ordering, de-dup, stop and resume
/// rule lives here, so they are tested without a socket or a clock.
///
/// - Turns go out in transcript order, each once. Thinking is skipped. A tool call waits
///   until it leaves `running`, so its result rides along and nothing is ever re-sent; the
///   turns after it wait too, keeping the order.
/// - `stop` goes out once per finished turn: the session reads idle and either was just seen
///   busy, or its last assistant message arrived in this same read (a turn fast enough to
///   slip a poll). It carries that last assistant message.
/// - Each finished round of the tab's output schema (fulfilled or failed) goes out once as
///   `output`, after the turn events of the same read. A fresh connect skips rounds already done.
///   With redaction on (`redacted` non-nil) a round goes out only from its redacted copy, once
///   the mod has written it — the live slot's raw result is never sent.
/// - Every id is `<turn part>`, plus `~o<rounds sent>` once an output round has gone out, so
///   `Last-Event-ID` resumes both: nothing is missed or repeated.
public struct SessionEventFeed: Sendable {
    public static let stopSuffix = "#stop"
    /// Ids from before redaction moved to output rounds carried a redacted-copy count; a
    /// resume strips it.
    static let legacyCopiesMark = "~r"
    static let roundsMark = "~o"

    private enum Cursor: Sendable, Equatable {
        /// First read: skip history, start at the current end.
        case end
        /// Nothing was settled at connect (empty transcript): every turn is new.
        case beginning
        /// Everything after this turn id is unsent.
        case after(String)
    }

    private var cursor: Cursor
    private var lastStatus: SessionStatus?
    /// The last output round sent; nil until the first read of a fresh connect sets it.
    private var roundsSent: Int?
    /// The tab's callsign, echoed on `output` events.
    private let callsign: String?

    /// `lastEventID` is the client's `Last-Event-ID`: nil starts at the current end; otherwise
    /// `<turn part>[~o<m>]` resumes after that turn and output round `m` (0 when absent). The
    /// turn part is a turn id, or `<turn id>#stop` (resumes after that turn, so the stop is not
    /// repeated: it only fires for a reply sent in the same read, or on a busy → idle seen), or
    /// empty.
    public init(lastEventID: String? = nil, callsign: String? = nil) {
        self.callsign = callsign
        guard var raw = lastEventID?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            cursor = .end
            return
        }
        if let mark = raw.range(of: Self.roundsMark, options: .backwards),
           let m = Int(raw[mark.upperBound...]) {
            roundsSent = m
            raw = String(raw[..<mark.lowerBound])
        }
        if let mark = raw.range(of: Self.legacyCopiesMark, options: .backwards),
           Int(raw[mark.upperBound...]) != nil {
            roundsSent = roundsSent ?? 0
            raw = String(raw[..<mark.lowerBound])
        }
        if raw.hasSuffix(Self.stopSuffix) { raw.removeLast(Self.stopSuffix.count) }
        cursor = raw.isEmpty ? .end : .after(raw)
    }

    /// The events alone — what most callers and tests compare.
    public mutating func step(turns: [Turn], status: SessionStatus,
                              output: StructuredOutputState? = nil,
                              redacted: [RedactedOutput]? = nil) -> [FeedEvent] {
        frames(turns: turns, status: status, output: output, redacted: redacted).map(\.event)
    }

    /// The events with their SSE ids, as the endpoint sends them. `output` is the tab's
    /// `output` slot as it stands (nil for a tab without an output schema). `redacted` is the
    /// mod's redacted copies of its rounds, or nil with redaction off; when set, rounds go out
    /// from these copies only.
    public mutating func frames(turns: [Turn], status: SessionStatus,
                                output: StructuredOutputState? = nil,
                                redacted: [RedactedOutput]? = nil) -> [FeedFrame] {
        let isConnect = cursor == .end
        if roundsSent == nil {
            // A fresh connect has already "seen" every round that is over.
            let round = output?.round ?? 0
            roundsSent = isConnect ? (output?.status == .armed ? round - 1 : round) : 0
        }
        var events: [FeedEvent] = []
        let start: Int
        switch cursor {
        case .end:
            // Start after the last settled turn: a tool still running at the end is sent when
            // it finishes rather than skipped as history.
            var last = turns.count - 1
            while last >= 0, case let .tool(_, _, _, _, state) = turns[last], state == .running { last -= 1 }
            start = last + 1
            cursor = last >= 0 ? .after(turns[last].id) : .beginning
            lastStatus = status  // a connect is not a transition
        case .beginning:
            start = 0
        case let .after(id):
            // An id that left the tail (or never existed) replays the whole tail.
            start = (turns.firstIndex { $0.id == id }).map { $0 + 1 } ?? 0
        }

        var sent = Set<String>()
        for turn in turns[min(start, turns.count)...] {
            // A running tool holds the line: it and everything after it wait for its result.
            if case let .tool(_, _, _, _, state) = turn, state == .running { break }
            let event: FeedEvent?
            switch turn {
            case let .user(_, text): event = .prompt(id: turn.id, text: text)
            case let .assistant(_, markdown, _): event = .message(id: turn.id, text: markdown)
            case .thinking: event = nil
            case let .tool(_, name, params, result, state):
                event = .tool(id: turn.id, name: name, state: state, params: params, result: result)
            }
            if let event { events.append(event); sent.insert(turn.id) }
            cursor = .after(turn.id)
        }

        if let previous = lastStatus, previous != status { events.append(.status(status)) }
        if status == .idle, let reply = Self.lastAssistant(in: turns),
           lastStatus == .busy || sent.contains(reply.id) {
            events.append(.stop(turnID: reply.id, text: reply.text))
        }
        lastStatus = status

        // Ids: each event's own turn part (the cursor's for one without), then the counters.
        var frames: [FeedFrame] = []
        var turnPart: String = {
            if case let .after(id) = cursor { return id } else { return "" }
        }()
        var rounds = roundsSent ?? 0
        func counters() -> String {
            rounds > 0 ? Self.roundsMark + String(rounds) : ""
        }
        for event in events {
            if let own = event.sseID { turnPart = own }
            frames.append(FeedFrame(event: event, id: event.sseID.map { $0 + counters() }))
        }
        var turn = turnPart
        if turn.hasSuffix(Self.stopSuffix) { turn.removeLast(Self.stopSuffix.count) }
        for round in Self.finishedRounds(output: output, redacted: redacted) where round.round > rounds {
            rounds = round.round
            frames.append(FeedFrame(
                event: .output(round: round.round, fulfilled: round.fulfilled, result: round.result,
                               at: round.at, turn: turn.isEmpty ? nil : turn,
                               violations: round.fulfilled ? [] : round.violations,
                               callsign: callsign, redacted: redacted != nil),
                id: turnPart + counters()))
        }
        roundsSent = rounds
        return frames
    }

    private struct FinishedRound {
        let round: Int
        let fulfilled: Bool
        let result: JSONValue?
        let at: Date?
        let violations: [String]
    }

    /// The rounds that may go out, oldest first. With redaction off, the live slot once it has
    /// left `armed`. With it on, only the mod's copies — so a round waits for its copy, and a
    /// round the mod could not redact goes out failed with no result.
    private static func finishedRounds(output: StructuredOutputState?,
                                       redacted: [RedactedOutput]?) -> [FinishedRound] {
        guard let redacted else {
            guard let output, let round = output.round, output.status != .armed else { return [] }
            return [FinishedRound(round: round, fulfilled: output.status == .fulfilled,
                                  result: output.result, at: output.completedAt,
                                  violations: output.violations ?? [])]
        }
        return redacted.filter { $0.status != .armed }.sorted { $0.round < $1.round }.map { copy in
            let fulfilled = copy.status == .fulfilled && !copy.failed
            return FinishedRound(round: copy.round, fulfilled: fulfilled,
                                 result: fulfilled ? copy.result : nil, at: copy.completedAt,
                                 violations: copy.failed ? [RedactedOutput.redactionFailed]
                                                         : (copy.violations ?? []))
        }
    }

    private static func lastAssistant(in turns: [Turn]) -> (id: String, text: String)? {
        for turn in turns.reversed() {
            if case let .assistant(_, markdown, _) = turn { return (turn.id, markdown) }
        }
        return nil
    }
}
