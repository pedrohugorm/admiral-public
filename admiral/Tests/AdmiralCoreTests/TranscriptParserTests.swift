import XCTest
@testable import AdmiralCore

final class TranscriptParserTests: XCTestCase {
    /// A realistic transcript mirroring the reference screenshot scenario.
    private let scheduledOrdering: [String] = [
        #"{"type":"ai-title","aiTitle":"Implement scheduled ordering","sessionId":"s1"}"#,
        #"{"type":"user","message":{"role":"user","content":"Add scheduled ordering so customers can pick a future delivery time when placing an order."}}"#,
        #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"thinking","thinking":"Plan the schema and worker."},{"type":"text","text":"I'll add a `scheduledFor` field to the order schema, a time-picker to checkout, and a fulfillment worker."}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TaskCreate","input":{"subject":"Add scheduledFor to order schema"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Task #1 created successfully: Add scheduledFor to order schema"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"TaskCreate","input":{"subject":"Add time picker to checkout"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Task #2 created successfully: Add time picker to checkout"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"TaskCreate","input":{"subject":"Wire delivery queue worker"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"Task #3 created successfully: Wire delivery queue worker"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"u1","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"u2","name":"TaskUpdate","input":{"taskId":"2","status":"completed"}}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"u3","name":"TaskUpdate","input":{"taskId":"3","status":"in_progress"}}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"npm test"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b1","content":"ok"}]}}"#,
        #"{"type":"file-history-snapshot","note":"ignored line type"}"#,
    ]

    private let withUUIDs: [String] = [
        #"{"type":"user","uuid":"line-u1","message":{"role":"user","content":"fix it"}}"#,
        #"{"type":"assistant","uuid":"line-a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"fixed"}]}}"#,
        #"{"type":"user","message":{"role":"user","content":"no uuid on this one"}}"#,
    ]

    /// The SSE feed de-dups and resumes on turn ids, so the same file must parse to the same
    /// ids every time — a random id per parse re-sent the whole tail on every poll.
    func testTurnIdsAreStableAcrossParses() {
        let first = TranscriptParser.parse(lines: withUUIDs).turns.map(\.id)
        let second = TranscriptParser.parse(lines: withUUIDs).turns.map(\.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["u-line-u1.0", "t-line-a1.0", "a-line-a1.1", first[3]])
        XCTAssertEqual(Set(first).count, first.count, "ids are unique within a conversation")
    }

    /// Two polls of an unchanged transcript send nothing new, and a fresh connect replays no
    /// history — with ids the parser made, not hand-written ones.
    func testFeedOverRealParsesSendsEachTurnOnce() {
        var feed = SessionEventFeed()
        XCTAssertEqual(feed.step(turns: TranscriptParser.parse(lines: withUUIDs).turns, status: .idle), [],
                       "a fresh connect starts at the current end")
        XCTAssertEqual(feed.step(turns: TranscriptParser.parse(lines: withUUIDs).turns, status: .idle), [],
                       "an unchanged transcript re-parsed sends nothing")
        let more = withUUIDs + [#"{"type":"assistant","uuid":"line-a2","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#]
        XCTAssertEqual(feed.step(turns: TranscriptParser.parse(lines: more).turns, status: .idle),
                       [.message(id: "a-line-a2.0", text: "done"), .stop(turnID: "a-line-a2.0", text: "done")])
        XCTAssertEqual(feed.step(turns: TranscriptParser.parse(lines: more).turns, status: .idle), [],
                       "one stop per finished turn, not one per poll")
    }

    func testTitleFromAITitle() {
        let convo = TranscriptParser.parse(lines: scheduledOrdering)
        XCTAssertEqual(convo.title, "Implement scheduled ordering")
    }

    func testCustomTitleWinsOverAITitle() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"Robotic title"}"#,
            #"{"type":"custom-title","customTitle":"My title"}"#,
        ]
        XCTAssertEqual(TranscriptParser.parse(lines: lines).title, "My title")
    }

    func testPlanFoldedFromTaskStream() {
        let plan = TranscriptParser.parse(lines: scheduledOrdering).plan
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.items.map(\.title), [
            "Add scheduledFor to order schema",
            "Add time picker to checkout",
            "Wire delivery queue worker",
        ])
        XCTAssertEqual(plan?.items.map(\.state), [.completed, .completed, .inProgress])
        XCTAssertEqual(plan?.progress.done, 2)
        XCTAssertEqual(plan?.progress.total, 3)
    }

    func testUserAndAssistantTurns() {
        let turns = TranscriptParser.parse(lines: scheduledOrdering).turns
        let userTexts = turns.compactMap { turn -> String? in
            if case let .user(_, text) = turn { return text }
            return nil
        }
        XCTAssertTrue(userTexts.contains { $0.hasPrefix("Add scheduled ordering") })

        let assistantTexts = turns.compactMap { turn -> String? in
            if case let .assistant(_, md, _) = turn { return md }
            return nil
        }
        XCTAssertTrue(assistantTexts.contains { $0.contains("`scheduledFor`") })

        let thinking = turns.contains { if case .thinking = $0 { return true }; return false }
        XCTAssertTrue(thinking)
    }

    func testToolResultAttachedAndStated() {
        let turns = TranscriptParser.parse(lines: scheduledOrdering).turns
        let bash = turns.first { if case let .tool(id, _, _, _, _) = $0 { return id == "b1" }; return false }
        guard case let .tool(_, name, params, result, state)? = bash else {
            return XCTFail("Bash tool turn missing")
        }
        XCTAssertEqual(name, "Bash")
        XCTAssertEqual(params, "npm test")
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(state, .success)
    }

    func testTodoWriteSnapshotTakesPrecedence() {
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"x1","name":"TodoWrite","input":{"todos":[{"content":"First","status":"completed"},{"content":"Second","status":"in_progress"},{"content":"Third","status":"pending"}]}}]}}"#,
        ]
        let plan = TranscriptParser.parse(lines: lines).plan
        XCTAssertEqual(plan?.items.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(plan?.items.map(\.state), [.completed, .inProgress, .pending])
    }

    func testEmptyAndGarbageLinesIgnored() {
        let convo = TranscriptParser.parse(lines: ["", "   ", "not json", "{}"])
        XCTAssertTrue(convo.turns.isEmpty)
        XCTAssertNil(convo.plan)
        XCTAssertNil(convo.title)
    }
}
