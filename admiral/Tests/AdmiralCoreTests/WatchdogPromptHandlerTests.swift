import XCTest
@testable import AdmiralCore

final class WatchdogPromptHandlerTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-prompt-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func payload(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    private func lines(token: String) -> [PromptEvent] {
        guard let data = try? Data(contentsOf: AdmiralPaths.promptsLog(base: base, token: token)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(PromptEvent.self, from: Data($0.utf8))
        }
    }

    func testAppendsPromptLine() {
        WatchdogPromptHandler.handle(
            payload: payload(["hook_event_name": "UserPromptSubmit",
                              "prompt": "execute and /drive-ticket to PROD"]),
            base: base, token: "tok1", now: { "T1" })
        XCTAssertEqual(lines(token: "tok1"),
                       [PromptEvent(ts: "T1", prompt: "execute and /drive-ticket to PROD")])
    }

    func testIgnoresEmptyPromptAndWrongEvent() {
        WatchdogPromptHandler.handle(
            payload: payload(["hook_event_name": "UserPromptSubmit", "prompt": ""]),
            base: base, token: "tok1", now: { "T1" })
        WatchdogPromptHandler.handle(
            payload: payload(["hook_event_name": "Stop", "prompt": "hi"]),
            base: base, token: "tok1", now: { "T1" })
        XCTAssertEqual(lines(token: "tok1"), [])
    }

    func testTruncatesLongPrompt() {
        let long = String(repeating: "x", count: WatchdogPromptHandler.maxPromptLength + 100)
        WatchdogPromptHandler.handle(
            payload: payload(["hook_event_name": "UserPromptSubmit", "prompt": long]),
            base: base, token: "tok1", now: { "T1" })
        XCTAssertEqual(lines(token: "tok1").first?.prompt.count,
                       WatchdogPromptHandler.maxPromptLength)
    }

    func testDispatcherCapturesPromptOnUserPromptSubmit() async {
        let raw = payload(["hook_event_name": "UserPromptSubmit", "session_id": "s",
                           "cwd": "/tmp", "prompt": "go /drive-ticket to PROD"])
        _ = await HookDispatcher.handle(cliType: "claude", event: "UserPromptSubmit",
                                        payload: raw, base: base, token: "tok2")
        XCTAssertEqual(lines(token: "tok2").map(\.prompt), ["go /drive-ticket to PROD"])
    }
}
