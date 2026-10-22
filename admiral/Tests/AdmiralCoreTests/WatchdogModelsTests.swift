import XCTest
@testable import AdmiralCore

final class WatchdogModelsTests: XCTestCase {
    func testConfigDefaults() {
        let c = WatchdogConfig.default
        XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.idleThresholdMinutes, 5)
        XCTAssertEqual(c.probeTimeoutMinutes, 3)
        XCTAssertEqual(c.rules, [WatchRule.seeded])
        XCTAssertTrue(WatchRule.seeded.trigger.contains("/drive-ticket to PROD"))
    }

    func testStateDefaultsAndRoundTrip() throws {
        var s = WatchdogState()
        XCTAssertEqual(s.phase, .disarmed)
        XCTAssertTrue(s.sessionEnabled)
        XCTAssertEqual(s.cycles, 0)
        s.phase = .probing
        s.trigger = "/drive-ticket to PROD"
        s.lastAnswer = WatchdogAnswer(status: "blocked", reason: "CI")
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(WatchdogState.self, from: data), s)
    }
}
