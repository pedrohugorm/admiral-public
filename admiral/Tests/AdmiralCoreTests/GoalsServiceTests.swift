import XCTest
@testable import AdmiralCore

@MainActor
final class GoalsServiceTests: XCTestCase {
    private var host: FakeTerminalHost!
    private var manager: SessionManager!
    private var base: URL!
    private var goals: GoalsStore!
    private var idle: IdleClock!
    private var config: GoalsNudgeConfig!
    private var notified: [(UUID, String, String)] = []
    private var service: GoalsService!
    private var session: AgentSession!
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    override func setUp() async throws {
        try await super.setUp()
        host = FakeTerminalHost()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("goals-svc-\(UUID().uuidString)")
        manager = SessionManager(host: host, executablePath: "/bin/echo", supportDir: base)
        goals = GoalsStore(base: base)
        idle = IdleClock()
        config = GoalsNudgeConfig(enabled: true)
        notified = []
        service = GoalsService(manager: manager, goalsStore: goals,
                               configProvider: { [self] in config }, idle: idle,
                               notify: { [self] id, title, body in notified.append((id, title, body)) })
        session = AgentSession(callsign: "worker", cwd: "/tmp",
                               claudeSessionID: "sid-1", status: .idle, token: "tok-1")
        manager.register(session, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                     cwd: "/tmp", onExit: { _ in }))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private var injected: [String] { host.sent.filter { $0 != "\r" } }

    private func setGoals(_ texts: [String]) {
        guard case let .success(value) = SessionGoals.make(from: texts, now: t0) else {
            return XCTFail("fixture must be valid")
        }
        goals.set(value, forSession: "sid-1")
    }

    /// The idle clock is shared, so the goals service must READ it rather than start its
    /// own — otherwise both nudges would count idleness separately.
    private func advanceIdle(to seconds: TimeInterval) {
        idle.observe("sid-1", status: .idle, now: t0)
        idle.observe("sid-1", status: .idle, now: t0.addingTimeInterval(seconds))
    }

    func testFullCycle_probeAnswerNagThenAllDone() throws {
        setGoals(["ship PROJ-510", "no manual pod checks"])
        service.tick(now: t0)
        XCTAssertEqual(service.phase(forSession: "sid-1"), .watching)
        XCTAssertEqual(injected, [])

        advanceIdle(to: 5 * 60)
        service.tick(now: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(service.phase(forSession: "sid-1"), .probing)
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected[0].contains("GOALS CHECK"), injected[0])
        let armed = try XCTUnwrap(manager.structuredOutputState(tabID: session.id, type: .goals))
        XCTAssertEqual(armed.status, .armed)

        // The session answers: one done, one not.
        try fulfil(#"{"goals":[{"id":"g1","done":true},{"id":"g2","done":false}]}"#)
        service.tick(now: t0.addingTimeInterval(5 * 60 + 10))
        XCTAssertEqual(goals.goals(forSession: "sid-1")?.progress.done, 1)
        XCTAssertEqual(service.phase(forSession: "sid-1"), .watching)
        XCTAssertEqual(injected.count, 2)
        XCTAssertTrue(injected[1].contains("g2) no manual pod checks"), injected[1])
        XCTAssertNil(manager.structuredOutputState(tabID: session.id, type: .goals))

        // Second round: the last goal lands.
        advanceIdle(to: 5 * 60)
        service.tick(now: t0.addingTimeInterval(11 * 60))
        try fulfil(#"{"goals":[{"id":"g2","done":true}]}"#)
        service.tick(now: t0.addingTimeInterval(11 * 60 + 10))

        XCTAssertEqual(goals.goals(forSession: "sid-1")?.isComplete, true)
        XCTAssertEqual(service.phase(forSession: "sid-1"), .idle)
        XCTAssertEqual(notified.count, 1)
        XCTAssertTrue(notified[0].1.contains("Goals met"), notified[0].1)
        XCTAssertNil(manager.structuredOutputState(tabID: session.id, type: .goals))
    }

    private func fulfil(_ json: String) throws {
        var state = try XCTUnwrap(manager.structuredOutputState(tabID: session.id, type: .goals))
        state.status = .fulfilled
        state.result = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        StructuredOutputStore.write(state, base: base, token: "tok-1", type: .goals)
    }

    func testNoGoalsNeverNudges() {
        advanceIdle(to: 60 * 60)
        service.tick(now: t0.addingTimeInterval(60 * 60))
        XCTAssertEqual(injected, [])
        XCTAssertNil(manager.structuredOutputState(tabID: session.id, type: .goals))
    }

    func testDisabledNeverNudges() {
        config.enabled = false
        setGoals(["ship it"])
        advanceIdle(to: 60 * 60)
        service.tick(now: t0.addingTimeInterval(60 * 60))
        XCTAssertEqual(injected, [])
    }

    /// The arbitration: the watchdog injects first and wakes the shared clock, which puts
    /// this session back below the goals threshold — so it gets one nudge, not two.
    func testAnotherNudgeWakingTheSessionDefersTheGoalsProbe() {
        setGoals(["ship it"])
        service.tick(now: t0)
        advanceIdle(to: 5 * 60)
        idle.wake("sid-1")                     // e.g. the watchdog just injected its probe
        service.tick(now: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(injected, [], "deferred a cycle")
        XCTAssertEqual(service.phase(forSession: "sid-1"), .watching)
    }

    /// A garbled answer that parses as JSON but carries no usable entries must not read as
    /// "everything is done".
    func testAnswerWithoutUsableEntriesNagsInstead() throws {
        setGoals(["ship it"])
        service.tick(now: t0)
        advanceIdle(to: 5 * 60)
        service.tick(now: t0.addingTimeInterval(5 * 60))
        try fulfil(#"{"goals":[{"id":"g1"}]}"#)
        service.tick(now: t0.addingTimeInterval(5 * 60 + 10))

        XCTAssertEqual(goals.goals(forSession: "sid-1")?.progress.done, 0)
        XCTAssertEqual(notified.count, 0)
        XCTAssertEqual(injected.count, 2, "probe, then a nag")
    }

    func testClosedSessionsDropTheirState() {
        setGoals(["ship it"])
        service.tick(now: t0)
        XCTAssertEqual(service.states.count, 1)
        manager.delete(session.id)
        service.tick(now: t0.addingTimeInterval(10))
        XCTAssertTrue(service.states.isEmpty)
    }
}
