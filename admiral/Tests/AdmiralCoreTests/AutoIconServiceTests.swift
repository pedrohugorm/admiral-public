import XCTest
@testable import AdmiralCore

/// A tab opens with the default icon, and its first prompt picks one. An icon the user set
/// never changes, and only the first prompt picks.
@MainActor
final class AutoIconServiceTests: XCTestCase {
    private var base: URL!
    private var manager: SessionManager!
    private let symbols = ["sparkles", "hammer", "cube", "server.rack"]

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("auto-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        manager = SessionManager(host: FakeTerminalHost(), claudeHome: base.appendingPathComponent("claude"),
                                 executablePath: "/bin/echo", supportDir: base)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    /// A tab whose transcript already holds `earlier` prompts, with the icon as given.
    private func tab(earlier: Int = 0, color: String? = nil, symbol: String? = nil) -> AgentSession {
        let transcript = base.appendingPathComponent("\(UUID().uuidString).jsonl")
        let rows = (0..<earlier).map {
            #"{"type":"user","timestamp":"2026-09-30T10:00:0\#($0)Z","message":{"role":"user","content":"prompt \#($0)"}}"#
        }
        try? rows.map { $0 + "\n" }.joined().write(to: transcript, atomically: true, encoding: .utf8)
        let session = AgentSession(callsign: "tab", cwd: "/w", claudeSessionID: UUID().uuidString,
                                   transcriptPath: transcript.path, avatarColorHex: color, avatarSymbol: symbol)
        manager.register(session, handle: FakeTerminalHost.Handle(pid: 1))
        return session
    }

    /// What the prompt hook records when a prompt is submitted.
    private func submit(_ prompt: String, to session: AgentSession) {
        let data = try! JSONEncoder().encode(PromptEvent(ts: "2026-09-30T10:01:00Z", prompt: prompt))
        AtomicAppend.line(data, to: AdmiralPaths.promptsLog(base: base, token: session.token))
    }

    private func icon(of session: AgentSession) -> String? {
        manager.sessions.first { $0.id == session.id }?.avatarSymbol
    }

    private func service(_ picker: FakeIconPicker) -> AutoIconService {
        AutoIconService(manager: manager, picker: picker, symbols: symbols)
    }

    private func settle(_ service: AutoIconService) async {
        for task in service.picks.values { await task.value }
    }

    func testTheFirstPromptPicksTheIcon() async {
        let picker = FakeIconPicker(answer: "hammer")
        let auto = service(picker), tab = tab()
        submit("Fix the flaky login test", to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertEqual(icon(of: tab), "hammer")
        XCTAssertEqual(picker.prompts, ["Fix the flaky login test"])
    }

    /// Claude writes the prompt to the transcript before the hook runs, so the first prompt is
    /// usually already there when the tick reads it.
    func testTheFirstPromptAlreadyInTheTranscriptStillPicks() async {
        let picker = FakeIconPicker(answer: "cube")
        let auto = service(picker), tab = tab(earlier: 1)
        submit("prompt 0", to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertEqual(icon(of: tab), "cube")
    }

    func testCreatingATabPicksNothing() async {
        let picker = FakeIconPicker(answer: "hammer")
        let auto = service(picker), tab = tab()
        auto.tick()
        await settle(auto)
        XCTAssertNil(icon(of: tab))
        XCTAssertEqual(picker.prompts, [])
    }

    func testALaterPromptNeverPicks() async {
        let picker = FakeIconPicker(answer: nil)
        let auto = service(picker), tab = tab()
        submit("first", to: tab)
        auto.tick()
        await settle(auto)
        submit("second", to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertEqual(picker.prompts, ["first"])
        XCTAssertNil(icon(of: tab))
    }

    /// A tab restored after a relaunch starts a fresh prompt log, so its next prompt looks like
    /// a first one there. Its transcript says otherwise.
    func testARestoredTabWithAHistoryNeverPicks() async {
        let picker = FakeIconPicker(answer: "hammer")
        let auto = service(picker), tab = tab(earlier: 2)
        submit("carry on", to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertEqual(picker.prompts, [])
        XCTAssertNil(icon(of: tab))
    }

    func testAnIconTheUserSetIsNeverReplaced() async {
        let picker = FakeIconPicker(answer: "hammer")
        let auto = service(picker)
        let picked = tab(symbol: "cube"), tinted = tab(color: "#E8912D")
        submit("Fix the flaky login test", to: picked)
        submit("Fix the flaky login test", to: tinted)
        auto.tick()
        await settle(auto)
        XCTAssertEqual(icon(of: picked), "cube")
        XCTAssertNil(icon(of: tinted))
        XCTAssertEqual(picker.prompts, [])
    }

    func testAnIconSetWhileThePickRunsIsKept() async throws {
        let picker = FakeIconPicker(answer: "hammer", held: true)
        let auto = service(picker), tab = tab()
        submit("Fix the flaky login test", to: tab)
        auto.tick()
        try await picker.waitUntilAsked()
        manager.setAppearance(tab.id, colorHex: "#2F6BFF", symbol: "server.rack")
        picker.release()
        await settle(auto)
        XCTAssertEqual(icon(of: tab), "server.rack")
    }

    /// The model can take a second or more; the tick hands the pick off and returns.
    func testTheTickNeverWaitsForTheModel() async throws {
        let picker = FakeIconPicker(answer: "hammer", held: true)
        let auto = service(picker), tab = tab()
        submit("Fix the flaky login test", to: tab)
        auto.tick()
        try await picker.waitUntilAsked()
        auto.tick()
        XCTAssertNil(icon(of: tab), "the pick is still running")
        picker.release()
        await settle(auto)
        XCTAssertEqual(icon(of: tab), "hammer")
        XCTAssertEqual(picker.prompts.count, 1)
    }

    func testOnlyTheFirst200CharactersReachTheModel() async {
        let picker = FakeIconPicker(answer: "hammer")
        let auto = service(picker), tab = tab()
        let prompt = String(repeating: "a", count: 200) + String(repeating: "b", count: 300)
        submit(prompt, to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertEqual(picker.prompts, [String(repeating: "a", count: 200)])
    }

    func testAPastedPromptReachesTheModelWithoutItsTags() async {
        let picker = FakeIconPicker(answer: "hammer")
        let auto = service(picker), tab = tab()
        submit("  <pasted_content id=\"569c\"> Investigate the failed workflow </pasted_content>", to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertEqual(picker.prompts, ["Investigate the failed workflow"])
    }

    func testNoModelLeavesTheDefaultIcon() async {
        let picker = FakeIconPicker(answer: nil)
        let auto = service(picker), tab = tab()
        submit("Fix the flaky login test", to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertNil(icon(of: tab))
    }

    func testASymbolOutsideTheListIsIgnored() async {
        let picker = FakeIconPicker(answer: "not.a.symbol")
        let auto = service(picker), tab = tab()
        submit("Fix the flaky login test", to: tab)
        auto.tick()
        await settle(auto)
        XCTAssertNil(icon(of: tab))
    }
}

/// Answers with `answer`; when `held`, only once `release()` is called.
final class FakeIconPicker: IconPicker, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var held: Bool
    private var waiting: CheckedContinuation<Void, Never>?
    let answer: String?

    init(answer: String?, held: Bool = false) {
        self.answer = answer
        self.held = held
    }

    var prompts: [String] { lock.withLock { asked } }

    func pickSymbol(for prompt: String, from symbols: [String]) async -> String? {
        lock.withLock { asked.append(prompt) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                guard held else { return true }
                waiting = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return answer
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            held = false
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }

    func waitUntilAsked(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while prompts.isEmpty {
            guard Date() < deadline else {
                throw NSError(domain: "FakeIconPicker", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "the picker was never asked"])
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
