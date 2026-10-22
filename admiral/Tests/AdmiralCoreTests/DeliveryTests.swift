import XCTest
@testable import AdmiralCore

/// How Admiral's own messages reach a tab: over claude's messaging socket when the tab was
/// launched accepting peer messages, typed into it otherwise — and typed whenever the socket
/// cannot take it, so the message is never lost.
@MainActor
final class DeliveryTests: XCTestCase {
    private var fm: FileManager { .default }
    private var root: URL!
    private var claudeHome: URL!
    private var support: URL!
    private var host: FakeTerminalHost!
    private var manager: SessionManager!
    /// What went over the socket, by session id.
    private var socketed: [(sid: String, body: String)] = []
    private var socketFails = false

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString)")
        claudeHome = root.appendingPathComponent("claude")
        support = root.appendingPathComponent("support")
        try fm.createDirectory(at: claudeHome.appendingPathComponent("sessions"),
                               withIntermediateDirectories: true)
        host = FakeTerminalHost()
        socketed = []
        socketFails = false
        manager = SessionManager(host: host, claudeHome: claudeHome,
                                 executablePath: "/bin/echo", supportDir: support)
        manager.sendPeerMessage = { [unowned self] body, file, _ in
            if socketFails { throw ClaudeMessagingSocket.DeliveryError.unreachable("refused") }
            socketed.append((file.sessionId ?? "", body))
        }
    }

    override func tearDown() { try? fm.removeItem(at: root) }

    /// A live claude with a messaging socket, as `~/.claude/sessions/<pid>.json` shows it.
    private func publishSocket(sid: String, pid: Int = 4242) throws {
        let sock = root.appendingPathComponent("\(pid).sock")
        fm.createFile(atPath: sock.path, contents: Data())
        try #"{"pid":\#(pid),"sessionId":"\#(sid)","status":"idle","messagingSocketPath":"\#(sock.path)"}"#
            .write(to: claudeHome.appendingPathComponent("sessions/\(pid).json"),
                   atomically: true, encoding: .utf8)
    }

    private func tab(_ sid: String, accepts: Bool) -> AgentSession {
        var s = AgentSession(callsign: sid, cwd: "/tmp", claudeSessionID: sid, status: .idle)
        s.acceptsPeerMessages = accepts
        manager.register(s, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                               cwd: "/tmp", onExit: { _ in }))
        return s
    }

    private var typed: [String] { host.sent.filter { $0 != "\r" } }

    func testATabThatAcceptsGetsItOverTheSocketAndNothingIsTyped() throws {
        try publishSocket(sid: "sid-a")
        let s = tab("sid-a", accepts: true)
        XCTAssertTrue(manager.deliver(s.id, text: "PR WATCH — news"))
        XCTAssertEqual(socketed.map(\.body), ["PR WATCH — news"])
        XCTAssertEqual(typed, [], "never typed on top of what the user is writing")
    }

    func testATabLaunchedWithoutItIsTypedInto() throws {
        try publishSocket(sid: "sid-b")
        let s = tab("sid-b", accepts: false)
        XCTAssertTrue(manager.deliver(s.id, text: "PR WATCH — news"))
        XCTAssertTrue(socketed.isEmpty, "its claude would hold a socket message, not deliver it")
        XCTAssertEqual(typed, ["PR WATCH — news"])
    }

    func testASocketThatRefusesFallsBackToTyping() throws {
        try publishSocket(sid: "sid-c")
        socketFails = true
        let s = tab("sid-c", accepts: true)
        XCTAssertTrue(manager.deliver(s.id, text: "WATCHDOG CHECK"))
        XCTAssertEqual(typed, ["WATCHDOG CHECK"], "the message is never lost")
    }

    func testNoPublishedSocketFallsBackToTyping() {
        let s = tab("sid-d", accepts: true)
        XCTAssertTrue(manager.deliver(s.id, text: "WATCHDOG CHECK"))
        XCTAssertTrue(socketed.isEmpty)
        XCTAssertEqual(typed, ["WATCHDOG CHECK"])
    }

    // MARK: - The setting reaches the tab at launch

    private func zsh() -> AgentType {
        AgentType(id: "claude_code", displayName: "Claude Code", executableName: "zsh",
                  defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
                  symbolName: "sparkles")
    }

    private func launch(accepting: Bool) throws -> (AgentSession, [String: Any]) {
        let m = SessionManager(host: host, claudeHome: claudeHome, executablePath: "/bin/zsh",
                               defaultAgentType: zsh(), supportDir: support,
                               hookHelper: "/X/admiral-hook")
        m.acceptPeerMessages = { accepting }
        let s = m.commission(callsign: "x", cwd: "/tmp")
        let data = try Data(contentsOf: AdmiralPaths.settingsFile(base: support, token: s.token))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (try XCTUnwrap(m.sessions.first { $0.id == s.id }), obj)
    }

    func testTheSettingOnLaunchesATabThatAcceptsAndKnowsIt() throws {
        let (s, settings) = try launch(accepting: true)
        XCTAssertEqual(settings["crossSessionInbound"] as? String, "accept")
        XCTAssertTrue(s.acceptsPeerMessages)
    }

    func testTheSettingOffLeavesClaudesDefaultAndTheTabTyped() throws {
        let (s, settings) = try launch(accepting: false)
        XCTAssertNil(settings["crossSessionInbound"])
        XCTAssertFalse(s.acceptsPeerMessages)
    }

    /// Options saved before the setting existed carry no value; the default is on.
    func testSavedOptionsWithoutTheSettingDefaultToOn() throws {
        let old = #"{"managed":true,"permissionMode":"bypassPermissions","appendSystemPrompt":true,"extraFlags":""}"#
        let options = try JSONDecoder().decode(LaunchOptions.self, from: Data(old.utf8))
        XCTAssertTrue(options.acceptsPeerMessages)
        XCTAssertTrue(LaunchOptions().acceptsPeerMessages)
    }
}
