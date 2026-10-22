// admiral/App/UITests/APIServerUITests.swift
import XCTest

/// The sidebar API Server toggle: off → click → the row shows the bound port and a
/// second click turns it back off. Reads only the accessibility tree. Launch args
/// follow CommissionUITests: a cheap -uiTestExecutable so no real claude spawns,
/// and no persisted state leaks in (the enabled flag defaults to off in a fresh
/// UserDefaults? No — .standard persists; the test therefore ends OFF to self-clean).
final class APIServerUITests: XCTestCase {
    func testToggleStartsAndStopsServer() throws {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("api-ui-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

        let app = XCUIApplication.isolated()
        app.launchArguments = ["-uiTestExecutable", "/bin/cat", "-uiTestCwd", tmp]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)

        let toggle = app.descendants(matching: .any).matching(identifier: "api-server-toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "API server toggle should exist")

        func labelShowsPort(after deadline: TimeInterval, expected: Bool) -> Bool {
            let end = Date().addingTimeInterval(deadline)
            while Date() < end {
                if toggle.label.contains(":") == expected { return true }
                Thread.sleep(forTimeInterval: 0.3)
            }
            return toggle.label.contains(":") == expected
        }

        // Ensure OFF baseline (a previous run may have persisted the enabled flag).
        if toggle.label.contains(":") {
            app.activate(); toggle.click()
            XCTAssertTrue(labelShowsPort(after: 10, expected: false), "baseline off: \(toggle.label)")
        }

        // First click may only focus the window (macOS quirk) — click until state changes.
        for _ in 0..<4 where !toggle.label.contains(":") {
            app.activate()
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCTAssertTrue(labelShowsPort(after: 10, expected: true), "label should show port: \(toggle.label)")

        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(labelShowsPort(after: 10, expected: false), "should be off again: \(toggle.label)")
    }
}
