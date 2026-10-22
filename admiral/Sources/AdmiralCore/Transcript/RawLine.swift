import Foundation

/// The subset of a transcript JSONL line we decode. Everything else is ignored.
struct RawLine: Decodable {
    let type: String?
    /// The line's own id, written by claude. What turn ids are built from, so the same line
    /// parses to the same id every time (the SSE feed de-dups and resumes on them).
    let uuid: String?
    let timestamp: String?
    let message: RawMessage?
    // Title line variants (camelCase keys in the JSON).
    let aiTitle: String?
    let customTitle: String?
    let agentName: String?
}

struct RawMessage: Decodable {
    let role: String?
    let model: String?
    let content: JSONValue?
    let usage: RawUsage?
}

/// Token usage on an assistant transcript line (snake_case keys in the JSON).
struct RawUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
