import Foundation

/// Who a message reaches and when.
public struct GroupRouting: Equatable, Sendable {
    /// Idle members: typed to now.
    public var wake: [UUID] = []
    /// Busy members: they keep one pending wake and get it when their turn ends.
    public var pending: [UUID] = []
    /// Members whose claude is not running (tab back at its shell): nothing can be typed.
    public var unreachable: [UUID] = []
}

/// Pure routing, so the rules are testable without a session in sight.
///
/// The sender is never a recipient. A paused group wakes nobody (the message is still logged).
/// An untagged message goes to every member; `@name` narrows it to those members.
public enum GroupRouter {
    public static func route(members: [UUID], sender: UUID?, target: GroupMessage.Target,
                             paused: Bool, status: (UUID) -> SessionStatus) -> GroupRouting {
        guard !paused else { return GroupRouting() }
        let named: [UUID]
        switch target {
        case .everyone: named = members
        case .members(let ids): named = members.filter(ids.contains)
        }
        var routing = GroupRouting()
        for id in named where id != sender {
            switch status(id) {
            case .idle: routing.wake.append(id)
            case .busy: routing.pending.append(id)
            case .shell, .unknown: routing.unreachable.append(id)
            }
        }
        return routing
    }
}
