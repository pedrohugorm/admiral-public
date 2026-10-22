import XCTest
@testable import AdmiralCore

@MainActor
final class SetStructuredOutputToolTests: XCTestCase {
    private var base: URL!
    private var manager: SessionManager!
    private var bridge: BridgeCore!
    private var token: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("so-tool-\(UUID().uuidString)")
        manager = SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/usr/bin/claude",
            appearanceStore: SessionAppearanceStore(defaults: UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!),
            openSessionsStore: OpenSessionsStore(defaults: UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!),
            supportDir: base
        )
        bridge = BridgeCore(manager: manager)
        token = manager.commission(callsign: "w", cwd: "/x").token
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private var schema: JSONValue {
        try! JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}"#.utf8))
    }
    private func arm() {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText), base: base, token: token)
    }
    private func state() -> StructuredOutputState? { StructuredOutputStore.read(base: base, token: token) }

    func testUnknownCallerFails() {
        XCTAssertFalse(bridge.setStructuredOutput(fromToken: "ghost", outputJSON: "{}").ok)
    }

    func testNothingArmedFails() {
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":true}"#)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("no structured output is armed"))
    }

    /// The user says "it's done, close it" between watchdog checks. With nothing armed the
    /// report used to be refused, and the watchdog stayed on until its next check.
    func testAnUnaskedReportReachesAWatchdogThatIsWatching() {
        bridge.isWatchdogWatching = { _ in true }
        let r = bridge.setStructuredOutput(fromToken: token,
                                           outputJSON: #"{"status":"done","reason":"user closed it"}"#)
        XCTAssertTrue(r.ok, r.message)
        let slot = StructuredOutputStore.read(base: base, token: token, type: .watchdog)
        XCTAssertEqual(slot?.status, .fulfilled)
        XCTAssertEqual(slot?.result?["status"]?.stringValue, "done")
    }

    func testAnUnaskedReportIsStillRefusedWhenNoWatchdogIsWatching() {
        bridge.isWatchdogWatching = { _ in false }
        let r = bridge.setStructuredOutput(fromToken: token,
                                           outputJSON: #"{"status":"done","reason":"x"}"#)
        XCTAssertFalse(r.ok)
        XCTAssertNil(StructuredOutputStore.read(base: base, token: token, type: .watchdog))
    }

    func testValidOutputFulfills() {
        arm()
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":true}"#)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(state()?.status, .fulfilled)
        XCTAssertNotNil(state()?.result)
    }

    func testInvalidOutputCountsAttemptAndReportsViolations() {
        arm()
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":"yes"}"#)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("$.ok: expected boolean"), r.message)
        XCTAssertEqual(state()?.attempts, 1)
        XCTAssertEqual(state()?.status, .armed, "still armed — the model gets another try")
    }

    /// A retry restates the schema. The only copy the model was given is in the Stop block
    /// that armed it, which may be far back in context by the time it is correcting itself.
    func testRetryRestatesTheSchema() {
        arm()
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":"yes"}"#)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains(StopInstruction.schemaText(schema)), r.message)
        XCTAssertTrue(r.message.contains(#""required":["ok"]"#), r.message)
    }

    /// Once the budget is spent there is nothing to correct, so the schema is just noise.
    func testGivingUpDoesNotRestateTheSchema() {
        arm()
        for _ in 0..<2 { _ = bridge.setStructuredOutput(fromToken: token, outputJSON: "not json") }
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: "not json")
        XCTAssertTrue(r.message.contains("giving up"), r.message)
        XCTAssertFalse(r.message.contains("the schema is:"), r.message)
    }

    func testThirdFailureGivesUp() {
        arm()
        for _ in 0..<2 { _ = bridge.setStructuredOutput(fromToken: token, outputJSON: "not json") }
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: "still not json")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("giving up"), r.message)
        XCTAssertEqual(state()?.status, .failed)
        XCTAssertEqual(state()?.attempts, 3)
    }

    // MARK: - Routing between slots

    private func arm(_ type: ArmType) {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText),
                                    base: base, token: token, type: type)
    }
    private func state(_ type: ArmType) -> StructuredOutputState? {
        StructuredOutputStore.read(base: base, token: token, type: type)
    }

    func testTypeRoutesToThatSlotOnly() {
        arm(.watchdog)
        arm(.goals)
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":true}"#,
                                           type: "goals")
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(state(.goals)?.status, .fulfilled)
        XCTAssertEqual(state(.watchdog)?.status, .armed, "the other slot is untouched")
    }

    func testOmittedTypeWithSeveralArmedAsksWhichOne() {
        arm(.api)
        arm(.goals)
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":true}"#)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("several structured outputs are armed"), r.message)
        XCTAssertTrue(r.message.contains("api, goals"), r.message)
        XCTAssertEqual(state(.api)?.status, .armed)
        XCTAssertEqual(state(.goals)?.status, .armed)
    }

    /// One armed slot keeps the single-arm ergonomics the endpoint and watchdog rely on.
    func testOmittedTypeWithOneArmedRoutesToIt() {
        arm(.watchdog)
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":true}"#)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(state(.watchdog)?.status, .fulfilled)
    }

    func testUnknownTypeIsRefusedByName() {
        arm(.api)
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":true}"#,
                                           type: "wachdog")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("unknown type 'wachdog'"), r.message)
        XCTAssertTrue(r.message.contains("api, output, watchdog, goals"), r.message)
    }

    func testNamingAnUnarmedSlotFails() {
        arm(.api)
        let r = bridge.setStructuredOutput(fromToken: token, outputJSON: #"{"ok":true}"#,
                                           type: "goals")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("no goals structured output is armed"), r.message)
    }

    /// Budgets are per-slot: stonewalling one nudge must not spend another's attempts.
    func testFailedAttemptsDoNotLeakAcrossSlots() {
        arm(.watchdog)
        arm(.goals)
        for _ in 0..<2 {
            _ = bridge.setStructuredOutput(fromToken: token, outputJSON: "not json", type: "goals")
        }
        XCTAssertEqual(state(.goals)?.attempts, 2)
        XCTAssertEqual(state(.watchdog)?.attempts, 0)
    }

    func testExposedThroughMCPToolsCall() {
        arm()
        let mcp = MCPServer(bridge: bridge)
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_structured_output","arguments":{"output":"{\"ok\":true}"}}}"#
        let reply = mcp.handle(requestData: Data(call.utf8), sessionToken: token)
        let obj = try! JSONSerialization.jsonObject(with: reply) as! [String: Any]
        let result = obj["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(state()?.status, .fulfilled)
        // And it's listed.
        XCTAssertTrue(MCPServer.tools.contains { ($0["name"] as? String) == "set_structured_output" })
    }
}
