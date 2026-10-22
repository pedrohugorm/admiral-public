import Foundation

/// How long each session has been continuously idle.
///
/// Shared by every nudge that fires on idleness (the watchdog, the goals nudge) so a session
/// has ONE idle truth rather than two that drift. It is also the arbiter between them: an
/// injection calls `wake`, which restarts the clock, so whichever nudge speaks first this
/// tick puts every other nudge back below its threshold. A session that was just poked is
/// not idle — the arbitration and the semantics are the same rule.
@MainActor
public final class IdleClock {
    private var since: [String: Date] = [:]

    public init() {}

    /// Record this session's status and return its continuous idle time. Only a positive
    /// `.idle` read accumulates; busy or unknown resets the clock.
    @discardableResult
    public func observe(_ sessionID: String, status: SessionStatus, now: Date) -> TimeInterval {
        guard status == .idle else {
            since[sessionID] = nil
            return 0
        }
        let start = since[sessionID] ?? now
        since[sessionID] = start
        return now.timeIntervalSince(start)
    }

    public func idleSeconds(_ sessionID: String, now: Date) -> TimeInterval {
        since[sessionID].map { now.timeIntervalSince($0) } ?? 0
    }

    /// Something was injected into this session — it is no longer idle.
    public func wake(_ sessionID: String) {
        since[sessionID] = nil
    }

    /// Drop bookkeeping for sessions that are gone.
    public func keepOnly(_ live: Set<String>) {
        since = since.filter { live.contains($0.key) }
    }
}
