import XCTest

/// Rendered-UI test for the Footprint panel's Task List and Goals sections. Reads the
/// XCUITest accessibility tree, not the model — the point is that the sections actually
/// draw, with the right counts, and that they VANISH when there is nothing to show.
final class FootprintChecklistUITests: XCTestCase {

    /// A transcript with three tasks, one of them completed.
    private func writeTranscript() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("checklist-\(UUID().uuidString.prefix(8)).jsonl")
        let lines = [
            toolUse(id: "t1", name: "TaskCreate", input: #"{"subject":"Add shape guard"}"#),
            toolResult(id: "t1", text: "Task #1 created successfully: Add shape guard"),
            toolUse(id: "t2", name: "TaskCreate", input: #"{"subject":"Wire boot gate"}"#),
            toolResult(id: "t2", text: "Task #2 created successfully: Wire boot gate"),
            toolUse(id: "t3", name: "TaskCreate", input: #"{"subject":"Run the rnd smoke"}"#),
            toolResult(id: "t3", text: "Task #3 created successfully: Run the rnd smoke"),
            toolUse(id: "u1", name: "TaskUpdate", input: #"{"taskId":"1","status":"completed"}"#),
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func toolUse(id: String, name: String, input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }
    private func toolResult(id: String, text: String) -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(text)"}]}}"#
    }

    /// Always `.isolated()`: a bare XCUIApplication inherits the real profile and restores
    /// the user's live sessions, so the assertions would read whatever they happen to show.
    private func launch(transcript: String?, goals: String?) -> XCUIApplication {
        let app = XCUIApplication.isolated()
        app.launchArguments = ["-uiTestPanelOpen"]
        if let transcript { app.launchArguments += ["-uiTestTranscript", transcript] }
        if let goals { app.launchArguments += ["-uiTestGoals", goals] }
        app.launch()
        return app
    }

    /// The section's count label — present only when the section rendered at all.
    private func checklist(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.staticTexts["checklist-\(name)"]
    }

    /// Row text reaches the a11y tree as a StaticText's `value` on macOS, not its label.
    private func shows(_ app: XCUIApplication, _ text: String) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "value == %@", text)).firstMatch.exists
    }

    func testBothSectionsRenderWithTheirCounts() throws {
        let app = launch(transcript: try writeTranscript(),
                         goals: "Ship PROJ-510 behind the boot gate|No manual pod checks after merge")
        defer { app.terminate() }

        let tasks = checklist(app, "task-list")
        XCTAssertTrue(tasks.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(tasks.value as? String, "1 / 3")

        let goals = checklist(app, "goals")
        XCTAssertTrue(goals.waitForExistence(timeout: 10))
        XCTAssertEqual(goals.value as? String, "0 / 2")

        XCTAssertTrue(shows(app, "Add shape guard"), app.debugDescription)
        XCTAssertTrue(shows(app, "No manual pod checks after merge"))
    }

    /// The ask: no tasks → no panel section at all, not an empty header.
    func testSectionsAreAbsentWhenEmpty() throws {
        let app = launch(transcript: nil, goals: nil)
        defer { app.terminate() }

        // The panel itself is up (its header exists) but neither checklist is.
        XCTAssertTrue(app.staticTexts["Footprint"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(checklist(app, "task-list").exists)
        XCTAssertFalse(checklist(app, "goals").exists)
    }

    /// A met goal counts toward the header and renders as a completed row.
    func testCompletedGoalsCount() throws {
        let app = launch(transcript: try writeTranscript(),
                         goals: "+Terminology lookups resolve in rnd|Ship PROJ-510|No manual pod checks")
        defer { app.terminate() }

        let goals = checklist(app, "goals")
        XCTAssertTrue(goals.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(goals.value as? String, "1 / 3")
        XCTAssertTrue(shows(app, "Terminology lookups resolve in rnd"))
    }

    func testGoalsAloneStillRender() throws {
        let app = launch(transcript: try writeTranscript(), goals: "Just the one goal")
        defer { app.terminate() }

        let goals = checklist(app, "goals")
        XCTAssertTrue(goals.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(goals.value as? String, "0 / 1")
    }
}
