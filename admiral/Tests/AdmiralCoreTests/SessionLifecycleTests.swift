import XCTest
@testable import AdmiralCore

@MainActor
final class SessionLifecycleTests: XCTestCase {
    private func tempDefaults() -> UserDefaults { UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")! }

    private func manager(_ store: OpenSessionsStore) -> SessionManager {
        SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/usr/bin/claude",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: store
        )
    }

    func testOpenSessionsStoreUpsertAndRemove() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        XCTAssertTrue(store.all().isEmpty)
        store.upsert(OpenSessionRecord(cwd: "/a", sessionID: "s1", callsign: "A"))
        store.upsert(OpenSessionRecord(cwd: "/b", sessionID: "s2", callsign: "B"))
        store.upsert(OpenSessionRecord(cwd: "/a2", sessionID: "s1", callsign: "A2")) // upsert by id
        XCTAssertEqual(store.all().map(\.sessionID), ["s2", "s1"])
        XCTAssertEqual(store.all().last?.cwd, "/a2")
        store.remove(sessionID: "s2")
        XCTAssertEqual(store.all().map(\.sessionID), ["s1"])
    }

    func testCommissionRecordsThenDeleteForgets() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        let manager = manager(store)
        let s = manager.commission(callsign: "ai", cwd: "/Users/me/code/ai")
        let sid = s.claudeSessionID!
        XCTAssertEqual(store.all().map(\.sessionID), [sid], "commission records the open session")

        manager.delete(s.id)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.selectedID)
        XCTAssertTrue(store.all().isEmpty, "deleted session is forgotten (won't restore)")
    }

    func testDeleteTerminatesTheProcess() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/usr/bin/claude",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        let s = manager.commission(callsign: "ai", cwd: "/x")
        manager.delete(s.id)
        XCTAssertEqual(host.terminatedPIDs.count, 1, "the child process must be terminated on delete")
    }

    func testMoveReordersSessionsAndPersistsOrder() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        let manager = manager(store)
        let a = manager.commission(callsign: "a", cwd: "/a")
        let b = manager.commission(callsign: "b", cwd: "/b")
        let c = manager.commission(callsign: "c", cwd: "/c")
        XCTAssertEqual(manager.sessions.map(\.callsign), ["a", "b", "c"])

        manager.move(c.id, before: a.id)   // c to the front
        XCTAssertEqual(manager.sessions.map(\.callsign), ["c", "a", "b"])
        // The restore order is persisted in the same order.
        XCTAssertEqual(store.all().map(\.callsign), ["c", "a", "b"])
        _ = b
    }

    func testMoveByDeltaReordersClampsAndPersists() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        let manager = manager(store)
        let a = manager.commission(callsign: "a", cwd: "/a")
        let b = manager.commission(callsign: "b", cwd: "/b")
        let c = manager.commission(callsign: "c", cwd: "/c")
        XCTAssertEqual(manager.sessions.map(\.callsign), ["a", "b", "c"])

        XCTAssertTrue(manager.move(c.id, by: -1))   // c up one
        XCTAssertEqual(manager.sessions.map(\.callsign), ["a", "c", "b"])
        XCTAssertEqual(store.all().map(\.callsign), ["a", "c", "b"], "new order is persisted")

        XCTAssertTrue(manager.move(a.id, by: 1))    // a down one
        XCTAssertEqual(manager.sessions.map(\.callsign), ["c", "a", "b"])

        XCTAssertFalse(manager.move(c.id, by: -1), "top item clamps — no move")
        XCTAssertFalse(manager.move(b.id, by: 1), "bottom item clamps — no move")
        XCTAssertEqual(manager.sessions.map(\.callsign), ["c", "a", "b"])
    }

    func testRefreshStatusesMatchesBySessionIdKeepingFreshest() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        let sessionsDir = home.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        // Two files for one sessionId (two app instances resumed it); the fresher one wins.
        try #"{"pid":111,"sessionId":"abc-123","status":"idle","updatedAt":100}"#
            .write(to: sessionsDir.appendingPathComponent("111.json"), atomically: true, encoding: .utf8)
        try #"{"pid":222,"sessionId":"abc-123","status":"busy","updatedAt":200}"#
            .write(to: sessionsDir.appendingPathComponent("222.json"), atomically: true, encoding: .utf8)

        let manager = SessionManager(
            host: FakeTerminalHost(), claudeHome: home, executablePath: "/bin/echo")
        manager.register(AgentSession(callsign: "a", cwd: "/a", claudeSessionID: "abc-123", status: .unknown))
        manager.register(AgentSession(callsign: "b", cwd: "/b", claudeSessionID: "no-file", status: .unknown))

        manager.refreshStatuses()

        XCTAssertEqual(manager.sessions.first { $0.callsign == "a" }?.status, .busy,
                       "matched by sessionId; the freshest file (busy) wins over the stale idle one")
        XCTAssertEqual(manager.sessions.first { $0.callsign == "b" }?.status, .unknown,
                       "no matching file and no pid → status left untouched")
    }

    /// Claude writes `"shell"` for a finished turn with a background task still running. The
    /// session is idle; only Admiral's own exit marker means the process is gone.
    func testClaudesShellStatusIsIdleNotExited() {
        XCTAssertEqual(SessionStatus(raw: "shell"), .idle)
        XCTAssertEqual(SessionStatus(raw: "idle"), .idle)
        XCTAssertEqual(SessionStatus(raw: "busy"), .busy)
        XCTAssertEqual(SessionStatus(raw: "waiting"), .unknown)
        XCTAssertEqual(SessionStatus(raw: nil), .unknown)
    }

    /// busy → idle on a tab you're NOT on flags "unseen work"; visiting clears it; a fresh
    /// busy → idle after the visit re-flags it.
    func testUnseenWorkFlagsOnCompletionAndClearsOnVisit() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        let sessionsDir = home.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let file = sessionsDir.appendingPathComponent("111.json")
        func write(_ status: String, _ updatedAt: Int) throws {
            try "{\"pid\":111,\"sessionId\":\"sid-1\",\"status\":\"\(status)\",\"updatedAt\":\(updatedAt)}"
                .write(to: file, atomically: true, encoding: .utf8)
        }

        let manager = SessionManager(host: FakeTerminalHost(), claudeHome: home, executablePath: "/bin/echo")
        manager.register(AgentSession(callsign: "worker", cwd: "/w", claudeSessionID: "sid-1", status: .unknown))
        manager.register(AgentSession(callsign: "other", cwd: "/o", claudeSessionID: "sid-other", status: .unknown))
        func worker() -> AgentSession { manager.sessions.first { $0.callsign == "worker" }! }
        let workerID = worker().id
        let otherID = manager.sessions.first { $0.callsign == "other" }!.id
        manager.selectedID = otherID   // you're looking at a different tab

        try write("busy", 100); manager.refreshStatuses()
        XCTAssertFalse(worker().hasUnseenWork, "still working — no completion yet")

        try write("idle", 200); manager.refreshStatuses()
        XCTAssertTrue(worker().hasUnseenWork, "finished on an unvisited tab → unseen work")

        manager.selectedID = workerID
        XCTAssertFalse(worker().hasUnseenWork, "visiting the tab marks it seen")

        // A new burst that completes while you're on another tab re-flags it.
        manager.selectedID = otherID
        try write("busy", 300); manager.refreshStatuses()
        try write("idle", 400); manager.refreshStatuses()
        XCTAssertTrue(worker().hasUnseenWork, "a fresh completion after the visit re-flags")
    }

    /// No false positives: the tab you're on never lights up, and a restored session that
    /// comes up idle (no prior busy) is not treated as a completion.
    func testUnseenWorkNotFlaggedForSelectedTabOrWithoutPriorBusy() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        let sessionsDir = home.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        func write(_ pid: Int, _ sid: String, _ status: String, _ updatedAt: Int) throws {
            try "{\"pid\":\(pid),\"sessionId\":\"\(sid)\",\"status\":\"\(status)\",\"updatedAt\":\(updatedAt)}"
                .write(to: sessionsDir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        }

        let manager = SessionManager(host: FakeTerminalHost(), claudeHome: home, executablePath: "/bin/echo")
        manager.register(AgentSession(callsign: "selected", cwd: "/s", claudeSessionID: "sel", status: .unknown))
        manager.register(AgentSession(callsign: "restored", cwd: "/r", claudeSessionID: "res", status: .unknown))
        let selectedID = manager.sessions[0].id
        manager.selectedID = selectedID   // you're looking at it

        try write(11, "sel", "busy", 100); try write(22, "res", "idle", 100)
        manager.refreshStatuses()
        try write(11, "sel", "idle", 200)
        manager.refreshStatuses()

        XCTAssertFalse(manager.sessions.first { $0.callsign == "selected" }!.hasUnseenWork,
                       "the tab you're viewing never flags unseen")
        XCTAssertFalse(manager.sessions.first { $0.callsign == "restored" }!.hasUnseenWork,
                       "idle without a prior busy (a restored session) is not a completion")
    }

    /// Deleting the selected tab moves to an adjacent one — next, or previous if it was the
    /// last — instead of jumping to the top of the list.
    func testDeleteSelectsAdjacentNotTop() {
        func fresh() -> SessionManager {
            SessionManager(host: FakeTerminalHost(),
                           claudeHome: URL(fileURLWithPath: "/tmp/none-\(UUID().uuidString)"),
                           executablePath: "/bin/echo")
        }
        func seed(_ m: SessionManager) {
            m.register(AgentSession(callsign: "a", cwd: "/a"))
            m.register(AgentSession(callsign: "b", cwd: "/b"))
            m.register(AgentSession(callsign: "c", cwd: "/c"))
        }
        func id(_ m: SessionManager, _ n: String) -> UUID { m.sessions.first { $0.callsign == n }!.id }

        // Selected middle → next.
        let m1 = fresh(); seed(m1); m1.selectedID = id(m1, "b")
        m1.delete(id(m1, "b"))
        XCTAssertEqual(m1.selectedID, id(m1, "c"), "deleting the selected middle tab selects the next")

        // Selected last → previous.
        let m2 = fresh(); seed(m2); m2.selectedID = id(m2, "c")
        m2.delete(id(m2, "c"))
        XCTAssertEqual(m2.selectedID, id(m2, "b"), "deleting the selected last tab selects the previous")

        // Deleting a non-selected tab leaves the selection where it is.
        let m3 = fresh(); seed(m3); m3.selectedID = id(m3, "a")
        m3.delete(id(m3, "c"))
        XCTAssertEqual(m3.selectedID, id(m3, "a"), "deleting another tab doesn't move selection")

        // The last remaining tab → no selection.
        let m4 = fresh(); m4.register(AgentSession(callsign: "solo", cwd: "/s"))
        m4.delete(id(m4, "solo"))
        XCTAssertNil(m4.selectedID, "deleting the last tab clears selection")
    }

    func testResumeUsesResumeFlag() {
        let host = FakeTerminalHost()
        let claude = AgentType(
            id: "claude_code", displayName: "Claude", executableName: "zsh",
            defaultArgs: ["-ilc", "exec 'claude' --permission-mode bypassPermissions --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles"
        )
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        let s = manager.commission(callsign: "ai", cwd: "/x", agentType: claude, sessionID: "abc-123", resume: true)
        XCTAssertEqual(s.claudeSessionID, "abc-123", "resumed session reuses the saved id")
        let cmd = host.spawned.first?.args.joined(separator: " ") ?? ""
        XCTAssertTrue(cmd.contains("--resume abc-123"), "must resume via --resume; got: \(cmd)")
        XCTAssertFalse(cmd.contains("--session-id"), "must not also pass --session-id")
    }

    /// A recipe carrying the name placeholder gets `--name '<display title>'` at spawn, so
    /// claude's own session name matches the tab. A rename before relaunch flows through too.
    func testCommissionPassesTabNameViaNameFlag() {
        let host = FakeTerminalHost()
        let claude = AgentType(
            id: "claude_code", displayName: "Claude", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder) --name \(SessionManager.sessionNamePlaceholder)"],
            symbolName: "sparkles"
        )
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        _ = manager.commission(callsign: "worker", cwd: "/x", agentType: claude, sessionID: "abc-123")
        let cmd = host.spawned.first?.args.joined(separator: " ") ?? ""
        XCTAssertTrue(cmd.contains("--name 'worker'"), "spawns with the tab name via --name; got: \(cmd)")
        XCTAssertFalse(cmd.contains(SessionManager.sessionNamePlaceholder), "the placeholder is fully substituted")
    }

    /// An apostrophe in the tab name is shell-escaped so the `zsh -ilc` command string stays valid.
    func testCommissionShellEscapesNameWithApostrophe() {
        let host = FakeTerminalHost()
        let claude = AgentType(
            id: "claude_code", displayName: "Claude", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder) --name \(SessionManager.sessionNamePlaceholder)"],
            symbolName: "sparkles"
        )
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        let s = manager.commission(callsign: "worker", cwd: "/x", agentType: claude, sessionID: "abc-123")
        manager.rename(s.id, to: "Sam's tab")
        // Rename doesn't relaunch; a reload (or restore) is what re-spawns with the new name.
        manager.reload(s.id)
        let cmd = host.spawned.last?.args.joined(separator: " ") ?? ""
        XCTAssertTrue(cmd.contains(#"--name 'Sam'\''s-tab'"#), "apostrophe is POSIX-escaped; got: \(cmd)")
    }

    /// Bash (no session-id placeholder ⇒ no name placeholder either) never gets `--name`.
    func testCommissionOmitsNameForUnmanagedShell() {
        let host = FakeTerminalHost()
        let bash = AgentType(
            id: "bash", displayName: "Bash", executableName: "zsh",
            defaultArgs: ["-il"], symbolName: "terminal"
        )
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        _ = manager.commission(callsign: "shell", cwd: "/x", agentType: bash)
        let cmd = host.spawned.first?.args.joined(separator: " ") ?? ""
        XCTAssertFalse(cmd.contains("--name"), "an unmanaged shell gets no --name; got: \(cmd)")
    }

    /// Reload kills the running process, relaunches at the SAME claude session id (resuming a
    /// transcript when one exists), keeps the tab in place, and doesn't move the selection.
    func testReloadKillsAndRelaunchesSameSessionInPlace() {
        let host = FakeTerminalHost()
        let claude = AgentType(
            id: "claude_code", displayName: "Claude", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles"
        )
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            defaultAgentType: claude,
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        let a = manager.commission(callsign: "a", cwd: "/a", agentType: claude)
        let b = manager.commission(callsign: "b", cwd: "/b", agentType: claude)
        let c = manager.commission(callsign: "c", cwd: "/c", agentType: claude)
        let bSid = b.claudeSessionID!
        manager.selectedID = a.id   // looking at a DIFFERENT tab than the one we reload

        let reloaded = manager.reload(b.id)

        XCTAssertEqual(host.terminatedPIDs.count, 1, "reload terminates the old process")
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded?.claudeSessionID, bSid, "relaunches as the SAME claude session")
        XCTAssertNotEqual(reloaded?.id, b.id, "a fresh AgentSession identity backs the new process")
        XCTAssertEqual(manager.sessions.map(\.callsign), ["a", "b", "c"], "the tab stays in its slot")
        XCTAssertEqual(manager.selectedID, a.id, "reloading a background tab doesn't steal selection")
        _ = c
    }

    /// Reloading the SELECTED tab keeps the selection on it (via its new identity).
    func testReloadKeepsSelectionWhenReloadingSelectedTab() {
        let host = FakeTerminalHost()
        let claude = AgentType(
            id: "claude_code", displayName: "Claude", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles"
        )
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            defaultAgentType: claude,
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        let a = manager.commission(callsign: "a", cwd: "/a", agentType: claude)
        manager.selectedID = a.id
        let reloaded = manager.reload(a.id)
        XCTAssertEqual(manager.selectedID, reloaded?.id, "the reloaded selected tab stays selected")
    }

    func testReuseSessionIDWithoutResumeUsesSessionIDFlag() {
        let host = FakeTerminalHost()
        let claude = AgentType(
            id: "claude_code", displayName: "Claude", executableName: "zsh",
            defaultArgs: ["-ilc", "exec 'claude' --permission-mode bypassPermissions --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles"
        )
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults())
        )
        // An empty session (no transcript) reopens fresh at the SAME id via --session-id.
        let s = manager.commission(callsign: "ai", cwd: "/x", agentType: claude, sessionID: "def-456", resume: false)
        XCTAssertEqual(s.claudeSessionID, "def-456")
        let cmd = host.spawned.first?.args.joined(separator: " ") ?? ""
        XCTAssertTrue(cmd.contains("--session-id def-456"), "must recreate via --session-id; got: \(cmd)")
        XCTAssertFalse(cmd.contains("--resume"), "must not resume a non-existent session")
    }
}
