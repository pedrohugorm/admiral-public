import XCTest
@testable import AdmiralCore

@MainActor
final class WatchdogServiceTests: XCTestCase {
    private var host: FakeTerminalHost!
    private var manager: SessionManager!
    private var store: WatchdogStateStore!
    private var defaults: UserDefaults!
    private var base: URL!
    private var config: WatchdogConfig!
    private var notified: [(UUID, String, String)] = []
    private var service: WatchdogService!
    private var idle: IdleClock!
    private var session: AgentSession!
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    override func setUp() async throws {
        try await super.setUp()
        host = FakeTerminalHost()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-svc-\(UUID().uuidString)")
        manager = SessionManager(host: host, claudeHome: base, executablePath: "/bin/echo",
                                 supportDir: base)
        defaults = UserDefaults(suiteName: "wd-svc-tests")
        defaults.removePersistentDomain(forName: "wd-svc-tests")
        store = WatchdogStateStore(defaults: defaults)
        config = WatchdogConfig(enabled: true)
        notified = []
        idle = IdleClock()
        service = WatchdogService(manager: manager, stateStore: store,
                                  configProvider: { [self] in config }, idle: idle,
                                  notify: { [self] id, title, body in notified.append((id, title, body)) })
        session = AgentSession(callsign: "worker", cwd: "/tmp",
                               claudeSessionID: "sid-1", status: .idle, token: "tok-1")
        let handle = host.spawn(executable: "/bin/echo", args: [], env: [:], cwd: "/tmp",
                                onExit: { _ in })
        manager.register(session, handle: handle)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func writePrompt(_ text: String) {
        let data = try! JSONEncoder().encode(PromptEvent(ts: "T", prompt: text))
        AtomicAppend.line(data, to: AdmiralPaths.promptsLog(base: base, token: "tok-1"))
    }

    /// `submit` = send(text) + send("\r"); count only the messages.
    private var injected: [String] { host.sent.filter { $0 != "\r" } }

    /// A tab launched accepting peer messages gets the probe on its messaging socket — not
    /// typed into its input box.
    func testAProbeReachesATabThatAcceptsOverTheSocket() throws {
        var socketed: [String] = []
        manager.sendPeerMessage = { body, _, _ in socketed.append(body) }
        let sock = base.appendingPathComponent("77.sock")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sock.path, contents: Data())
        try #"{"pid":77,"sessionId":"sid-2","status":"idle","messagingSocketPath":"\#(sock.path)"}"#
            .write(to: base.appendingPathComponent("sessions/77.json"), atomically: true, encoding: .utf8)
        var tab = AgentSession(callsign: "socketed", cwd: "/tmp", claudeSessionID: "sid-2",
                               status: .idle, token: "tok-2")
        tab.acceptsPeerMessages = true
        manager.register(tab, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                 cwd: "/tmp", onExit: { _ in }))
        let data = try JSONEncoder().encode(PromptEvent(ts: "T", prompt: "/drive-ticket to PROD"))
        AtomicAppend.line(data, to: AdmiralPaths.promptsLog(base: base, token: "tok-2"))

        service.tick(now: t0)
        service.tick(now: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(service.phase(forSession: "sid-2"), .probing)
        XCTAssertEqual(socketed.count, 1)
        XCTAssertTrue(socketed.first?.contains("WATCHDOG CHECK") == true, "\(socketed)")
        XCTAssertEqual(injected, [], "nothing typed — sid-1 had no trigger, sid-2 went by socket")
    }

    /// The Stop hook runs out of process, so the app mirrors "armed, and for what" to a file
    /// while the watchdog is on, and takes it away when the watchdog stands down.
    func testTheReminderMarkerFollowsTheWatchdog() {
        XCTAssertNil(WatchdogReminder.trigger(base: base, token: "tok-1"))
        writePrompt("execute and /drive-ticket to PROD")
        service.tick(now: t0)
        XCTAssertEqual(service.phase(forSession: "sid-1"), .armed)
        XCTAssertEqual(WatchdogReminder.trigger(base: base, token: "tok-1"), "/drive-ticket to PROD")

        config.enabled = false
        service.tick(now: t0.addingTimeInterval(1))
        XCTAssertEqual(service.phase(forSession: "sid-1"), .disarmed)
        XCTAssertNil(WatchdogReminder.trigger(base: base, token: "tok-1"))
    }

    func testFullCycle_armProbeNagThenDone() throws {
        writePrompt("execute and /drive-ticket to PROD")
        service.tick(now: t0)                       // arm (idle clock starts at t0)
        XCTAssertEqual(service.phase(forSession: "sid-1"), .armed)
        XCTAssertEqual(host.sent, [])

        service.tick(now: t0.addingTimeInterval(5 * 60))   // idle ≥ 5m → probe
        XCTAssertEqual(service.phase(forSession: "sid-1"), .probing)
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected[0].contains("WATCHDOG CHECK"))
        let armedTripwire = try XCTUnwrap(manager.structuredOutputState(tabID: session.id, type: .watchdog))
        XCTAssertEqual(armedTripwire.status, .armed)
        XCTAssertEqual(armedTripwire.toolName, "set_structured_output")

        // Session answers "blocked" (as the bridge tool would store it).
        var state = try XCTUnwrap(manager.structuredOutputState(tabID: session.id, type: .watchdog))
        state.status = .fulfilled
        state.result = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"status":"blocked","reason":"CI outage"}"#.utf8))
        StructuredOutputStore.write(state, base: base, token: "tok-1", type: .watchdog)

        service.tick(now: t0.addingTimeInterval(5 * 60 + 10))   // parse → nag
        XCTAssertEqual(service.phase(forSession: "sid-1"), .armed)
        XCTAssertEqual(injected.count, 2)
        XCTAssertTrue(injected[1].contains("Did you drive to prod?"))
        XCTAssertNil(manager.structuredOutputState(tabID: session.id, type: .watchdog))   // cleared

        // The nag reset the idle clock; it restarts on the next tick that reads idle,
        // then 5 more idle minutes bring the second probe → answer done.
        service.tick(now: t0.addingTimeInterval(5 * 60 + 20))    // idle clock restarts here
        service.tick(now: t0.addingTimeInterval(10 * 60 + 20))
        XCTAssertEqual(service.phase(forSession: "sid-1"), .probing)
        var done = try XCTUnwrap(manager.structuredOutputState(tabID: session.id, type: .watchdog))
        done.status = .fulfilled
        done.result = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"status":"done","reason":"prod validated east+west"}"#.utf8))
        StructuredOutputStore.write(done, base: base, token: "tok-1", type: .watchdog)

        service.tick(now: t0.addingTimeInterval(10 * 60 + 30))
        XCTAssertEqual(service.phase(forSession: "sid-1"), .disarmed)
        XCTAssertEqual(notified.count, 1)
        XCTAssertTrue(notified[0].2.contains("prod validated"))
        // Disarmed state persisted for the sid.
        XCTAssertEqual(store.state(forSession: "sid-1")?.phase, .disarmed)
    }

    func testProbeTimeoutNags() {
        writePrompt("go /drive-ticket to PROD")
        service.tick(now: t0)
        service.tick(now: t0.addingTimeInterval(5 * 60))          // probe armed
        XCTAssertEqual(injected.count, 1)
        // 3 minutes pass, no answer → reclaim + nag.
        service.tick(now: t0.addingTimeInterval(8 * 60))
        XCTAssertEqual(service.phase(forSession: "sid-1"), .armed)
        XCTAssertEqual(injected.count, 2)
        XCTAssertNil(manager.structuredOutputState(tabID: session.id, type: .watchdog))
    }

    /// Slots are per-feature, so an API request in flight neither blocks the probe (as the
    /// single shared tripwire used to) nor gets clobbered by it.
    func testProbeCoexistsWithAnApiArmAndLeavesItAlone() {
        manager.armStructuredOutput(
            tabID: session.id,
            spec: StructuredOutputSpec(schema: .object([:]), delivery: .jsonText, type: .api))
        writePrompt("go /drive-ticket to PROD")
        service.tick(now: t0)
        service.tick(now: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(service.phase(forSession: "sid-1"), .probing)
        XCTAssertEqual(injected.count, 1, "the probe still goes out")
        XCTAssertEqual(manager.structuredOutputState(tabID: session.id, type: .watchdog)?.delivery,
                       .toolUse)
        XCTAssertEqual(manager.structuredOutputState(tabID: session.id, type: .api)?.delivery,
                       .jsonText, "the API's arm is untouched")
    }

    func testMasterToggleOffDoesNothing() {
        config.enabled = false
        writePrompt("go /drive-ticket to PROD")
        service.tick(now: t0)
        service.tick(now: t0.addingTimeInterval(10 * 60))
        XCTAssertEqual(service.phase(forSession: "sid-1"), .disarmed)
        XCTAssertEqual(host.sent, [])
    }

    func testPerSessionDisableViaAPI() {
        service.setSessionEnabled("sid-1", false)
        writePrompt("go /drive-ticket to PROD")
        service.tick(now: t0)
        service.tick(now: t0.addingTimeInterval(10 * 60))
        XCTAssertEqual(host.sent, [])
        XCTAssertFalse(service.sessionEnabled("sid-1"))
        // Persisted, so a relaunch keeps the opt-out.
        XCTAssertEqual(store.state(forSession: "sid-1")?.sessionEnabled, false)
    }

    func testRelaunchResumesArmedStateFromStore() {
        let armed = WatchdogState(phase: .armed, ruleID: WatchRule.seeded.id,
                                  trigger: WatchRule.seeded.trigger, armedAt: t0)
        store.set(armed, forSession: "sid-1")
        // Fresh service (new app run) — no prompts in the log needed.
        let fresh = WatchdogService(manager: manager, stateStore: store,
                                    configProvider: { [self] in config }, idle: IdleClock(),
                                    notify: { _, _, _ in })
        fresh.tick(now: t0)
        fresh.tick(now: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(fresh.phase(forSession: "sid-1"), .probing)
        XCTAssertEqual(injected.count, 1)
    }
}
