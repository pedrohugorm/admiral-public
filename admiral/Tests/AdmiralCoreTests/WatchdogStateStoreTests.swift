import XCTest
@testable import AdmiralCore

final class WatchdogStateStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "wd-store-tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    func testRoundTripAndRemove() {
        let store = WatchdogStateStore(defaults: defaults)
        XCTAssertNil(store.state(forSession: "sid1"))

        var s = WatchdogState()
        s.phase = .armed
        s.trigger = "/drive-ticket to PROD"
        store.set(s, forSession: "sid1")
        XCTAssertEqual(store.state(forSession: "sid1"), s)
        // A second instance (fresh load) sees the same state — persistence, not cache.
        XCTAssertEqual(WatchdogStateStore(defaults: defaults).state(forSession: "sid1"), s)

        store.set(nil, forSession: "sid1")
        XCTAssertNil(store.state(forSession: "sid1"))
    }

    func testSessionsAreIndependent() {
        let store = WatchdogStateStore(defaults: defaults)
        store.set(WatchdogState(phase: .armed), forSession: "a")
        store.set(WatchdogState(phase: .probing), forSession: "b")
        XCTAssertEqual(store.state(forSession: "a")?.phase, .armed)
        XCTAssertEqual(store.state(forSession: "b")?.phase, .probing)
    }
}
