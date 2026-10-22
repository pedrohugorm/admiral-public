import XCTest
@testable import AdmiralCore

/// The five `schedule_*` bridge tools, driven the way a tab calls them.
@MainActor
final class ScheduleToolsTests: XCTestCase {
    private var base: URL!
    private var backend: FakeScheduleBackend!
    private var scheduler: SchedulerService!
    private var bridge: BridgeCore!
    private var server: MCPServer!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let manager = SessionManager(host: FakeTerminalHost(), claudeHome: base.appendingPathComponent("claude"),
                                     executablePath: "/bin/echo", supportDir: base)
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"), handle: FakeTerminalHost.Handle(pid: 1))
        backend = FakeScheduleBackend(dir: base)
        scheduler = SchedulerService(store: ScheduleStore(base: base), backend: backend,
                                     runConfig: TabRun.Config(busySeenTimeout: 0.05, turnTimeout: 0.3, pollInterval: 0.002,
                                                              injectReadyTimeout: 0.05, injectVerifyTimeout: 0.05),
                                     providers: { [CCSwitchProvider(id: "p-kimi", name: "Kimi", env: [:])] })
        bridge = BridgeCore(manager: manager)
        bridge.scheduler = scheduler
        server = MCPServer(bridge: bridge)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func call(_ tool: String, _ args: [String: Any] = [:]) -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": args]]
        let data = server.handle(requestData: try! JSONSerialization.data(withJSONObject: request), sessionToken: "A")
        let result = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? true)
    }

    private func settle() async {
        for task in scheduler.tasks.values { await task.value }
    }

    @discardableResult
    private func create(_ name: String = "night report", extra: [String: Any] = [:]) -> (text: String, isError: Bool) {
        var args: [String: Any] = ["name": name, "cron": "0 9 * * *", "cwd": base.path, "prompt": "write the report"]
        args.merge(extra) { $1 }
        return call("schedule_set", args)
    }

    func testTheToolsAreListed() {
        let names = Set(MCPServer.tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(["schedule_list", "schedule_set", "schedule_delete", "schedule_run", "schedule_history"]
            .allSatisfy(names.contains))
    }

    func testSetCreatesTheScheduleAndAnswersWithItsNextRuns() {
        let result = create()
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("created schedule night-report"), result.text)
        XCTAssertTrue(result.text.contains("Every day at 9:00"), result.text)
        XCTAssertTrue(result.text.contains("next runs"), result.text)
        XCTAssertEqual(scheduler.store.all().map(\.name), ["night-report"])
    }

    func testSetTakesACustomModel() {
        XCTAssertFalse(create(extra: ["provider": "Kimi"]).isError)
        XCTAssertEqual(scheduler.store.all().first?.provider, "Kimi")
        XCTAssertTrue(call("schedule_list").text.contains("Kimi"))
    }

    /// A schedule names the claude model (default opus) and effort its runs launch with, and
    /// both show in the list.
    func testSetTakesAModelAndEffort() {
        let result = create(extra: ["model": "fable", "effort": "xhigh"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(scheduler.store.all().first?.model, "fable")
        XCTAssertEqual(scheduler.store.all().first?.effort, "xhigh")
        XCTAssertTrue(result.text.contains("model fable"), result.text)
        let list = call("schedule_list").text
        XCTAssertTrue(list.contains("model fable"), list)
        XCTAssertTrue(list.contains("effort xhigh"), list)
    }

    func testSetRefusesAnUnknownModelOrEffort() {
        let result = create(extra: ["model": "gpt-5", "effort": "ultra"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("sonnet"), result.text)
        XCTAssertTrue(result.text.contains("xhigh"), result.text)
    }

    func testSetListsEveryProblem() {
        let result = call("schedule_set", ["name": "x", "cron": "61 * * * *", "cwd": "/no/such/folder", "prompt": ""])
        XCTAssertTrue(result.isError)
        for fragment in ["minute", "/no/such/folder", "prompt"] {
            XCTAssertTrue(result.text.contains(fragment), "\(fragment) missing from: \(result.text)")
        }
    }

    func testListShowsWhatIsScheduled() {
        XCTAssertEqual(call("schedule_list").text, "(no schedules)")
        create()
        let list = call("schedule_list").text
        for fragment in ["night-report", "Every day at 9:00", "0 9 * * *", "next", base.path, "scratch"] {
            XCTAssertTrue(list.contains(fragment), "\(fragment) missing from: \(list)")
        }
    }

    func testRunStartsARunAndHistoryShowsIt() async {
        create()
        let run = call("schedule_run", ["name": "night-report"])
        XCTAssertFalse(run.isError, run.text)
        XCTAssertTrue(run.text.contains("@night-report"), run.text)
        await settle()
        let history = call("schedule_history", ["name": "night-report"])
        XCTAssertFalse(history.isError, history.text)
        let runID = try? XCTUnwrap(scheduler.store.runs(for: scheduler.store.all()[0].id).first?.id)
        XCTAssertTrue(history.text.contains(runID ?? "?"), history.text)
        XCTAssertTrue(history.text.contains("succeeded"), history.text)
        XCTAssertTrue(history.text.contains("now"), history.text)
    }

    /// One run's detail is read from its session's transcript: nothing of it was copied into
    /// the index.
    func testHistoryForOneRunReadsItsReplyAndOutputFromTheTranscript() async throws {
        create(extra: ["output_schema": SchedulerServiceTests.schema])
        backend.outputStatus = .fulfilled
        _ = call("schedule_run", ["name": "night-report"])
        await settle()
        let opened = try XCTUnwrap(backend.opened.first)
        let transcript = backend.transcriptPath(sessionID: opened.sessionID, cwd: base.path)
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Report written."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__bridge__set_structured_output","input":{"type":"output","output":"{\"summary\":\"all green\"}"}}]}}"#,
        ]
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: transcript))
        handle.seekToEndOfFile()
        handle.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        handle.closeFile()
        let runID = try XCTUnwrap(scheduler.store.runs(for: scheduler.store.all()[0].id).first?.id)
        let detail = call("schedule_history", ["run_id": runID])
        XCTAssertFalse(detail.isError, detail.text)
        XCTAssertTrue(detail.text.contains("Report written."), detail.text)
        XCTAssertTrue(detail.text.contains(#"{"summary":"all green"}"#), detail.text)
    }

    func testDeleteRemovesTheSchedule() {
        create()
        XCTAssertFalse(call("schedule_delete", ["name": "night-report"]).isError)
        XCTAssertEqual(scheduler.store.all(), [])
        XCTAssertTrue(call("schedule_delete", ["name": "night-report"]).isError)
    }

    func testRunNamesAnUnknownSchedule() {
        XCTAssertTrue(call("schedule_run", ["name": "nope"]).isError)
    }

    func testWithoutASchedulerTheToolsSaySo() {
        bridge.scheduler = nil
        let result = call("schedule_list")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not available"), result.text)
    }
}
