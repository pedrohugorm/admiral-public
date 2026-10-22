import XCTest
@testable import AdmiralCore

final class SessionEventFeedTests: XCTestCase {
    private let prompt = Turn.user(id: "1", text: "fix it")
    private let reply = Turn.assistant(id: "2", markdown: "fixed", model: nil)
    private let thought = Turn.thinking(id: "3", text: "hmm")
    private let runningTool = Turn.tool(id: "4", name: "Bash", params: "ls", result: nil, state: .running)
    private let doneTool = Turn.tool(id: "4", name: "Bash", params: "ls", result: "a b", state: .success)
    private let finalReply = Turn.assistant(id: "5", markdown: "all done", model: nil)

    func testFreshConnectSkipsHistoryThenSendsNewMessages() {
        var feed = SessionEventFeed()
        XCTAssertEqual(feed.step(turns: [prompt, reply], status: .idle), [], "history is not replayed")
        let next = Turn.user(id: "6", text: "again")
        XCTAssertEqual(feed.step(turns: [prompt, reply, next], status: .busy),
                       [.prompt(id: "u-6", text: "again"), .status(.busy)])
    }

    func testBusyToIdleSendsOneStopWithTheFinalReply() {
        var feed = SessionEventFeed()
        _ = feed.step(turns: [prompt], status: .busy)
        let events = feed.step(turns: [prompt, finalReply], status: .idle)
        XCTAssertEqual(events, [.message(id: "a-5", text: "all done"), .status(.idle),
                                .stop(turnID: "a-5", text: "all done")])
        XCTAssertEqual(feed.step(turns: [prompt, finalReply], status: .idle), [], "one stop, not one per tick")
    }

    /// A turn that starts and ends between two polls is never seen busy; its reply arriving
    /// while idle still ends it.
    func testTurnFasterThanAPollStillStops() {
        var feed = SessionEventFeed()
        _ = feed.step(turns: [], status: .idle)
        let events = feed.step(turns: [prompt, finalReply], status: .idle)
        XCTAssertEqual(events, [.prompt(id: "u-1", text: "fix it"), .message(id: "a-5", text: "all done"),
                                .stop(turnID: "a-5", text: "all done")])
    }

    func testRunningToolWaitsForItsResultAndHoldsLaterTurns() {
        var feed = SessionEventFeed()
        _ = feed.step(turns: [prompt], status: .busy)
        XCTAssertEqual(feed.step(turns: [prompt, runningTool], status: .busy), [])
        XCTAssertEqual(feed.step(turns: [prompt, doneTool, finalReply], status: .busy),
                       [.tool(id: "x-4", name: "Bash", state: .success, params: "ls", result: "a b"),
                        .message(id: "a-5", text: "all done")])
    }

    func testThinkingIsNotSent() {
        var feed = SessionEventFeed()
        _ = feed.step(turns: [prompt], status: .busy)
        XCTAssertEqual(feed.step(turns: [prompt, thought, reply], status: .busy),
                       [.message(id: "a-2", text: "fixed")])
    }

    func testLastEventIDResumesAfterThatTurn() {
        var feed = SessionEventFeed(lastEventID: "u-1")
        XCTAssertEqual(feed.step(turns: [prompt, reply, finalReply], status: .busy),
                       [.message(id: "a-2", text: "fixed"), .message(id: "a-5", text: "all done")])
    }

    func testResumingFromAStopDoesNotRepeatIt() {
        var feed = SessionEventFeed(lastEventID: "a-5#stop")
        XCTAssertEqual(feed.step(turns: [prompt, finalReply], status: .idle), [])
    }

    func testUnknownLastEventIDReplaysTheTail() {
        var feed = SessionEventFeed(lastEventID: "u-gone")
        XCTAssertEqual(feed.step(turns: [prompt, reply], status: .busy),
                       [.prompt(id: "u-1", text: "fix it"), .message(id: "a-2", text: "fixed")])
    }

    // MARK: - Redacted output rounds

    // Obviously fake test data — never a real patient.
    private let raw: JSONValue = .object(["slack_reply": .string("filed for John Testerston")])
    private let scrubbed: JSONValue = .object(["slack_reply": .string("filed for [REDACTED]")])
    private var schema: JSONValue { .object(["type": .string("object")]) }

    private func slot(_ status: StructuredOutputState.Status, round: Int, result: JSONValue? = nil) -> StructuredOutputState {
        StructuredOutputState(schema: schema, delivery: .toolUse, status: status, result: result, round: round)
    }

    /// With redaction on, the live slot's raw result never goes out: the round waits for its
    /// copy and is sent from it, tagged redacted.
    func testWithRedactionOnARoundGoesOutOnlyFromItsCopy() throws {
        var feed = SessionEventFeed()
        _ = feed.frames(turns: [prompt], status: .busy, output: slot(.armed, round: 1), redacted: [])
        let done = slot(.fulfilled, round: 1, result: raw)
        XCTAssertEqual(feed.step(turns: [prompt, finalReply], status: .idle, output: done, redacted: []),
                       [.message(id: "a-5", text: "all done"), .status(.idle), .stop(turnID: "a-5", text: "all done")],
                       "no output until the copy exists")
        let copy = RedactedOutput(round: 1, status: .fulfilled, result: scrubbed)
        let frames = feed.frames(turns: [prompt, finalReply], status: .idle, output: done, redacted: [copy])
        XCTAssertEqual(frames.map(\.event),
                       [.output(round: 1, fulfilled: true, result: scrubbed, turn: "a-5", redacted: true)])
        XCTAssertEqual(frames.first?.id, "a-5~o1")
        let wire = String(decoding: try XCTUnwrap(frames.first).event.data, as: UTF8.self)
        XCTAssertFalse(wire.contains("Testerston"), wire)
        XCTAssertTrue(wire.contains(#""redacted":true"#), wire)
        XCTAssertEqual(feed.step(turns: [prompt, finalReply], status: .idle, output: done, redacted: [copy]), [],
                       "sent once")
    }

    func testACopyTheModCouldNotRedactGoesOutFailedWithNoResult() {
        var feed = SessionEventFeed(lastEventID: "a-5")
        let copy = RedactedOutput(round: 1, status: .fulfilled, result: nil, failed: true)
        XCTAssertEqual(feed.step(turns: [prompt, finalReply], status: .idle,
                                 output: slot(.fulfilled, round: 1, result: raw), redacted: [copy]),
                       [.output(round: 1, fulfilled: false, result: nil, turn: "a-5",
                                violations: [RedactedOutput.redactionFailed], redacted: true)])
    }

    /// A Stop hook that reopens the turn re-arms the slot for the next round before the first
    /// round's copy lands: the copy still goes out, then the next round's.
    func testEachRoundGoesOutFromItsCopyInOrderEvenAfterTheSlotMovedOn() {
        var feed = SessionEventFeed(lastEventID: "a-5")
        let copies = [RedactedOutput(round: 2, status: .fulfilled, result: .object(["slack_reply": .string("goals done")])),
                      RedactedOutput(round: 1, status: .fulfilled, result: scrubbed)]
        let events = feed.step(turns: [prompt, finalReply], status: .idle, output: slot(.armed, round: 3), redacted: copies)
        XCTAssertEqual(events.map { if case let .output(round, _, _, _, _, _, _, _) = $0 { round } else { 0 } }, [1, 2])
    }

    func testWithRedactionOffTheLiveSlotGoesOutUntagged() {
        var feed = SessionEventFeed(lastEventID: "a-5")
        XCTAssertEqual(feed.step(turns: [prompt, finalReply], status: .idle,
                                 output: slot(.fulfilled, round: 1, result: raw), redacted: nil),
                       [.output(round: 1, fulfilled: true, result: raw, turn: "a-5")])
    }

    /// The client dropped after a round; the next round's copy reaches the reconnect alone.
    func testResumeAfterARoundDoesNotRepeatIt() {
        var live = SessionEventFeed(lastEventID: "a-5")
        let c1 = RedactedOutput(round: 1, status: .fulfilled, result: scrubbed)
        let id = live.frames(turns: [prompt, finalReply], status: .idle, output: slot(.armed, round: 2), redacted: [c1]).last?.id
        XCTAssertEqual(id, "a-5~o1")
        var resumed = SessionEventFeed(lastEventID: id)
        let c2 = RedactedOutput(round: 2, status: .failed, violations: ["no call"])
        XCTAssertEqual(resumed.step(turns: [prompt, finalReply], status: .idle, output: slot(.failed, round: 2),
                                    redacted: [c1, c2]),
                       [.output(round: 2, fulfilled: false, result: nil, turn: "a-5", violations: ["no call"], redacted: true)])
    }

    func testNoMessageIsTaggedRedactedAnyMore() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FeedEvent.message(id: "a-5", text: "x").data) as? [String: Any])
        XCTAssertNil(body["redacted"])
    }

    func testStopIDCarriesTheSuffixAndDataIsJSON() throws {
        let stop = FeedEvent.stop(turnID: "a-5", text: "all done")
        XCTAssertEqual(stop.sseID, "a-5#stop")
        let body = try JSONSerialization.jsonObject(with: stop.data) as? [String: String]
        XCTAssertEqual(body, ["text": "all done"])
    }
}
