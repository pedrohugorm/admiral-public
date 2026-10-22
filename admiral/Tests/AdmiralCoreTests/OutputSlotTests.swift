import XCTest
@testable import AdmiralCore

/// A tab's own output schema: every turn re-arms the `output` slot, the Stop hook holds the
/// turn until `set_structured_output(type: "output")` lands, within the usual budget.
@MainActor
final class OutputSlotTests: XCTestCase {
    private var base: URL!
    private let sid = "sess-output-1"
    private let token = "TOK1"

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("output-slot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private let strict = #"{"type":"object","additionalProperties":false,"required":["verdict","score"],"properties":{"verdict":{"type":"string","enum":["pass","fail"]},"score":{"type":"integer"}}}"#

    private func makeBridge() -> (BridgeCore, SessionManager) {
        let manager = SessionManager(host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
                                     executablePath: "/bin/echo", supportDir: base)
        manager.register(AgentSession(callsign: "worker", cwd: "/a", claudeSessionID: sid, token: token),
                         handle: FakeTerminalHost.Handle(pid: 1))
        return (BridgeCore(manager: manager), manager)
    }

    private func hook(_ event: String, token: String? = nil) async -> String? {
        await HookDispatcher.handle(cliType: "claude", event: event,
                                    payload: Data(#"{"session_id":"\#(sid)","prompt":"go"}"#.utf8),
                                    base: base, token: token ?? self.token)
    }

    private var slot: StructuredOutputState? {
        StructuredOutputStore.read(base: base, token: token, type: .output)
    }

    // MARK: - Every turn owes the output

    func testEachPromptArmsTheSlotAndStopHoldsTheTurnUntilItIsSet() async throws {
        XCTAssertNil(OutputSchemaStore.set(json(strict), base: base, session: sid))
        let (bridge, _) = makeBridge()

        _ = await hook("UserPromptSubmit")
        XCTAssertEqual(slot?.status, .armed)
        XCTAssertEqual(slot?.round, 1)

        let held = await hook("Stop")
        let block = try XCTUnwrap(held, "the turn is held")
        XCTAssertTrue(block.contains(#"\"output\""#), block)

        XCTAssertTrue(bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"verdict":"pass","score":3}"#,
                                                 type: "output").ok)
        XCTAssertEqual(slot?.status, .fulfilled)
        let afterSet = await hook("Stop")
        XCTAssertNil(afterSet, "fulfilled: the turn may end")

        _ = await hook("UserPromptSubmit")
        XCTAssertEqual(slot?.status, .armed, "the next prompt owes a new answer")
        XCTAssertEqual(slot?.round, 2)
        XCTAssertEqual(slot?.blocks, 0, "with a fresh budget")
    }

    func testATabWithoutASchemaIsNeverArmed() async {
        _ = await hook("UserPromptSubmit")
        XCTAssertNil(slot)
        let stop = await hook("Stop")
        XCTAssertNil(stop)
    }

    func testAnswerThatBreaksTheSchemaIsRefused() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        _ = await hook("UserPromptSubmit")
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"verdict":"maybe","score":3}"#, type: "output")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(slot?.status, .armed)
        XCTAssertEqual(slot?.attempts, 1)
    }

    // MARK: - Budget

    func testExhaustedBudgetFailsTheRoundAndLetsTheTurnGo() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        _ = await hook("UserPromptSubmit")
        for i in 1...StructuredOutputState.maxBlocks {
            let out = await hook("Stop")
            XCTAssertNotNil(out, "block \(i) holds the turn")
        }
        let last = await hook("Stop")
        XCTAssertNil(last, "past the budget the turn is let go")
        XCTAssertEqual(slot?.status, .failed)
    }

    /// `api` outranks `output`: a caller waiting synchronously is answered first.
    func testApiSlotWinsTheStopOverOutput() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        _ = await hook("UserPromptSubmit")
        StructuredOutputStore.write(.init(schema: json(#"{"type":"object"}"#), delivery: .jsonText),
                                    base: base, token: token, type: .api)
        let block = await hook("Stop")
        XCTAssertTrue(block?.contains(#"\"api\""#) == true, block ?? "nil")
        XCTAssertEqual(slot?.blocks, 0, "output's budget did not move")
    }

    // MARK: - Strict schemas

    func testStrictSchemaRules() {
        XCTAssertEqual(StrictSchema.violations(json(strict)), [])
        let cases: [(String, String)] = [
            (#"{"type":"string"}"#, "root must be an object"),
            (#"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}"#,
             "additionalProperties"),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string"}},"required":[]}"#,
             "listed in \"required\""),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string","pattern":"x"}},"required":["a"]}"#,
             "keyword \"pattern\""),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":["string","null"]}},"required":["a"]}"#,
             "single \"type\""),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"array"}},"required":["a"]}"#,
             "needs \"items\""),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"object","properties":{"b":{"type":"string"}},"required":["b"]}},"required":["a"]}"#,
             "$.a: an object needs \"additionalProperties\""),
            (#"{"type":"object","additionalProperties":false,"properties":{},"required":["ghost"]}"#,
             "not in \"properties\""),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string"}},"required":"a"}"#,
             "\"required\" must be an array of property names"),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string","enum":"x"}},"required":["a"]}"#,
             "$.a: \"enum\" must be a non-empty array"),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string","enum":[]}},"required":["a"]}"#,
             "$.a: \"enum\" must be a non-empty array"),
            (#"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string","enum":["ok",1]}},"required":["a"]}"#,
             "$.a: enum value 1 does not match \"type\": \"string\""),
            (#"{"type":"object","additionalProperties":false,"properties":{"n":{"type":"integer","const":"3"}},"required":["n"]}"#,
             "$.n: const \"3\" does not match \"type\": \"integer\""),
        ]
        XCTAssertEqual(StrictSchema.violations(json(#"{"type":"object","additionalProperties":false,"properties":{"level":{"type":"string","enum":["low","high"]},"n":{"type":"integer","const":3}},"required":["level","n"]}"#)), [],
                       "an enum and a const of the node's own type are fine")
        for (schema, expected) in cases {
            let problems = StrictSchema.violations(json(schema)).joined(separator: " | ")
            XCTAssertTrue(problems.contains(expected), "\(schema) → \(problems)")
        }
    }

    func testCommissionRefusesANonStrictSchemaBeforeCreatingATab() {
        let (bridge, manager) = makeBridge()
        let before = manager.sessions.count
        let r = bridge.commission(callsign: "x", cwd: "/tmp", outputSchema: #"{"type":"object"}"#)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("must be strict"), r.message)
        XCTAssertEqual(manager.sessions.count, before)
    }

    func testCommissionWithASchemaStoresItForTheNewTab() throws {
        let (bridge, manager) = makeBridge()
        let r = bridge.commission(callsign: "judge", cwd: "/tmp", outputSchema: strict)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("output_schema=set"), r.message)
        let tab = try XCTUnwrap(manager.sessions.first { $0.callsign == "judge" })
        XCTAssertEqual(OutputSchemaStore.schema(base: base, session: try XCTUnwrap(tab.claudeSessionID)), json(strict))
    }

    func testSetOutputSchemaSetsAndClears() {
        let (bridge, _) = makeBridge()
        XCTAssertFalse(bridge.setOutputSchema(callsign: "worker", schemaJSON: #"{"type":"object"}"#).ok)
        XCTAssertTrue(bridge.setOutputSchema(callsign: "worker", schemaJSON: strict).ok)
        XCTAssertNotNil(OutputSchemaStore.schema(base: base, session: sid))
        StructuredOutputStore.write(.init(schema: json(strict), delivery: .jsonText, round: 1),
                                    base: base, token: token, type: .output)
        XCTAssertTrue(bridge.setOutputSchema(callsign: "worker", schemaJSON: "").ok)
        XCTAssertNil(OutputSchemaStore.schema(base: base, session: sid))
        XCTAssertNil(slot, "clearing disarms the slot too")
    }

    // MARK: - Where the result shows

    func testSessionStatusReportsTheLatestRound() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        XCTAssertTrue(bridge.sessionStatus(callsign: "worker").message.contains("output_schema=set (no turn yet)"))
        _ = await hook("UserPromptSubmit")
        _ = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"verdict":"fail","score":1}"#, type: "output")
        let status = bridge.sessionStatus(callsign: "worker").message
        XCTAssertTrue(status.contains(#"output_schema=set round 1: {"score":1,"verdict":"fail"}"#), status)
    }

    func testFeedSendsEachFinishedRoundOnce() {
        let schema = json(strict)
        let result = json(#"{"verdict":"pass","score":2}"#)
        var feed = SessionEventFeed()
        _ = feed.step(turns: [], status: .busy, output: .init(schema: schema, delivery: .jsonText, round: 1))
        let done = StructuredOutputState(schema: schema, delivery: .jsonText, status: .fulfilled,
                                         result: result, round: 1)
        XCTAssertEqual(feed.step(turns: [], status: .busy, output: done),
                       [.output(round: 1, fulfilled: true, result: result)])
        XCTAssertEqual(feed.step(turns: [], status: .busy, output: done), [], "sent once")

        let failed = StructuredOutputState(schema: schema, delivery: .jsonText, status: .failed, round: 2)
        XCTAssertEqual(feed.step(turns: [], status: .busy, output: failed),
                       [.output(round: 2, fulfilled: false, result: nil)])
    }

    func testFeedResumeAndFreshConnectForRounds() throws {
        let schema = json(strict)
        let done1 = StructuredOutputState(schema: schema, delivery: .jsonText, status: .fulfilled,
                                          result: json(#"{"verdict":"pass","score":1}"#), round: 1)
        var fresh = SessionEventFeed()
        XCTAssertEqual(fresh.step(turns: [], status: .idle, output: done1), [], "a fresh connect skips finished rounds")

        // A pre-upgrade id still carrying the redacted-copy count resumes; the count is dropped.
        var live = SessionEventFeed(lastEventID: "~r0")
        let frame = try XCTUnwrap(live.frames(turns: [], status: .idle, output: done1).first)
        XCTAssertEqual(frame.id, "~o1")
        var resumed = SessionEventFeed(lastEventID: frame.id)
        XCTAssertEqual(resumed.step(turns: [], status: .idle, output: done1), [], "not repeated after a resume")
        let done2 = StructuredOutputState(schema: schema, delivery: .jsonText, status: .fulfilled,
                                          result: json(#"{"verdict":"fail","score":0}"#), round: 2)
        XCTAssertEqual(resumed.step(turns: [], status: .idle, output: done2).count, 1)
    }

    func testOutputEventData() throws {
        let event = FeedEvent.output(round: 3, fulfilled: true, result: json(#"{"verdict":"pass","score":2}"#),
                                     at: Date(timeIntervalSince1970: 1_790_000_000), turn: "a-7",
                                     violations: ["ignored when fulfilled"], callsign: "worker")
        XCTAssertEqual(event.name, "output")
        XCTAssertEqual(String(decoding: event.data, as: UTF8.self),
                       #"{"at":"2026-09-21T14:13:20Z","callsign":"worker","redacted":false,"result":{"score":2,"verdict":"pass"},"round":3,"status":"fulfilled","turn":"a-7","violations":[]}"#)
        let failed = FeedEvent.output(round: 4, fulfilled: false, result: nil,
                                      at: Date(timeIntervalSince1970: 1_790_000_000), turn: nil,
                                      violations: ["$.score: missing"], callsign: "worker")
        XCTAssertEqual(String(decoding: failed.data, as: UTF8.self),
                       #"{"at":"2026-09-21T14:13:20Z","callsign":"worker","redacted":false,"result":null,"round":4,"status":"failed","turn":null,"violations":["$.score: missing"]}"#)
        XCTAssertEqual(String(decoding: FeedEvent.output(round: 1, fulfilled: true, result: nil).data, as: UTF8.self),
                       #"{"at":null,"callsign":null,"redacted":false,"result":null,"round":1,"status":"fulfilled","turn":null,"violations":[]}"#)
    }

    /// The feed fills in the callsign, when the round settled, the turn it had reached and why
    /// it failed — and a slot file from before those fields still decodes.
    func testFeedStampsTheOutputEvent() throws {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        var feed = SessionEventFeed(callsign: "worker")
        let turns: [Turn] = [.user(id: "1", text: "go"), .assistant(id: "2", markdown: "done", model: nil)]
        _ = feed.step(turns: turns, status: .busy, output: .init(schema: json(strict), delivery: .jsonText, round: 1))
        let failed = StructuredOutputState(schema: json(strict), delivery: .jsonText, status: .failed, round: 1,
                                           completedAt: when, violations: ["output is not valid JSON"])
        XCTAssertEqual(feed.step(turns: turns, status: .idle, output: failed).compactMap { event -> FeedEvent? in
            if case .output = event { return event } else { return nil }
        }, [.output(round: 1, fulfilled: false, result: nil, at: when, turn: "a-2",
                    violations: ["output is not valid JSON"], callsign: "worker")])

        let legacy = Data(#"{"schema":{"type":"object"},"delivery":"json_text","attempts":0,"blocks":1,"status":"armed","round":2}"#.utf8)
        let old = try JSONDecoder().decode(StructuredOutputState.self, from: legacy)
        XCTAssertNil(old.completedAt)
        XCTAssertNil(old.violations)
        XCTAssertNil(old.settled)
    }

    func testFulfilAndGiveUpStampTheSlot() async throws {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        _ = await hook("UserPromptSubmit")
        XCTAssertNil(slot?.completedAt)
        XCTAssertFalse(bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"verdict":"maybe","score":3}"#,
                                                  type: "output").ok)
        XCTAssertNotNil(slot?.violations?.first, "the last validation errors are kept")
        XCTAssertTrue(bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"verdict":"pass","score":3}"#,
                                                 type: "output").ok)
        XCTAssertEqual(slot?.status, .fulfilled)
        XCTAssertNotNil(slot?.completedAt)
        XCTAssertNil(slot?.violations)

        _ = await hook("UserPromptSubmit")
        for _ in 1...StructuredOutputState.maxBlocks { _ = await hook("Stop") }
        _ = await hook("Stop")
        XCTAssertEqual(slot?.status, .failed)
        XCTAssertNotNil(slot?.completedAt)
        XCTAssertEqual(slot?.violations, ["no output after 3 blocks"], "gave up without a single attempt")

        _ = await hook("UserPromptSubmit")
        for _ in 1...StructuredOutputState.maxAttempts {
            _ = bridge.setStructuredOutput(fromToken: token, outputJSON: "nope", type: "output")
        }
        XCTAssertEqual(slot?.status, .failed)
        XCTAssertEqual(slot?.violations, ["output is not valid JSON"])
        XCTAssertNotNil(slot?.completedAt)
    }

    // MARK: - A run that continues past its fulfilled turn

    private func fulfil(_ bridge: BridgeCore, _ body: String = #"{"verdict":"pass","score":3}"#) {
        XCTAssertTrue(bridge.setStructuredOutput(fromToken: token, outputJSON: body, type: "output").ok)
    }

    /// Background-task wake-up / goals-review block: a second Stop in the same prompt, after the
    /// first let the fulfilled round go, owes a new answer.
    func testASecondStopInTheSamePromptAfterFulfilReArmsAndBlocks() async throws {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        _ = await hook("UserPromptSubmit")
        _ = await hook("Stop")
        fulfil(bridge)
        let first = await hook("Stop")
        XCTAssertNil(first, "the first Stop after fulfil lets the turn go")
        XCTAssertEqual(slot?.status, .fulfilled)
        XCTAssertEqual(slot?.settled, true)

        let second = await hook("Stop")
        let block = try XCTUnwrap(second, "the run continued: the new answer is owed")
        XCTAssertTrue(block.contains(#"\"output\""#), block)
        XCTAssertEqual(slot?.status, .armed)
        XCTAssertEqual(slot?.round, 2)
        XCTAssertEqual(slot?.blocks, 1, "re-armed and blocked in one write")
        XCTAssertEqual(slot?.attempts, 0)
        XCTAssertNil(slot?.result)
        XCTAssertNil(slot?.settled)

        fulfil(bridge, #"{"verdict":"fail","score":1}"#)
        let third = await hook("Stop")
        XCTAssertNil(third)
        XCTAssertEqual(slot?.round, 2)
        XCTAssertEqual(slot?.status, .fulfilled)
        XCTAssertEqual(slot?.result, json(#"{"verdict":"fail","score":1}"#))
    }

    func testANewPromptStillResetsToTheNextRoundWithAFreshBudget() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        _ = await hook("UserPromptSubmit")
        fulfil(bridge)
        _ = await hook("Stop")
        _ = await hook("Stop")   // re-armed: round 2, blocks 1
        XCTAssertEqual(slot?.round, 2)
        _ = await hook("UserPromptSubmit")
        XCTAssertEqual(slot?.status, .armed)
        XCTAssertEqual(slot?.round, 3)
        XCTAssertEqual(slot?.blocks, 0)
        XCTAssertNil(slot?.settled)
        // …and a Stop right after the fulfil of that fresh prompt is a first Stop again.
        fulfil(bridge)
        let stop = await hook("Stop")
        XCTAssertNil(stop)
        XCTAssertEqual(slot?.status, .fulfilled)
    }

    func testAFailedSlotIsNotReArmedByALaterStop() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        _ = await hook("UserPromptSubmit")
        for _ in 1...StructuredOutputState.maxBlocks { _ = await hook("Stop") }
        _ = await hook("Stop")
        XCTAssertEqual(slot?.status, .failed)
        for _ in 1...3 {
            let stop = await hook("Stop")
            XCTAssertNil(stop)
        }
        XCTAssertEqual(slot?.status, .failed, "failed stays failed until a new prompt")
        XCTAssertEqual(slot?.round, 1)
        _ = await hook("UserPromptSubmit")
        XCTAssertEqual(slot?.status, .armed)
        XCTAssertEqual(slot?.round, 2)
    }

    func testTheReArmKeepsTheThreeBlockCap() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        _ = await hook("UserPromptSubmit")
        fulfil(bridge)
        _ = await hook("Stop")
        for i in 1...StructuredOutputState.maxBlocks {
            let block = await hook("Stop")
            XCTAssertNotNil(block, "block \(i) of the continued round")
        }
        let last = await hook("Stop")
        XCTAssertNil(last)
        XCTAssertEqual(slot?.status, .failed)
        XCTAssertEqual(slot?.round, 2)
        XCTAssertEqual(slot?.violations, ["no output after 3 blocks"])
    }

    func testNoReArmWithoutASchemaOrForOtherSlots() async {
        // The tab's schema was cleared mid-run: a fulfilled, settled slot is not re-armed.
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        _ = await hook("UserPromptSubmit")
        fulfil(bridge)
        _ = await hook("Stop")
        OutputSchemaStore.set(nil, base: base, session: sid)
        let stop = await hook("Stop")
        XCTAssertNil(stop)
        XCTAssertEqual(slot?.status, .fulfilled)
    }

    func testAHigherPrioritySlotStillWinsTheReArmedStop() async {
        OutputSchemaStore.set(json(strict), base: base, session: sid)
        let (bridge, _) = makeBridge()
        _ = await hook("UserPromptSubmit")
        fulfil(bridge)
        _ = await hook("Stop")
        StructuredOutputStore.write(.init(schema: json(#"{"type":"object"}"#), delivery: .jsonText),
                                    base: base, token: token, type: .api)
        let block = await hook("Stop")
        XCTAssertTrue(block?.contains(#"\"api\""#) == true, block ?? "nil")
        XCTAssertEqual(slot?.status, .armed, "output waits its turn")
        XCTAssertEqual(slot?.blocks, 0)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token, type: .api)?.blocks, 1)
    }

    // MARK: - Survives reload, goes with delete

    func testReloadKeepsTheSchemaAndDeleteRemovesIt() async throws {
        let manager = SessionManager(host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
                                     executablePath: "/bin/echo", supportDir: base)
        let tab = manager.commission(callsign: "judge", cwd: "/tmp")
        let sid = try XCTUnwrap(tab.claudeSessionID)
        OutputSchemaStore.set(json(strict), base: base, session: sid)

        let fresh = try XCTUnwrap(manager.reload(tab.id))
        XCTAssertEqual(fresh.claudeSessionID, sid, "reload relaunches the same claude session")
        XCTAssertNotEqual(fresh.token, tab.token)
        _ = await HookDispatcher.handle(cliType: "claude", event: "UserPromptSubmit",
                                        payload: Data(#"{"session_id":"\#(sid)","prompt":"go"}"#.utf8),
                                        base: base, token: fresh.token)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: fresh.token, type: .output)?.status, .armed,
                       "the reloaded tab still owes its output")

        manager.delete(fresh.id)
        XCTAssertNil(OutputSchemaStore.schema(base: base, session: sid))
    }
}
