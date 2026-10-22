import Foundation

/// Pure scheduling policy for a global request rate cap: hand out one "slot" per
/// `minInterval`, so a burst of callers is spaced out instead of firing at once. Time is
/// passed in (seconds, monotonic-ish) so it's fully unit-testable without sleeping.
///
/// Used to keep every `gh` call the app makes — across all tabs — under GitHub's rate limit.
struct RateSchedule {
    /// Seconds between consecutive slots (`1 / maxRequestsPerSecond`); 0 disables spacing.
    let minInterval: TimeInterval
    /// The earliest time the next slot may run. Reservations bump it forward.
    private var nextEarliest: TimeInterval = 0

    init(minInterval: TimeInterval) {
        self.minInterval = max(0, minInterval)
    }

    /// Reserve the next slot and return how long the caller must wait (>= 0) before it runs.
    mutating func reserve(now: TimeInterval) -> TimeInterval {
        let slot = max(now, nextEarliest)
        nextEarliest = slot + minInterval
        return max(0, slot - now)
    }

    /// GitHub reported a rate limit: hold every future slot until at least `now + cooldown`.
    mutating func penalize(now: TimeInterval, cooldown: TimeInterval) {
        nextEarliest = max(nextEarliest, now + cooldown)
    }
}

/// Process-wide async gate that spaces `gh` invocations to a max requests/second and backs off
/// when GitHub signals a rate limit. An actor so concurrent callers from every tab serialize
/// through one shared schedule; the reservation is taken synchronously (before the sleep), so
/// callers queue up without double-booking a slot.
public actor GHRateLimiter {
    private var schedule: RateSchedule
    private let cooldown: TimeInterval

    public init(maxRequestsPerSecond: Double, cooldownOnLimit: TimeInterval = 60) {
        schedule = RateSchedule(minInterval: maxRequestsPerSecond > 0 ? 1 / maxRequestsPerSecond : 0)
        cooldown = cooldownOnLimit
    }

    /// Wait until it's this caller's turn under the global rate cap.
    public func acquire() async {
        let delay = schedule.reserve(now: Date().timeIntervalSinceReferenceDate)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// Signal that the last call came back rate-limited, so queued callers back off.
    public func penalize() {
        schedule.penalize(now: Date().timeIntervalSinceReferenceDate, cooldown: cooldown)
    }
}
