import XCTest
@testable import AdmiralCore

/// A watched session ending a turn is reminded, once per prompt, that "done" only counts
/// when it is reported through `set_structured_output`.
final class WatchdogReminderTests: XCTestCase {
    private var base: URL!
    private let sid = "sid-wd"
    private let token = "tok-wd"

    override func setUp() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-reminder-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func stop() async -> String? {
        await HookDispatcher.handle(
            cliType: "claude", event: "Stop",
            payload: Data(#"{"hook_event_name":"Stop","session_id":"\#(sid)"}"#.utf8),
            base: base, token: token)
    }

    private func prompt() async {
        _ = await HookDispatcher.handle(
            cliType: "claude", event: "UserPromptSubmit",
            payload: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","prompt":"go"}"#.utf8),
            base: base, token: token)
    }

    private func object(_ json: String?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
    }

    func testAWatchedSessionIsRemindedToReportDoneOncePerPrompt() async throws {
        WatchdogReminder.mark(trigger: "/drive-ticket to PROD", base: base, token: token)

        let stopped = await stop()
        let obj = try object(stopped)
        XCTAssertEqual(obj["decision"] as? String, "block")
        let reason = try XCTUnwrap(obj["reason"] as? String)
        XCTAssertTrue(reason.contains("\"/drive-ticket to PROD\""), reason)
        XCTAssertTrue(reason.contains("set_structured_output"), reason)
        XCTAssertTrue(reason.contains("\"status\":\"done\""), reason)
        // Unfinished work means keep going: "not done → end your turn" stopped a driver that
        // had a failed CI run to fix.
        XCTAssertTrue(reason.contains("If it is not done, do not report in_progress: take the next step yourself now."), reason)
        XCTAssertFalse(reason.contains("If it is not done, end your turn"), reason)
        XCTAssertNotNil(obj["systemMessage"] as? String, "the user sees it happened")

        let again = await stop()
        XCTAssertNil(again, "one block per prompt — a block resumes the turn")
        await prompt()
        let reArmed = await stop()
        XCTAssertNotNil(reArmed, "a new instruction earns a new reminder")
    }

    func testSilentWhenNoWatchdogIsWatching() async {
        let out = await stop()
        XCTAssertNil(out)
        WatchdogReminder.mark(trigger: "x", base: base, token: token)
        WatchdogReminder.unmark(base: base, token: token)
        let afterOff = await stop()
        XCTAssertNil(afterOff)
    }

    /// A probe the session owes is the real thing; the reminder must not take its Stop.
    func testAPendingProbeOutranksTheReminder() async throws {
        WatchdogReminder.mark(trigger: "/drive-ticket to PROD", base: base, token: token)
        let spec = try XCTUnwrap(WatchdogMachine.probeSpec)
        StructuredOutputStore.write(.init(schema: spec.schema, delivery: .toolUse),
                                    base: base, token: token, type: .watchdog)
        let stopped = await stop()
        let out = try XCTUnwrap(stopped)
        XCTAssertFalse(out.contains("watchdog — a watchdog is watching"), out)
    }

    /// One reason per Stop: open goals are reviewed first, the reminder takes a later Stop.
    func testTheGoalReviewOutranksTheReminder() async throws {
        WatchdogReminder.mark(trigger: "/drive-ticket to PROD", base: base, token: token)
        guard case let .success(goals) = SessionGoals.make(from: ["ship it"]) else {
            return XCTFail("fixture")
        }
        GoalsStore(base: base).set(goals, forSession: sid)

        let firstStop = await stop()
        let first = try XCTUnwrap(firstStop)
        XCTAssertTrue(first.contains("goal review"), first)
        let secondStop = await stop()
        let second = try XCTUnwrap(secondStop)
        XCTAssertTrue(second.contains("a watchdog is watching"), second)
    }
}
