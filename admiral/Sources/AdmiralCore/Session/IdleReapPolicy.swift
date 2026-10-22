import Foundation

/// Decides which scratch tabs are due for removal. Pure — `now` and the open-goals set
/// are parameters — so the threshold and guards are unit-testable without a clock or disk.
public enum IdleReapPolicy {
    /// 30 minutes with no output change and no programmatic input.
    public static let idleThreshold: TimeInterval = 30 * 60

    /// Sessions to reap: scratch, not currently selected, not busy, no open goals (all
    /// met/cancelled, or none set), and inactive for `threshold`. A session with no
    /// activity stamp yet falls back to its spawn time (a stampless session with no spawn
    /// time is never reaped).
    public static func reapable(
        sessions: [AgentSession], selectedID: UUID?, withOpenGoals: Set<UUID>, now: Date,
        threshold: TimeInterval = idleThreshold
    ) -> [UUID] {
        sessions.filter { s in
            guard s.scratch, s.id != selectedID, s.status != .busy,
                  !withOpenGoals.contains(s.id) else { return false }
            guard let last = s.lastActivityAt ?? s.spawnedAt else { return false }
            return now.timeIntervalSince(last) >= threshold
        }.map(\.id)
    }
}
