import Foundation

/// In-memory reply-obligation store, mirroring the Python SQLite inbox semantics:
/// a hail enrolls a pending obligation; a valid reply closes it.
public final class Inbox {
    public struct Obligation: Equatable, Sendable {
        public let msgID: String
        public let from: String
        public let to: String
        public var answered: Bool
    }

    private var byID: [String: Obligation] = [:]

    public init() {}

    public func enroll(msgID: String, from: String, to: String) {
        byID[msgID] = Obligation(msgID: msgID, from: from, to: to, answered: false)
    }

    public func pending(to: String) -> [Obligation] {
        byID.values
            .filter { !$0.answered && $0.to.caseInsensitiveCompare(to) == .orderedSame }
            .sorted { $0.msgID < $1.msgID }
    }

    @discardableResult
    public func markAnswered(_ msgID: String) -> Bool {
        guard var obligation = byID[msgID] else { return false }
        obligation.answered = true
        byID[msgID] = obligation
        return true
    }
}
