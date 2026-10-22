import Foundation

/// Token usage in Anthropic wire form (`input_tokens` / `output_tokens`).
public struct AnthropicUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
    var jsonObject: [String: Any] { ["input_tokens": inputTokens, "output_tokens": outputTokens] }
}

/// The subset of an Anthropic Messages API request Admiral understands.
/// `content` decodes both the plain-string and content-block-array forms.
public struct AnthropicMessagesRequest {
    public let model: String
    public let stream: Bool
    /// Text of every `role: "user"` message, in order — string content as-is,
    /// block arrays as their text blocks joined by a blank line — trimmed.
    /// Non-text blocks (images, tool_result) contribute nothing.
    public let userTexts: [String]
    /// Parsed structured-output request, from `output_format` (json_schema) or a forced
    /// single-tool `tool_choice`. nil = a plain text turn (including `tools` without a
    /// forced choice, which stays ignored).
    public let structuredOutput: StructuredOutputSpec?
    /// Non-nil when the structured-output fields are contradictory; the endpoint 400s
    /// with this message instead of guessing.
    public let structuredOutputError: String?

    public static func decode(_ body: Data) -> AnthropicMessagesRequest? {
        struct Raw: Decodable {
            struct Msg: Decodable { let role: String?; let content: JSONValue? }
            let model: String?
            let stream: Bool?
            let messages: [Msg]?
            let output_format: JSONValue?
            let tools: JSONValue?
            let tool_choice: JSONValue?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: body),
              let model = raw.model, !model.isEmpty else { return nil }
        let userTexts = (raw.messages ?? [])
            .filter { $0.role == "user" }
            .compactMap { msg -> String? in
                let text = (msg.content?.blocks ?? [])
                    .filter { $0["type"]?.stringValue == "text" }
                    .compactMap { $0["text"]?.stringValue }
                    .joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        let (spec, specError) = structuredOutputSpec(
            outputFormat: raw.output_format, tools: raw.tools, toolChoice: raw.tool_choice)
        return AnthropicMessagesRequest(model: model, stream: raw.stream ?? false,
                                        userTexts: userTexts,
                                        structuredOutput: spec, structuredOutputError: specError)
    }

    /// Both wire forms reduce to one spec: a schema plus where the result goes.
    static func structuredOutputSpec(
        outputFormat: JSONValue?, tools: JSONValue?, toolChoice: JSONValue?
    ) -> (StructuredOutputSpec?, String?) {
        let formatSchema: JSONValue? = outputFormat?["type"]?.stringValue == "json_schema"
            ? outputFormat?["schema"] : nil
        let forcedName: String? = toolChoice?["type"]?.stringValue == "tool"
            ? toolChoice?["name"]?.stringValue : nil
        if formatSchema != nil, forcedName != nil {
            return (nil, "output_format and a forced tool_choice cannot be combined")
        }
        if let schema = formatSchema {
            return (StructuredOutputSpec(schema: schema, delivery: .jsonText), nil)
        }
        if let name = forcedName {
            guard let toolSchema = (tools?.arrayValue ?? [])
                .first(where: { $0["name"]?.stringValue == name })?["input_schema"] else {
                return (nil, "tool_choice names '\(name)' but no such tool with an input_schema is in tools")
            }
            return (StructuredOutputSpec(schema: toolSchema, delivery: .toolUse, toolName: name), nil)
        }
        return (nil, nil)
    }
}

/// Builders for the exact bytes of Anthropic responses and SSE event payloads.
/// Built with JSONSerialization (not Encodable) because `stop_sequence` must be
/// present-and-null, which Encodable omits by default.
public enum AnthropicWire {
    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    public static func message(id: String, model: String, text: String, usage: AnthropicUsage) -> Data {
        encode([
            "id": id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "stop_sequence": NSNull(),
            "usage": usage.jsonObject,
        ])
    }

    public static func error(type: String, message: String) -> Data {
        encode(["type": "error", "error": ["type": type, "message": message]])
    }

    /// Compact JSON text of a JSONValue (the structured result as a string).
    public static func jsonText(_ value: JSONValue) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// JSONValue → Foundation objects, for composing into JSONSerialization payloads.
    static func foundationObject(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(n): return n
        case let .string(s): return s
        case let .array(a): return a.map(foundationObject)
        case let .object(o): return o.mapValues(foundationObject)
        }
    }

    /// The non-streaming response for a fulfilled structured-output request:
    /// `output_format` → the JSON as the text block; a forced tool → a tool_use block
    /// with `stop_reason: "tool_use"`, exactly as a real forced tool call returns.
    public static func structuredMessage(
        id: String, model: String, spec: StructuredOutputSpec,
        result: JSONValue, usage: AnthropicUsage
    ) -> Data {
        let content: [[String: Any]]
        let stopReason: String
        switch spec.delivery {
        case .jsonText:
            content = [["type": "text", "text": jsonText(result)]]
            stopReason = "end_turn"
        case .toolUse:
            content = [[
                "type": "tool_use",
                "id": "toolu_" + String(id.dropFirst(4)),   // msg_<hex> → toolu_<hex>
                "name": spec.toolName ?? "structured_output",
                "input": foundationObject(result),
            ]]
            stopReason = "tool_use"
        }
        return encode([
            "id": id, "type": "message", "role": "assistant", "model": model,
            "content": content, "stop_reason": stopReason, "stop_sequence": NSNull(),
            "usage": usage.jsonObject,
        ])
    }

    public static func contentBlockStartToolUse(id: String, name: String) -> Data {
        encode(["type": "content_block_start", "index": 0,
                "content_block": ["type": "tool_use", "id": id, "name": name,
                                  "input": [String: Any]()]])
    }

    public static func inputJSONDelta(partial: String) -> Data {
        encode(["type": "content_block_delta", "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": partial]])
    }

    // MARK: SSE event payloads (the `data:` JSON of each frame)

    public static func messageStart(id: String, model: String) -> Data {
        encode(["type": "message_start", "message": [
            "id": id, "type": "message", "role": "assistant", "model": model,
            "content": [Any](), "stop_reason": NSNull(), "stop_sequence": NSNull(),
            "usage": ["input_tokens": 0, "output_tokens": 0],
        ]])
    }

    public static func contentBlockStart() -> Data {
        encode(["type": "content_block_start", "index": 0,
                "content_block": ["type": "text", "text": ""]])
    }

    public static func contentBlockDelta(text: String) -> Data {
        encode(["type": "content_block_delta", "index": 0,
                "delta": ["type": "text_delta", "text": text]])
    }

    public static func contentBlockStop() -> Data {
        encode(["type": "content_block_stop", "index": 0])
    }

    public static func messageDelta(usage: AnthropicUsage, stopReason: String = "end_turn") -> Data {
        encode(["type": "message_delta",
                "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
                "usage": ["output_tokens": usage.outputTokens]])
    }

    public static func messageStop() -> Data { encode(["type": "message_stop"]) }
    public static func ping() -> Data { encode(["type": "ping"]) }
}
