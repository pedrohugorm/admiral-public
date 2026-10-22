import XCTest
@testable import AdmiralCore

@MainActor
final class IdleReapPolicyTests: XCTestCase {
    private func session(scratch: Bool, activityAgo: TimeInterval, now: Date,
                         status: SessionStatus = .idle) -> AgentSession {
        var s = AgentSession(callsign: "s", cwd: "/x", status: status, scratch: scratch)
        s.lastActivityAt = now.addingTimeInterval(-activityAgo)
        return s
    }

    private func manager(supportDir: URL? = nil,
                         thresholdProvider: (() -> TimeInterval)? = nil,
                         host: FakeTerminalHost? = nil) -> SessionManager {
        let host = host ?? FakeTerminalHost()
        let base = supportDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-reap-\(UUID().uuidString)")
        return SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/usr/bin/claude",
            idleReapThresholdProvider: thresholdProvider,
            appearanceStore: SessionAppearanceStore(defaults: UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!),
            openSessionsStore: OpenSessionsStore(defaults: UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!),
            supportDir: base
        )
    }

    func testReapsOnlyStaleScratchTabs() {
        let now = Date()
        let stale = session(scratch: true, activityAgo: 1801, now: now)
        let fresh = session(scratch: true, activityAgo: 60, now: now)
        let permanent = session(scratch: false, activityAgo: 9999, now: now)
        let ids = IdleReapPolicy.reapable(sessions: [stale, fresh, permanent], selectedID: nil,
                                          withOpenGoals: [], now: now)
        XCTAssertEqual(ids, [stale.id])
    }

    func testSelectedAndBusyAreNeverReaped() {
        let now = Date()
        let selected = session(scratch: true, activityAgo: 9999, now: now)
        let busy = session(scratch: true, activityAgo: 9999, now: now, status: .busy)
        let ids = IdleReapPolicy.reapable(sessions: [selected, busy], selectedID: selected.id,
                                          withOpenGoals: [], now: now)
        XCTAssertEqual(ids, [])
    }

    func testOpenGoalsBlockReap() {
        let now = Date()
        let working = session(scratch: true, activityAgo: 9999, now: now)
        let done = session(scratch: true, activityAgo: 9999, now: now)
        let ids = IdleReapPolicy.reapable(sessions: [working, done], selectedID: nil,
                                          withOpenGoals: [working.id], now: now)
        XCTAssertEqual(ids, [done.id])
    }

    func testFallsBackToSpawnTimeWhenNoActivityStamp() {
        let now = Date()
        var s = AgentSession(callsign: "s", cwd: "/x", spawnedAt: now.addingTimeInterval(-1801),
                             status: .idle, scratch: true)
        s.lastActivityAt = nil
        XCTAssertEqual(IdleReapPolicy.reapable(sessions: [s], selectedID: nil, withOpenGoals: [], now: now), [s.id])
    }

    func testManagerReapDeletesViaNormalTeardown() {
        let host = FakeTerminalHost()
        let m = manager(host: host)
        let keeper = m.commission(callsign: "keeper", cwd: "/a")         // selected, permanent
        _ = m.commission(callsign: "t", cwd: "/b", scratch: true)       // stale scratch
        m.reapIdleScratchTabs(now: Date().addingTimeInterval(1801))
        XCTAssertEqual(m.sessions.map(\.id), [keeper.id])
        XCTAssertEqual(host.terminatedPIDs.count, 1, "reap terminates the scratch tab's process")
    }

    /// The goals gate reads the session's goals file: an open goal keeps an idle scratch tab,
    /// all goals met or cancelled lets it go, and no goals file at all lets it go.
    func testManagerReapWaitsForGoals() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("admiral-reap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let m = manager(supportDir: base)
        _ = m.commission(callsign: "keeper", cwd: "/a")
        let open = m.commission(callsign: "open", cwd: "/b", scratch: true)
        let finished = m.commission(callsign: "finished", cwd: "/c", scratch: true)
        let bare = m.commission(callsign: "bare", cwd: "/d", scratch: true)
        let store = GoalsStore(base: base)
        var goals = try SessionGoals.make(from: ["ship it", "drop it"]).get()
        store.set(goals, forSession: try XCTUnwrap(open.claudeSessionID))
        goals.apply(statuses: ["g1": .met, "g2": .cancelled])
        store.set(goals, forSession: try XCTUnwrap(finished.claudeSessionID))

        m.reapIdleScratchTabs(now: Date().addingTimeInterval(1801))
        XCTAssertTrue(m.sessions.contains { $0.id == open.id }, "an open goal keeps the tab")
        XCTAssertFalse(m.sessions.contains { $0.id == finished.id }, "met/cancelled goals let it go")
        XCTAssertFalse(m.sessions.contains { $0.id == bare.id }, "no goals lets it go")
    }

    func testManagerReapHonorsThresholdProviderLive() {
        // Settings → Bridge & API edits the threshold; the provider is re-read each sweep.
        var minutes = 60
        let m = manager(thresholdProvider: { TimeInterval(minutes * 60) })
        _ = m.commission(callsign: "keeper", cwd: "/a")                 // selected, permanent
        let scratch = m.commission(callsign: "t", cwd: "/b", scratch: true)
        let later = Date().addingTimeInterval(1801)                     // stale at 30m, not 60m
        m.reapIdleScratchTabs(now: later)
        XCTAssertTrue(m.sessions.contains { $0.id == scratch.id }, "60m threshold keeps a 30m-idle tab")
        minutes = 10                                                    // settings edit, no rebuild
        m.reapIdleScratchTabs(now: later)
        XCTAssertFalse(m.sessions.contains { $0.id == scratch.id }, "10m threshold reaps it on the next sweep")
    }

    func testProgrammaticInjectStampsActivity() {
        let m = manager()
        let s = m.commission(callsign: "t", cwd: "/b", scratch: true)
        XCTAssertNil(m.sessions.first?.lastActivityAt)
        m.inject(s.id, text: "hello")
        XCTAssertNotNil(m.sessions.first?.lastActivityAt, "inject resets the idle clock")
    }
}
