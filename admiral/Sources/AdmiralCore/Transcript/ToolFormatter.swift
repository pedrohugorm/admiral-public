import Foundation

/// Humanizes a tool call's input into a one-line parameter summary for the
/// compact tool rows in the Transcript View.
enum ToolFormatter {
    /// Fields, in priority order, that best summarize a call.
    private static let salientKeys = [
        "command", "file_path", "path", "subject", "pattern",
        "query", "url", "description", "prompt",
    ]

    static func params(name: String, input: JSONValue?) -> String {
        guard let input else { return "" }
        for key in salientKeys {
            if let value = input[key]?.stringValue, !value.isEmpty {
                return truncate(value)
            }
        }
        if case let .object(o) = input {
            return o.keys.sorted().prefix(3).joined(separator: ", ")
        }
        return ""
    }

    private static func truncate(_ s: String, _ max: Int = 80) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= max ? oneLine : String(oneLine.prefix(max)) + "…"
    }
}
