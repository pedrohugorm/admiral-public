import XCTest
@testable import AdmiralCore

@MainActor
final class SessionManagerTests: XCTestCase {
    func testCommissionRegistersAndSelects() throws {
        let host = FakeTerminalHost()
        host.nextPID = 5150
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/usr/bin/claude"
        )
        let session = manager.commission(callsign: "Scheduled-ordering", cwd: "/tmp")
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.selectedID, session.id)
        XCTAssertEqual(session.claudePID, 5150)
        XCTAssertNotNil(session.spawnedAt, "spawn time recorded for transcript isolation")
        // A session id is generated and passed to claude via --session-id, with the
        // placeholder swapped for that id.
        let sid = try XCTUnwrap(session.claudeSessionID)
        XCTAssertEqual(host.spawned.first?.executable, "/usr/bin/claude")
        XCTAssertEqual(host.spawned.first?.args, ["--permission-mode", "bypassPermissions", "--session-id", sid])
        XCTAssertFalse(host.spawned.first?.args.contains(SessionManager.sessionIDPlaceholder) ?? true,
                       "placeholder must be substituted, not passed literally")
    }

    /// Per-terminal isolation: an Admiral-spawned session resolves ONLY its own
    /// transcript (named by the session id we passed via --session-id), never a decoy
    /// file from another session in the same workspace dir — then tails it. Pure + fast.
    func testOwnSpawnResolvesItsExactSessionTranscript() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("admiral-home-\(UUID().uuidString)")
        let cwd = home.appendingPathComponent("work").path
        let projectDir = home.appendingPathComponent("projects/\(TranscriptLocator.encodeProjectDir(cwd))")
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let host = FakeTerminalHost()
        host.spawnsWithoutPID = true  // claudePID == nil, like a fresh SwiftTerm spawn
        let manager = SessionManager(host: host, claudeHome: home, executablePath: "/usr/bin/claude")
        let session = manager.commission(callsign: "x", cwd: cwd)
        let sid = try XCTUnwrap(session.claudeSessionID)

        // Another session's transcript in the SAME dir — must never be adopted.
        let decoy = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (1...20).map { #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DECOY \#($0)"}]}}"# }
            .joined(separator: "\n").write(to: decoy, atomically: true, encoding: .utf8)
        // THIS session's transcript, named by the id we assigned.
        let mine = projectDir.appendingPathComponent("\(sid).jsonl")
        try ([
            #"{"type":"user","message":{"role":"user","content":"build the thing"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#,
        ].joined(separator: "\n")).write(to: mine, atomically: true, encoding: .utf8)

        var convo = manager.conversations[session.id] ?? .empty
        for _ in 0..<50 where convo.turns.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
            manager.resolveTranscript(for: session.id)
            convo = manager.conversations[session.id] ?? .empty
        }
        XCTAssertEqual(convo.turns.count, 2, "must resolve THIS session's exact transcript, not the decoy")
        let resolvedPath = manager.selectedSession?.transcriptPath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        XCTAssertEqual(resolvedPath, mine.resolvingSymlinksInPath().path)
    }

    /// Hosted claude must NOT inherit Claude Code's nested-session markers, or it runs as
    /// a child session that never persists a transcript (the Transcript view's data).
    func testCommissionStripsClaudeCodeEnvMarkers() {
        setenv("CLAUDECODE", "1", 1)
        setenv("CLAUDE_CODE_CHILD_SESSION", "abc", 1)
        setenv("ANTHROPIC_API_KEY", "keep-me", 1)
        defer { unsetenv("CLAUDECODE"); unsetenv("CLAUDE_CODE_CHILD_SESSION"); unsetenv("ANTHROPIC_API_KEY") }

        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"), executablePath: "/usr/bin/claude"
        )
        _ = manager.commission(callsign: "x", cwd: "/tmp")
        XCTAssertNil(host.lastEnv["CLAUDECODE"], "CLAUDECODE must be stripped")
        XCTAssertNil(host.lastEnv["CLAUDE_CODE_CHILD_SESSION"], "child-session marker must be stripped")
        XCTAssertEqual(host.lastEnv["ANTHROPIC_API_KEY"], "keep-me", "auth env must be preserved")

        XCTAssertTrue(SessionManager.inheritedAgentMarkers("CLAUDE_CODE_ENTRYPOINT"))
        XCTAssertFalse(SessionManager.inheritedAgentMarkers("CLAUDE_CONFIG_DIR"))
        XCTAssertFalse(SessionManager.inheritedAgentMarkers("PATH"))
    }

    /// SwiftTerm renders 24-bit SGR exactly, but TUIs only emit it when the environment says
    /// the terminal can take it. Without COLORTERM, chalk (claude) drops to level 2 and Rich
    /// (hermes) to EIGHT_BIT, quantizing every color onto the 256-cube — which is the washed-out
    /// look. TERM_PROGRAM=Admiral means nothing to those probes, so COLORTERM is the only signal.
    func testCommissionAdvertisesTrueColor() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"), executablePath: "/usr/bin/claude"
        )
        _ = manager.commission(callsign: "x", cwd: "/tmp")

        XCTAssertEqual(host.lastEnv["TERM"], "xterm-256color")
        XCTAssertEqual(host.lastEnv["COLORTERM"], "truecolor",
                       "hosted agents must be told the terminal is 24-bit, or they downsample")
    }

    /// GUI launchers (Cursor, shells) often export NO_COLOR=1 / FORCE_COLOR=0; if those ride
    /// into the hosted claude, chalk emits no SGR and the TUI looks black-and-white even with
    /// COLORTERM=truecolor. Strip the killers and force level 3.
    func testCommissionStripsColorKillersAndForcesColor() {
        setenv("NO_COLOR", "1", 1)
        setenv("NODE_DISABLE_COLORS", "1", 1)
        setenv("FORCE_COLOR", "0", 1)
        defer {
            unsetenv("NO_COLOR")
            unsetenv("NODE_DISABLE_COLORS")
            unsetenv("FORCE_COLOR")
        }

        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"), executablePath: "/usr/bin/claude"
        )
        _ = manager.commission(callsign: "x", cwd: "/tmp")

        XCTAssertNil(host.lastEnv["NO_COLOR"], "NO_COLOR must not reach hosted claude")
        XCTAssertNil(host.lastEnv["NODE_DISABLE_COLORS"])
        XCTAssertEqual(host.lastEnv["FORCE_COLOR"], "3")
        XCTAssertEqual(host.lastEnv["COLORTERM"], "truecolor")
    }

    func testCommissionSetsUTF8LocaleWhenMissing() {
        // A macOS GUI app inherits no shell locale; clear them to simulate that launch.
        unsetenv("LANG"); unsetenv("LC_ALL"); unsetenv("LC_CTYPE")

        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"), executablePath: "/usr/bin/claude"
        )
        _ = manager.commission(callsign: "x", cwd: "/tmp")

        let lang = host.lastEnv["LANG"] ?? ""
        XCTAssertTrue(lang.lowercased().contains("utf-8"),
                      "hosted claude must run under a UTF-8 locale, got LANG=\(lang)")
    }

    func testUTF8LocaleRespectsAnExistingChoice() {
        // An explicit UTF-8 locale already in the environment must not be overridden.
        XCTAssertFalse(SessionManager.needsUTF8Locale(["LANG": "pt_PT.UTF-8"]))
        XCTAssertFalse(SessionManager.needsUTF8Locale(["LC_CTYPE": "en_GB.utf8"]))
        XCTAssertFalse(SessionManager.needsUTF8Locale(["LC_ALL": "C.UTF-8"]))
        // The C locale (or nothing at all) is exactly what produces the Mac Roman mojibake.
        XCTAssertTrue(SessionManager.needsUTF8Locale([:]))
        XCTAssertTrue(SessionManager.needsUTF8Locale(["LANG": "C"]))
        XCTAssertTrue(SessionManager.needsUTF8Locale(["LANG": "en_US"]))
        XCTAssertTrue(SessionManager.preferredUTF8Locale.lowercased().contains("utf-8"))
    }

    /// The PostToolUse hook is a claude concern: a managed session (its argv carries the
    /// session-id placeholder) gets `--settings` appended, but an unmanaged plain shell does
    /// NOT — appending it to `zsh -il` would break the launch.
    func testHookSettingsInjectedOnlyForManagedSessions() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-hooktest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }

        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/zsh",
            supportDir: support,
            hookHelper: "/x/admiral-hook"
        )

        // Managed claude session → hook appended to the last launch arg.
        let claude = AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles"
        )
        _ = manager.commission(callsign: "agent", cwd: "/tmp", agentType: claude)
        let claudeArgs = try XCTUnwrap(host.spawned.last?.args)
        XCTAssertTrue(claudeArgs.last?.contains("--settings") ?? false,
                      "a managed claude session must get the PostToolUse hook via --settings")

        // Unmanaged bash shell (no session-id placeholder) → launches with exactly its args.
        let bash = AgentType(
            id: "bash", displayName: "Bash", executableName: "zsh",
            defaultArgs: ["-il"], symbolName: "terminal"
        )
        let shell = manager.commission(callsign: "shell", cwd: "/tmp", agentType: bash)
        XCTAssertEqual(host.spawned.last?.args, ["-il"],
                       "an unmanaged bash session launches with no --settings injected")
        XCTAssertNotNil(shell.claudeSessionID, "bash tabs get a persistent id for restore")
        XCTAssertEqual(shell.agentType.id, "bash")
    }

    func testBashCommissionPersistsForRestore() {
        let defaults = UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
        let store = OpenSessionsStore(defaults: defaults)
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/zsh",
            openSessionsStore: store
        )
        let bash = AgentType(
            id: "bash", displayName: "Bash", executableName: "zsh",
            defaultArgs: ["-il"], symbolName: "terminal"
        )
        let shell = manager.commission(callsign: "KEYS", cwd: "/Users/me", agentType: bash)
        let records = store.all()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].callsign, "KEYS")
        XCTAssertEqual(records[0].agentTypeID, "bash")
        XCTAssertEqual(records[0].sessionID, shell.claudeSessionID)
        XCTAssertTrue(records[0].isBash)
    }

    func testSendSubmitsTextThenReturn() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/usr/bin/claude"
        )
        let session = manager.commission(callsign: "x", cwd: "/tmp")
        manager.send(session.id, text: "run the tests")
        XCTAssertEqual(host.sent.suffix(2), ["run the tests", "\r"])
    }

    private func manager() -> SessionManager {
        SessionManager(host: FakeTerminalHost(),
                       claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                       executablePath: "/usr/bin/claude")
    }

    // A tab must never be nameless. The new-tab form validates, but the bridge
    // `commission` tool passes its `callsign` arg straight through — an empty one
    // used to render a blank tab (displayTitle fell back to the empty callsign).
    func testCommissionDefaultsEmptyCallsignToFolderName() {
        let session = manager().commission(callsign: "", cwd: "/tmp/myproj")
        XCTAssertEqual(session.callsign, "myproj", "empty callsign falls back to the cwd folder")
        XCTAssertFalse(session.displayTitle.isEmpty)
    }

    func testCommissionDefaultsWhitespaceCallsign() {
        let session = manager().commission(callsign: "   ", cwd: "/tmp/myproj")
        XCTAssertEqual(session.callsign, "myproj")
    }

    func testCommissionEmptyCallsignAndCwdFallsBackToGenericName() {
        let session = manager().commission(callsign: "  ", cwd: "/")
        XCTAssertEqual(session.callsign, "session")
        XCTAssertFalse(session.displayTitle.isEmpty)
    }

    // Safety net: an already-persisted session with an empty callsign (created before
    // the guard) still shows a name rather than a blank row.
    func testDisplayTitleNeverBlankForEmptyCallsign() {
        let bare = AgentSession(callsign: "", cwd: "/tmp")
        XCTAssertFalse(bare.displayTitle.isEmpty)
    }

    // On app quit terminateAll() kills every live process but must NOT delete the tabs —
    // they (and their transcripts) have to restore on the next launch.
    func testTerminateAllKillsEveryProcessButKeepsTabsForRestore() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/usr/bin/claude"
        )
        host.nextPID = 4242
        _ = manager.commission(callsign: "a", cwd: "/tmp")
        host.nextPID = 4243
        _ = manager.commission(callsign: "b", cwd: "/tmp")

        manager.terminateAll()

        // Every live process was terminated…
        XCTAssertEqual(host.terminatedPIDs.compactMap { $0 }.sorted(), [4242, 4243])
        // …but the tabs themselves are untouched, so they restore on relaunch.
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.sessions.map(\.callsign).sorted(), ["a", "b"])
    }
}
