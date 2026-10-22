import XCTest

/// Rendered-UI test for the session-switch bug. Reads the XCUITest accessibility tree
/// (the live terminal text), never the model. (Transcript-rendering UI tests were
/// removed when the Transcript view was hidden; transcript parsing/resolution is
/// covered by the fast AdmiralCore unit tests.)
final class SessionSwitchUITests: XCTestCase {

    // MARK: helpers

    private func makeTempDir(_ prefix: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Click an element (handling the macOS "first click only focuses the window" quirk)
    /// until `condition` holds — checking before each click to avoid double-commissioning.
    private func clickUntil(_ app: XCUIApplication, _ element: XCUIElement, _ condition: () -> Bool, _ what: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), "element should exist: \(what)")
        for _ in 0..<6 {
            if condition() { return }
            app.activate()
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            Thread.sleep(forTimeInterval: 0.6)
            if condition() { return }
        }
        XCTAssertTrue(condition(), "condition not met after clicks: \(what). \(app.debugDescription)")
    }

    private func value(_ element: XCUIElement, contains substring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = element.value as? String, v.contains(substring) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Select a session by clicking its sidebar row until its terminal is shown.
    private func selectSession(_ app: XCUIApplication, _ name: String) {
        let row = app.descendants(matching: .any).matching(identifier: "session-\(name)").firstMatch
        let term = app.staticTexts["terminal-content"]
        clickUntil(app, row, { (term.value as? String)?.contains("TERMCWD=\(name)") ?? false }, "select \(name)")
    }

    // MARK: selecting a session must show ITS terminal, and content must survive a round-trip

    func testSwitchingSessionShowsItsTerminalAndSurvivesRoundTrip() throws {
        let dirA = try makeTempDir("ADMA")
        let dirB = try makeTempDir("ADMB")
        let nameA = (dirA as NSString).lastPathComponent
        let nameB = (dirB as NSString).lastPathComponent

        let app = XCUIApplication.isolated()
        app.launchArguments = [
            "-uiTestExecutable", "/bin/sh",
            "-uiTestArgs", #"-c|||echo TERMCWD=$(basename "$PWD"); exec cat"#,
            "-uiTestCwd", "\(dirA)|||\(dirB)",
        ]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)

        // Commission A (empty-state button), then B (sidebar +); confirm via sidebar rows.
        clickUntil(app, app.buttons["commission-button"],
                   { app.descendants(matching: .any)["session-\(nameA)"].exists }, "commission A")
        clickUntil(app, app.buttons["commission-button-sidebar"],
                   { app.descendants(matching: .any)["session-\(nameB)"].exists }, "commission B")

        let term = app.staticTexts["terminal-content"]
        XCTAssertTrue(term.waitForExistence(timeout: 10), "terminal-content element should exist")

        // B just commissioned → selected: shows B's terminal, NOT A's.
        XCTAssertTrue(value(term, contains: "TERMCWD=\(nameB)", timeout: 12),
                      "B's terminal should be shown; got [\((term.value as? String) ?? "")]")
        XCTAssertFalse(((term.value as? String) ?? "").contains("TERMCWD=\(nameA)"),
                       "must not show A's terminal while B is selected")

        selectSession(app, nameA)
        XCTAssertTrue(value(term, contains: "TERMCWD=\(nameA)", timeout: 12),
                      "selecting A must switch the panel to A's terminal")

        selectSession(app, nameB)
        XCTAssertTrue(value(term, contains: "TERMCWD=\(nameB)", timeout: 12),
                      "selecting B must switch the panel to B's terminal")

        // Round-trip: A's live terminal content must SURVIVE (not blank / recreated).
        selectSession(app, nameA)
        XCTAssertTrue(value(term, contains: "TERMCWD=\(nameA)", timeout: 12),
                      "A's terminal content must survive the B→A→B→A round-trip")
    }
}
