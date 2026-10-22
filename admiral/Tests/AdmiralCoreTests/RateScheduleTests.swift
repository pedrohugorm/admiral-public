import XCTest
@testable import AdmiralCore

final class RateScheduleTests: XCTestCase {
    /// A burst of requests all arriving at the same instant are handed out one per
    /// `minInterval` — so N gh calls launched at once are spaced to `maxRequestsPerSecond`.
    func testSpacesSimultaneousReservationsByMinInterval() {
        var s = RateSchedule(minInterval: 0.5)   // 2 req/s
        XCTAssertEqual(s.reserve(now: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.reserve(now: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.reserve(now: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.reserve(now: 0), 1.5, accuracy: 1e-9)
    }

    /// After an idle gap longer than the interval, the next request waits nothing —
    /// the limiter doesn't accumulate a backlog when traffic is sparse.
    func testIdleRequestWaitsNothing() {
        var s = RateSchedule(minInterval: 0.5)
        _ = s.reserve(now: 0)                                  // next slot → 0.5
        XCTAssertEqual(s.reserve(now: 10), 0.0, accuracy: 1e-9) // 10 > 0.5 → no wait
        XCTAssertEqual(s.reserve(now: 10), 0.5, accuracy: 1e-9) // and the next is spaced again
    }

    /// When GitHub reports a rate limit, `penalize` pushes the next allowed slot out by the
    /// cooldown, so everything queued behind it backs off.
    func testPenaltyPushesNextSlotOutByCooldown() {
        var s = RateSchedule(minInterval: 0.5)
        _ = s.reserve(now: 0)                     // next → 0.5
        s.penalize(now: 0, cooldown: 60)          // next → max(0.5, 60) = 60
        XCTAssertEqual(s.reserve(now: 1), 59.0, accuracy: 1e-9)  // slot 60, now 1 → wait 59
    }

    /// A zero/negative rate disables spacing (never wait) rather than dividing by zero.
    func testZeroRateNeverWaits() {
        var s = RateSchedule(minInterval: 0)
        XCTAssertEqual(s.reserve(now: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.reserve(now: 0), 0.0, accuracy: 1e-9)
    }
}
