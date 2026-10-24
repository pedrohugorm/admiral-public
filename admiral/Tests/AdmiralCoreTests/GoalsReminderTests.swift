import XCTest
@testable import AdmiralCore

final class GoalsReminderTests: XCTestCase {
    private var base: URL!
    private var store: GoalsStore!
    private let sid = "sid-reminder"

    override func setUp() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("goals-reminder-\(UUID().uuidString)")
        store = GoalsStore(base: base)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func goals(_ texts: [String], done: [String] = [],
                       cancelled: [String] = []) -> SessionGoals {
        guard case var .success(goals) = SessionGoals.make(from: texts) else {
            fatalError("fixture must be valid")
        }
        var statuses = Dictionary(uniqueKeysWithValues: done.map { ($0, GoalStatus.met) })
        for id in cancelled { statuses[id] = .cancelled }
        goals.apply(statuses: statuses)
        return goals
    }

    private func payload(session: String) -> Data {
        Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)","prompt":"go"}"#.utf8)
    }

    private func dispatch(token: String? = "tok") async -> String? {
        await HookDispatcher.handle(cliType: "claude", event: "UserPromptSubmit",
                                    payload: payload(session: sid), base: base, token: token)
    }

    // MARK: - What it says

    func testListsOnlyTheOpenGoalsWithTheirIds() {
        let reminder = GoalsReminder.context(for: goals(["ship it", "verify in rnd", "no manual checks"],
                                                        done: ["g1"]))
        XCTAssertTrue(reminder.contains("1/3 met, 2 still open"), reminder)
        XCTAssertTrue(reminder.contains("g2) verify in rnd"), reminder)
        XCTAssertTrue(reminder.contains("g3) no manual checks"), reminder)
        XCTAssertFalse(reminder.contains("ship it"), "a met goal is not still open")
        XCTAssertTrue(reminder.contains("update_goals"), "it must name the tool to call")
    }

    /// EVERY prompt carries one. A session that never set goals is exactly the one that
    /// needs asking, so "nothing open" is an invitation, not silence.
    func testNothingOpenInvitesTheSessionToSetGoals() {
        for (state, expected) in [(GoalsReminder.context(for: nil), "set goals for this session"),
                                  (GoalsReminder.context(for: goals([])), "set goals for this session"),
                                  (GoalsReminder.context(for: goals(["done"], done: ["g1"])),
                                   "every goal is met. Before you do anything else, call `set_goal_self`"),
                                  (GoalsReminder.context(for: goals(["dropped"], cancelled: ["g1"])),
                                   "set goals for this session")] {
            XCTAssertTrue(state.contains(expected), state)
            XCTAssertTrue(state.contains("set_goal_self"), state)
            // It asks for outcomes, and says so twice — because the failure mode is a list of
            // commands ("run the tests"), which is provable and says nothing about the work.
            XCTAssertTrue(state.contains("OUTCOMES"), state)
            XCTAssertTrue(state.contains("Not the commands"), state)
        }
        // It has to ASK, not report — a status line nobody can act on is wasted space.
        XCTAssertEqual(GoalsReminder.systemMessage(for: nil),
                       "⚑ Set goals for this session — what would prove it done?")
        XCTAssertEqual(GoalsReminder.systemMessage(for: goals(["done"], done: ["g1"])),
                       "⚑ All goals met. Set the next goals now.")
    }

    /// Once every goal is met, the next request gets goals before anything else, and only a pure
    /// question or chat may skip them. A session that never set goals keeps the one-off opt-out.
    func testAllMetPressesForTheNextGoals() {
        let met = GoalsReminder.context(for: goals(["done"], done: ["g1"]))
        XCTAssertTrue(met.hasPrefix("ADMIRAL GOALS — every goal is met. Before you do anything else, "
                                    + "call `set_goal_self` with the goals for this request.\n"), met)
        XCTAssertTrue(met.hasSuffix("lets it stop. " + GoalsReminder.skipRule), met)
        XCTAssertFalse(met.contains("set the next ones"), met)
        XCTAssertFalse(met.contains("one-off"), met)

        // A session that never set goals gets the same narrow exception, not a "one-off" opt-out.
        let never = GoalsReminder.context(for: nil)
        XCTAssertTrue(never.hasPrefix("ADMIRAL GOALS — set goals for this session. Before you do anything "
                                      + "else, call `set_goal_self`"), never)
        XCTAssertTrue(never.hasSuffix("lets it stop. " + GoalsReminder.skipRule), never)
        XCTAssertFalse(never.contains("one-off"), never)
        XCTAssertFalse(never.contains("nothing to track"), never)
    }

    /// The per-prompt line carries the same rule, so the exception cannot widen after the first.
    func testFollowUpCarriesTheSameNarrowExemption() throws {
        for state in [nil, goals(["done"], done: ["g1"])] {
            let line = try XCTUnwrap(GoalsReminder.followUp(for: state))
            XCTAssertTrue(line.hasSuffix(GoalsReminder.skipRule), line)
            XCTAssertFalse(line.contains("otherwise carry on"), line)
        }
    }

    // MARK: - Through the hook

    func testPromptHookReturnsTheReminderAsContext() async throws {
        store.set(goals(["ship it", "verify"], done: ["g1"]), forSession: sid)
        let out = await dispatch()
        let json = try XCTUnwrap(out, "UserPromptSubmit stdout IS the mechanism")
        // Visible to the user AND readable by the model — a bare string is only the latter.
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["systemMessage"] as? String, "⚑ Goals 1/2 — still open: g2")
        let specific = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "UserPromptSubmit")
        XCTAssertTrue((specific["additionalContext"] as? String)?.contains("g2) verify") == true)
    }

    func testPromptHookInvitesWhenTheSessionHasNoGoals() async throws {
        let out = await dispatch()
        let json = try XCTUnwrap(out, "every prompt carries a goals message")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["systemMessage"] as? String,
                       "⚑ Set goals for this session — what would prove it done?")
        let specific = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertTrue((specific["additionalContext"] as? String)?.contains("set_goal_self") == true)
    }

    func testPromptHookStillLogsThePromptForTheWatchdog() async {
        store.set(goals(["ship it"]), forSession: sid)
        _ = await dispatch()
        let log = AdmiralPaths.promptsLog(base: base, token: "tok")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("\"prompt\":\"go\""), "the watchdog's capture must survive")
    }

    /// The goals file is keyed by the claude session id — the only identifier the helper
    /// gets — so a payload without one is the one case with nothing to say.
    func testPayloadWithoutASessionIdIsSilent() {
        let payload = Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"go"}"#.utf8)
        XCTAssertNil(GoalsReminder.promptJSON(payload: payload, base: base))
    }

    // MARK: - Sent once per change

    /// Hook context accumulates until compaction, so an unchanged reminder is not sent again:
    /// with goals open the second prompt carries the visible line and nothing for the model.
    func testUnchangedOpenGoalsAreNotResentIntoContext() async {
        store.set(goals(["ship it", "verify"], done: ["g1"]), forSession: sid)
        let first = await dispatch()
        XCTAssertEqual(first, GoalsReminder.promptJSON(for: store.goals(forSession: sid)))
        XCTAssertTrue(first?.contains("g2) verify") == true, first ?? "nil")
        let second = await dispatch()
        XCTAssertEqual(second, #"{"systemMessage":"⚑ Goals 1\/2 — still open: g2"}"#)
    }

    /// Without goals the full instructions go once; later prompts get one line that still asks,
    /// since any prompt may be the first with work in it.
    func testUnchangedNoGoalsSendsTheShortLine() async throws {
        _ = await dispatch()
        let out = await dispatch()
        let second = try XCTUnwrap(out)
        let expected = GoalsReminder.promptJSON(for: nil, context: GoalsReminder.followUp(for: nil))
        XCTAssertEqual(second, expected)
        XCTAssertTrue(second.contains("ADMIRAL GOALS — none set."), second)
        XCTAssertFalse(second.contains("OUTCOMES"), "the full instructions were already sent")
    }

    /// A change in what is open is news: the full context goes again, with the new list.
    func testChangedGoalsAreResentInFull() async throws {
        store.set(goals(["ship it", "verify"]), forSession: sid)
        _ = await dispatch()
        store.set(goals(["ship it", "verify"], done: ["g1"]), forSession: sid)
        let out = await dispatch()
        let after = try XCTUnwrap(out)
        XCTAssertEqual(after, GoalsReminder.promptJSON(for: store.goals(forSession: sid)))
        XCTAssertTrue(after.contains("g2) verify"), after)
    }

    /// `/clear` or compaction drops the earlier reminder from context, so SessionStart (matched
    /// to those sources) forgets it was sent and the next prompt carries it in full.
    func testSessionStartAfterCompactionResendsInFull() async throws {
        store.set(goals(["ship it"]), forSession: sid)
        _ = await dispatch()
        _ = await HookDispatcher.handle(
            cliType: "claude", event: "SessionStart",
            payload: Data(#"{"hook_event_name":"SessionStart","source":"compact","session_id":"\#(sid)"}"#.utf8),
            base: base, token: "tok")
        let out = await dispatch()
        let after = try XCTUnwrap(out)
        XCTAssertTrue(after.contains("g1) ship it"), after)
    }

    /// The app writes the goals, the hook helper reads them: same path, same key, two
    /// processes. If these ever disagree the reminder goes quiet with no other symptom.
    func testAppAndHookAgreeOnTheFile() {
        store.set(goals(["ship it"]), forSession: sid)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AdmiralPaths.goalsFile(base: base, session: sid).path))
        XCTAssertNotNil(GoalsReminder.promptJSON(payload: payload(session: sid), base: base))
    }
}

/// Ending a turn with goals still open earns one visible block per prompt.
final class GoalReviewStopTests: XCTestCase {
    private var base: URL!
    private var store: GoalsStore!
    private let sid = "sid-review"
    private let token = "tok-review"

    override func setUp() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-review-\(UUID().uuidString)")
        store = GoalsStore(base: base)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func goals(_ texts: [String], done: [String] = []) -> SessionGoals {
        guard case var .success(goals) = SessionGoals.make(from: texts) else {
            fatalError("fixture must be valid")
        }
        goals.apply(statuses: Dictionary(uniqueKeysWithValues: done.map { ($0, GoalStatus.met) }))
        return goals
    }

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

    func testBlocksOnceWithAVisibleMessageThenLetsTheTurnEnd() async throws {
        store.set(goals(["ship it", "verify"], done: ["g1"]), forSession: sid)

        let blocked = await stop()
        let first = try XCTUnwrap(blocked)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        XCTAssertEqual(obj["decision"] as? String, "block")
        XCTAssertEqual(obj["systemMessage"] as? String, "⚑ Goals 1/2 — still open: g2",
                       "the user has to SEE it, not just the model")
        let reason = try XCTUnwrap(obj["reason"] as? String)
        XCTAssertTrue(reason.contains("g2) verify"), reason)
        XCTAssertTrue(reason.contains("`cancelled`"), reason)
        // An open goal with a next step means keep working; "Then end your turn" let a driver
        // call a failed CI run a blocker and stop.
        XCTAssertTrue(reason.contains("if there is a next step you can take toward it, take it now."), reason)
        XCTAssertFalse(reason.contains("Then end your turn."), reason)

        // A block resumes the turn, so an unbounded rule would loop forever.
        let second = await stop()
        XCTAssertNil(second, "the budget is one block per prompt")
    }

    func testTheNextPromptReArmsTheReview() async {
        store.set(goals(["ship it"]), forSession: sid)
        _ = await stop()
        let spent = await stop()
        XCTAssertNil(spent)
        await prompt()
        let reArmed = await stop()
        XCTAssertNotNil(reArmed, "a new instruction earns a new review")
    }

    func testSilentWhenEveryGoalIsResolved() async {
        store.set(goals(["ship it"], done: ["g1"]), forSession: sid)
        let out = await stop()
        XCTAssertNil(out)
    }

    func testSilentWithoutGoals() async {
        let out = await stop()
        XCTAssertNil(out)
    }

    /// A session that owes structured output is already being held; two blocks in one Stop
    /// is one reason too many, and the contract outranks the reminder.
    func testStructuredOutputOutranksTheReview() async throws {
        store.set(goals(["ship it"]), forSession: sid)
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"object"}"#.utf8))
        StructuredOutputStore.write(.init(schema: schema, delivery: .toolUse),
                                    base: base, token: token, type: .watchdog)
        let stopped = await stop()
        let out = try XCTUnwrap(stopped)
        XCTAssertTrue(out.contains("set_structured_output"), out)
        XCTAssertFalse(out.contains("goal review"), out)
    }

}
