import XCTest
@testable import AdmiralCore

final class TurnCaptureTests: XCTestCase {

    // Compact fixture builders for Claude Code transcript jsonl lines.
    private func userLine(_ text: String) -> String {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private func toolResultLine() -> String {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content":
            [["type": "tool_result", "tool_use_id": "tu_1", "content": "ok"]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private func assistantLine(texts: [String], thinking: String? = nil,
                               usage: (Int, Int)? = nil) -> String {
        var blocks: [[String: Any]] = []
        if let thinking { blocks.append(["type": "thinking", "thinking": thinking]) }
        blocks.append(contentsOf: texts.map { ["type": "text", "text": $0] })
        blocks.append(["type": "tool_use", "id": "tu_1", "name": "Bash", "input": ["command": "ls"]])
        var message: [String: Any] = ["role": "assistant", "model": "claude-opus-4-8", "content": blocks]
        if let usage { message["usage"] = ["input_tokens": usage.0, "output_tokens": usage.1] }
        let obj: [String: Any] = ["type": "assistant", "message": message]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private func data(_ lines: [String], trailingNewline: Bool = true) -> Data {
        Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8)
    }

    // MARK: userTexts

    func testUserTextsExtractsOrderedTrimmedTexts() {
        let d = data([userLine("  first  "), assistantLine(texts: ["reply"]), toolResultLine(), userLine("second")])
        XCTAssertEqual(TurnCapture.userTexts(in: d), ["first", "second"])
    }

    // MARK: unseen (delta)

    func testFreshTranscriptEverythingUnseen() {
        XCTAssertEqual(TurnCapture.unseen(requestTexts: ["a", "b"], transcriptTexts: []), ["a", "b"])
    }

    func testCleanExtensionOnlyLastIsUnseen() {
        XCTAssertEqual(TurnCapture.unseen(requestTexts: ["a", "b", "c"], transcriptTexts: ["a", "b"]), ["c"])
    }

    func testRetryIsIdempotent() {
        XCTAssertEqual(TurnCapture.unseen(requestTexts: ["a", "b"], transcriptTexts: ["a", "b"]), [])
    }

    func testEditedHistoryCountsAsNew() {
        XCTAssertEqual(TurnCapture.unseen(requestTexts: ["a-edited", "b"], transcriptTexts: ["a", "b"]), ["a-edited"])
    }

    func testHandTypedTerminalMessagesAreIgnored() {
        // Messages typed directly in the terminal exist in the transcript but not the request.
        XCTAssertEqual(TurnCapture.unseen(requestTexts: ["a", "b"], transcriptTexts: ["a", "typed by hand", "b"]), [])
    }

    func testJoinedInjectionIsRecognizedOnLaterRequests() {
        // Round 1 injected ["a", "b"] as one joined message: transcript has "a\n\nb".
        // Round 2 request resends a, b (plus new c) — a and b must NOT re-inject.
        XCTAssertEqual(
            TurnCapture.unseen(requestTexts: ["a", "b", "c"], transcriptTexts: ["a\n\nb"]),
            ["c"]
        )
    }

    // MARK: capture

    func testCaptureConcatenatesAssistantTextAfterOffset() {
        let before = data([userLine("q1"), assistantLine(texts: ["old reply"])])
        let after = data([assistantLine(texts: ["part 1", "part 2"], thinking: "hmm", usage: (10, 5)),
                          assistantLine(texts: ["part 3"], usage: (11, 9))])
        var full = before; full.append(after)
        let cap = TurnCapture.capture(full, fromOffset: before.count)
        // text blocks joined by blank lines; thinking and tool_use ignored
        XCTAssertEqual(cap.text, "part 1\n\npart 2\n\npart 3")
        // usage from the LAST assistant line
        XCTAssertEqual(cap.usage, AnthropicUsage(inputTokens: 11, outputTokens: 9))
        XCTAssertEqual(cap.newOffset, full.count)
    }

    func testCaptureIgnoresIncompleteTrailingLine() {
        let before = data([userLine("q")])
        let complete = data([assistantLine(texts: ["done"], usage: (1, 2))])
        var full = before; full.append(complete)
        full.append(Data("{\"type\":\"assistant\",\"message\":{\"role\":\"assi".utf8)) // mid-write, no \n
        let cap = TurnCapture.capture(full, fromOffset: before.count)
        XCTAssertEqual(cap.text, "done")
        // newOffset stops at the end of the last COMPLETE line
        XCTAssertEqual(cap.newOffset, before.count + complete.count)
        // the incomplete tail is picked up once completed
        XCTAssertEqual(TurnCapture.capture(full, fromOffset: cap.newOffset).text, "")
    }

    func testCaptureEmptyWhenNothingAppended() {
        let d = data([userLine("q"), assistantLine(texts: ["r"])])
        let cap = TurnCapture.capture(d, fromOffset: d.count)
        XCTAssertEqual(cap.text, "")
        XCTAssertNil(cap.usage)
        XCTAssertEqual(cap.newOffset, d.count)
    }
}
