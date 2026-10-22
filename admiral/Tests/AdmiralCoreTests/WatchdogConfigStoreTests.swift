import XCTest
@testable import AdmiralCore

final class WatchdogConfigStoreTests: XCTestCase {
    func testDefaultWhenEmptyAndRoundTrip() {
        let defaults = UserDefaults(suiteName: "wd-config-tests")!
        defaults.removePersistentDomain(forName: "wd-config-tests")
        let store = WatchdogConfigStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)

        var config = WatchdogConfig.default
        config.enabled = true
        config.idleThresholdMinutes = 10
        config.rules.append(WatchRule(trigger: "/exam-loop", probeTemplate: "p", nagTemplate: "n"))
        store.save(config)
        XCTAssertEqual(WatchdogConfigStore(defaults: defaults).load(), config)
    }
}
