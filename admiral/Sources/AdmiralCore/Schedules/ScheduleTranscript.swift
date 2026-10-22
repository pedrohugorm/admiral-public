import Foundation

/// What a run did, read from its session's transcript: the assistant's text, and the last
/// structured output it delivered on the `output` slot (its `set_structured_output` call).
/// The run index copies neither; this is the one place they are read back.
public enum ScheduleTranscript {
    public struct Result: Equatable, Sendable {
        public let reply: String
        public let output: String?
    }

    public static func result(_ data: Data) -> Result {
        var output: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_use"
                && (block["name"] as? String)?.hasSuffix("set_structured_output") == true {
                let input = block["input"] as? [String: Any] ?? [:]
                guard (input["type"] as? String ?? "output") == "output" else { continue }
                if let text = input["output"] as? String {
                    output = text
                } else if let value = input["output"], JSONSerialization.isValidJSONObject(value),
                          let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                    output = String(decoding: encoded, as: UTF8.self)
                }
            }
        }
        return Result(reply: TurnCapture.capture(data, fromOffset: 0).text, output: output)
    }
}
