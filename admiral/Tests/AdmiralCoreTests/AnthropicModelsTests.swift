// admiral/Tests/AdmiralCoreTests/AnthropicModelsTests.swift
import XCTest
@testable import AdmiralCore

final class AnthropicModelsTests: XCTestCase {

    // MARK: request decoding

    func testDecodesStringContent() throws {
        let body = Data("""
        {"model":"Nasty Bug","max_tokens":1024,"messages":[
          {"role":"user","content":"hello"},
          {"role":"assistant","content":"hi"},
          {"role":"user","content":"  status?  "}
        ]}
        """.utf8)
        let req = try XCTUnwrap(AnthropicMessagesRequest.decode(body))
        XCTAssertEqual(req.model, "Nasty Bug")
        XCTAssertFalse(req.stream)
        // userTexts: user-role messages only, text extracted, trimmed
        XCTAssertEqual(req.userTexts, ["hello", "status?"])
    }

    func testDecodesBlockArrayContentAndStreamFlag() throws {
        let body = Data("""
        {"model":"tab","stream":true,"messages":[
          {"role":"user","content":[
            {"type":"text","text":"part one"},
            {"type":"image","source":{"type":"base64","media_type":"image/png","data":"xx"}},
            {"type":"text","text":"part two"}
          ]}
        ]}
        """.utf8)
        let req = try XCTUnwrap(AnthropicMessagesRequest.decode(body))
        XCTAssertTrue(req.stream)
        // text blocks joined with a blank line; non-text blocks ignored
        XCTAssertEqual(req.userTexts, ["part one\n\npart two"])
    }

    func testMalformedBodyDecodesToNil() {
        XCTAssertNil(AnthropicMessagesRequest.decode(Data("not json".utf8)))
        XCTAssertNil(AnthropicMessagesRequest.decode(Data("{\"messages\":[]}".utf8))) // no model
    }

    // MARK: response encoding

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMessageResponseShape() throws {
        let data = AnthropicWire.message(
            id: "msg_abc", model: "Nasty Bug", text: "all done",
            usage: AnthropicUsage(inputTokens: 12, outputTokens: 34)
        )
        let obj = try json(data)
        XCTAssertEqual(obj["id"] as? String, "msg_abc")
        XCTAssertEqual(obj["type"] as? String, "message")
        XCTAssertEqual(obj["role"] as? String, "assistant")
        XCTAssertEqual(obj["model"] as? String, "Nasty Bug")
        XCTAssertEqual(obj["stop_reason"] as? String, "end_turn")
        // stop_sequence must be PRESENT and null — strict SDK models require the key
        XCTAssertTrue(obj.keys.contains("stop_sequence"))
        XCTAssertTrue(obj["stop_sequence"] is NSNull)
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "all done")
        let usage = try XCTUnwrap(obj["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 12)
        XCTAssertEqual(usage["output_tokens"] as? Int, 34)
    }

    func testErrorEnvelope() throws {
        let obj = try json(AnthropicWire.error(type: "not_found_error", message: "no tab"))
        XCTAssertEqual(obj["type"] as? String, "error")
        let err = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(err["type"] as? String, "not_found_error")
        XCTAssertEqual(err["message"] as? String, "no tab")
    }

    // MARK: SSE payloads

    func testStreamingEventPayloads() throws {
        let start = try json(AnthropicWire.messageStart(id: "msg_1", model: "tab"))
        XCTAssertEqual(start["type"] as? String, "message_start")
        let msg = try XCTUnwrap(start["message"] as? [String: Any])
        XCTAssertEqual(msg["id"] as? String, "msg_1")
        XCTAssertEqual((msg["content"] as? [Any])?.count, 0)
        XCTAssertNil(msg["stop_reason"] as? String) // null at start

        let bStart = try json(AnthropicWire.contentBlockStart())
        XCTAssertEqual(bStart["type"] as? String, "content_block_start")
        XCTAssertEqual(bStart["index"] as? Int, 0)
        XCTAssertEqual((bStart["content_block"] as? [String: Any])?["type"] as? String, "text")

        let delta = try json(AnthropicWire.contentBlockDelta(text: "chunk"))
        XCTAssertEqual(delta["type"] as? String, "content_block_delta")
        XCTAssertEqual(delta["index"] as? Int, 0)
        let d = try XCTUnwrap(delta["delta"] as? [String: Any])
        XCTAssertEqual(d["type"] as? String, "text_delta")
        XCTAssertEqual(d["text"] as? String, "chunk")

        let bStop = try json(AnthropicWire.contentBlockStop())
        XCTAssertEqual(bStop["type"] as? String, "content_block_stop")

        let mDelta = try json(AnthropicWire.messageDelta(usage: AnthropicUsage(inputTokens: 0, outputTokens: 7)))
        XCTAssertEqual(mDelta["type"] as? String, "message_delta")
        XCTAssertEqual((mDelta["delta"] as? [String: Any])?["stop_reason"] as? String, "end_turn")
        XCTAssertEqual((mDelta["usage"] as? [String: Any])?["output_tokens"] as? Int, 7)

        XCTAssertEqual(try json(AnthropicWire.messageStop())["type"] as? String, "message_stop")
        XCTAssertEqual(try json(AnthropicWire.ping())["type"] as? String, "ping")
    }
}
