import XCTest
@testable import AdmiralCore

/// The gate every native notification passes through, and the hook payload → notification
/// mapping. Both pure, so they are tested without the app.
final class NotificationPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "notif-policy-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func allowed(_ kind: NotificationKind, viewing: Bool = false) -> Bool {
        NotificationPolicy.shouldPost(kind, viewing: viewing, defaults: defaults)
    }

    func testDefaultsAreEverythingOnExceptNudges() {
        for kind in NotificationKind.allCases { XCTAssertEqual(allowed(kind), kind != .nudge, "\(kind)") }
        XCTAssertTrue(allowed(.done), "a finished tab notifies by default")
        XCTAssertFalse(allowed(.nudge), "nudges are opt-in")
    }

    func testStoredNudgeValueIsRespected() {
        defaults.set(true, forKey: NotificationPolicy.nudgeKey)
        XCTAssertTrue(allowed(.nudge))
        defaults.set(false, forKey: NotificationPolicy.nudgeKey)
        XCTAssertFalse(allowed(.nudge))
    }

    func testMasterOffBlocksNudgeEvenWhenOptedIn() {
        defaults.set(true, forKey: NotificationPolicy.nudgeKey)
        defaults.set(false, forKey: NotificationPolicy.masterKey)
        XCTAssertFalse(allowed(.nudge))
        XCTAssertFalse(allowed(.done))
    }

    func testKeysAreUnderTheDocumentedNames() {
        XCTAssertEqual(NotificationPolicy.masterKey, "admiral.notificationsEnabled")
        XCTAssertEqual(NotificationKind.question.defaultsKey, "admiral.notify.question")
        XCTAssertEqual(NotificationKind.needsInput.defaultsKey, "admiral.notify.needsInput")
        XCTAssertEqual(NotificationKind.terminal.defaultsKey, "admiral.notify.terminal")
        XCTAssertEqual(NotificationKind.done.defaultsKey, "admiral.notify.done")
        XCTAssertEqual(NotificationKind.nudge.defaultsKey, "admiral.notify.nudge")
        XCTAssertNil(NotificationKind.agent.defaultsKey)
    }

    /// The master gates ALL posts — including the nudges and the `notify` tool, which used
    /// to bypass it.
    func testMasterOffBlocksEveryKind() {
        defaults.set(false, forKey: NotificationPolicy.masterKey)
        for kind in NotificationKind.allCases { XCTAssertFalse(allowed(kind), "\(kind)") }
    }

    func testEachToggleBlocksOnlyItsOwnKind() {
        let toggles: [(String, NotificationKind)] = [
            (NotificationPolicy.questionKey, .question), (NotificationPolicy.needsInputKey, .needsInput),
            (NotificationPolicy.terminalKey, .terminal), (NotificationPolicy.doneKey, .done),
            (NotificationPolicy.nudgeKey, .nudge),
        ]
        for (key, off) in toggles {
            defaults.set(false, forKey: key)
            for kind in NotificationKind.allCases {
                // Everything is on except the opt-in nudge kind, and the toggled one is off.
                XCTAssertEqual(allowed(kind), kind != off && kind != .nudge, "\(key) / \(kind)")
            }
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: NotificationPolicy.nudgeKey)
        XCTAssertTrue(allowed(.nudge))
        XCTAssertTrue(allowed(.done), "opting in to nudges changes nothing else")
    }

    func testViewingSuppressesOnlyTerminalAndNeedsInput() {
        XCTAssertFalse(allowed(.terminal, viewing: true))
        XCTAssertFalse(allowed(.needsInput, viewing: true))
        XCTAssertTrue(allowed(.question, viewing: true), "a question always notifies")
        XCTAssertFalse(allowed(.nudge, viewing: true), "off by default")
        XCTAssertTrue(allowed(.done, viewing: true))
        XCTAssertTrue(allowed(.agent, viewing: true))
    }

    // MARK: - hook payload → notification

    private func map(_ event: String, _ json: String) -> HookNotification? {
        HookNotification.from(event: event, payload: Data(json.utf8))
    }

    func testAskUserQuestionUsesTheFirstQuestion() throws {
        let note = try XCTUnwrap(map("PreToolUse", #"""
            {"tool_name":"AskUserQuestion","tool_input":{"questions":[
              {"question":"Which database should we use?","header":"DB","options":[]},
              {"question":"Second?"}]}}
            """#))
        XCTAssertEqual(note, HookNotification(kind: .question, titleSuffix: "is asking",
                                              body: "Which database should we use?"))
    }

    func testLongQuestionIsTruncatedAndFlattened() throws {
        let long = String(repeating: "word ", count: 100) + "\nend"
        let json = try String(data: JSONSerialization.data(withJSONObject: [
            "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": long]]]]), encoding: .utf8)!
        let note = try XCTUnwrap(map("PreToolUse", json))
        XCTAssertEqual(note.body.count, HookNotification.maxBody)
        XCTAssertTrue(note.body.hasSuffix("…"))
        XCTAssertFalse(note.body.contains("\n"))
    }

    func testQuestionWithoutTextStillNotifies() throws {
        let note = try XCTUnwrap(map("PreToolUse", #"{"tool_name":"AskUserQuestion","tool_input":{}}"#))
        XCTAssertEqual(note.kind, .question)
        XCTAssertFalse(note.body.isEmpty)
    }

    func testOtherToolsAndBadPayloadsSayNothing() {
        XCTAssertNil(map("PreToolUse", #"{"tool_name":"Bash","tool_input":{}}"#))
        XCTAssertNil(map("PreToolUse", "not json"))
        XCTAssertNil(map("Stop", #"{"tool_name":"AskUserQuestion"}"#))
    }

    func testBlockingNotificationTypesMapToNeedsYou() throws {
        for type in ["permission_prompt", "elicitation_dialog", "idle_prompt", "agent_needs_input"] {
            let note = try XCTUnwrap(map("Notification",
                #"{"notification_type":"\#(type)","message":"Claude needs your permission to use Bash"}"#), type)
            XCTAssertEqual(note, HookNotification(kind: .needsInput, titleSuffix: "needs you",
                                                  body: "Claude needs your permission to use Bash"), type)
        }
    }

    func testOtherNotificationTypesAreIgnored() {
        XCTAssertNil(map("Notification", #"{"notification_type":"auth_success","message":"ok"}"#))
        XCTAssertNil(map("Notification", #"{"message":"no type"}"#))
    }

    /// AskUserQuestion's own permission prompt would double the question's notification.
    func testAskUserQuestionPermissionPromptIsNotRepeated() {
        XCTAssertNil(map("Notification",
            #"{"notification_type":"permission_prompt","message":"Claude needs your permission to use AskUserQuestion"}"#))
    }

    func testMissingMessageGetsAFallbackBody() throws {
        let note = try XCTUnwrap(map("Notification", #"{"notification_type":"idle_prompt"}"#))
        XCTAssertFalse(note.body.isEmpty)
    }

    // MARK: - dispatcher + notify tool

    private func tmp() -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("notif-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private final class Sink: @unchecked Sendable { var notes: [(HookNotification, String)] = [] }

    private func dispatch(_ event: String, _ json: String, base: URL, sink: Sink, token: String? = "tok") async -> String? {
        await HookDispatcher.handle(cliType: "claude", event: event, payload: Data(json.utf8),
                                    base: base, token: token, notifier: { sink.notes.append(($0, $1)) })
    }

    private let ask = #"{"session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?"}]}}"#

    func testTerminalModeAskNotifiesAndStillAllows() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        ChatLedger.setMode(.terminal, base: base, session: "s1")
        let sink = Sink()
        let out = await dispatch("PreToolUse", ask, base: base, sink: sink)
        XCTAssertNil(out, "the hook must not alter claude's behavior")
        XCTAssertEqual(sink.notes.map(\.0.body), ["Ship it?"])
        XCTAssertEqual(sink.notes.map(\.1), ["tok"])
    }

    func testChatModeStillDeniesWithoutNotifying() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        ChatLedger.setMode(.chat, base: base, session: "s1")
        let sink = Sink()
        let out = await dispatch("PreToolUse", ask, base: base, sink: sink)
        XCTAssertEqual(out, ChatHookHandler.denyJSON)
        XCTAssertTrue(sink.notes.isEmpty)
    }

    func testNotificationHookNotifiesAndKeepsTheLedger() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let sink = Sink()
        let out = await dispatch("Notification",
            #"{"session_id":"s1","notification_type":"permission_prompt","message":"Allow Bash?"}"#,
            base: base, sink: sink)
        XCTAssertNil(out)
        XCTAssertEqual(sink.notes.map(\.0.kind), [.needsInput])
    }

    func testNoTokenNoNotification() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let sink = Sink()
        _ = await dispatch("PreToolUse", ask, base: base, sink: sink, token: nil)
        XCTAssertTrue(sink.notes.isEmpty)
    }

    func testEnvelopeCarriesKindSuffixBodyAndToken() throws {
        let note = HookNotification(kind: .question, titleSuffix: "is asking", body: "Ship it?")
        let env = try XCTUnwrap(JSONSerialization.jsonObject(
            with: HookNotifier.envelope(note, token: "tok")) as? [String: Any])
        XCTAssertEqual(env["token"] as? String, "tok")
        let params = (env["request"] as? [String: Any])?["params"] as? [String: Any]
        XCTAssertEqual(params?["name"] as? String, "notify")
        let args = params?["arguments"] as? [String: String]
        XCTAssertEqual(args, ["kind": "question", "title_suffix": "is asking", "body": "Ship it?"])
    }

    func testHookNotifierToleratesAMissingSocket() {
        HookNotifier.send(Data("{}".utf8), to: "/tmp/admiral-no-such-\(UUID().uuidString).sock")
    }
}

@MainActor
final class NotifyToolTests: XCTestCase {
    private func make() -> (MCPServer, BridgeCore, [(UUID, NotificationKind, String, String)].Box) {
        let host = FakeTerminalHost()
        let manager = SessionManager(host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                                     executablePath: "/bin/echo")
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"), handle: FakeTerminalHost.Handle(pid: 1))
        let bridge = BridgeCore(manager: manager)
        let box = [(UUID, NotificationKind, String, String)].Box()
        bridge.postNotification = { box.items.append(($0, $1, $2, $3)) }
        return (MCPServer(bridge: bridge), bridge, box)
    }

    private func call(_ server: MCPServer, token: String, _ args: [String: Any]) throws -> (text: String, isError: Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": "notify", "arguments": args]]
        let data = server.handle(requestData: try JSONSerialization.data(withJSONObject: req), sessionToken: token)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testToolPostsForTheCallersTabWithItsCallsignAsTitle() throws {
        let (server, _, box) = make()
        let r = try call(server, token: "A", ["body": "build done"])
        XCTAssertFalse(r.isError)
        XCTAssertEqual(box.items.count, 1)
        XCTAssertEqual(box.items[0].1, .agent)
        XCTAssertEqual(box.items[0].2, "@alice")
        XCTAssertEqual(box.items[0].3, "build done")
    }

    func testTitleIsHonoredAndHookSuffixWins() throws {
        let (server, _, box) = make()
        _ = try call(server, token: "A", ["body": "x", "title": "Deploy"])
        _ = try call(server, token: "A", ["body": "q?", "kind": "question", "title_suffix": "is asking"])
        XCTAssertEqual(box.items.map(\.2), ["Deploy", "@alice is asking"])
        XCTAssertEqual(box.items.map(\.1), [.agent, .question])
    }

    func testEmptyBodyAndUnknownSessionFail() throws {
        let (server, _, box) = make()
        XCTAssertTrue(try call(server, token: "A", ["body": "  "]).isError)
        XCTAssertTrue(try call(server, token: "nope", ["body": "x"]).isError)
        XCTAssertTrue(box.items.isEmpty)
    }
}

private extension Array {
    /// A reference box so a `@Sendable`-free closure can collect posts.
    final class Box { var items: [Element] = [] }
}
