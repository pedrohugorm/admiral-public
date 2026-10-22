import XCTest

/// Automated end-to-end test of the exact flow that was broken: clicking the real
/// Commission button must spawn a session that appears in the sidebar. A cheap
/// executable (`/bin/cat`) and a fixed directory are injected so no file picker and
/// no real `claude` are needed.
final class CommissionUITests: XCTestCase {
    func testCommissionButtonAddsSessionRow() throws {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("admiral-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let base = (tmp as NSString).lastPathComponent

        let app = XCUIApplication.isolated()
        app.launchArguments = ["-uiTestExecutable", "/bin/cat", "-uiTestCwd", tmp]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)

        let button = app.buttons["commission-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Commission button should exist on launch")

        // On macOS, a click on a non-key window only focuses it; activate, click via the
        // element's coordinate, and retry until the empty state is replaced.
        var committed = false
        for _ in 0..<5 {
            app.activate()
            let center = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.click()
            if button.waitForNonExistence(timeout: 4) { committed = true; break }
        }
        XCTAssertTrue(committed, "Commissioning should create a session and replace the empty state.\n\(app.debugDescription)")

        // The session should now appear as a row in the sidebar (named for the folder).
        let row = app.descendants(matching: .any)["session-\(base)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Commissioned session row should appear in the sidebar")

        try? FileManager.default.removeItem(atPath: tmp)
    }
}
