import Foundation

/// The Stop-hook JSON that keeps the turn alive and tells claude to deliver its
/// structured output. Hand-built with a fixed key order (like `DecisionRenderer`) so
/// tests can assert the exact wire bytes — this JSON IS the mechanism; a wrong key
/// silently stops enforcement.
public enum StopInstruction {
    /// The schema as wire text. Shared with the validation-failure reply so a retrying model
    /// reads the same bytes it was armed with, rather than working from memory of a Stop
    /// block that may be far back in its context.
    public static func schemaText(_ schema: JSONValue) -> String {
        let encoder = JSONEncoder()
        // Sorted, so the same schema is the same bytes every time: this string is asserted in
        // tests and is read twice by the model (once when armed, once on a retry), and Swift
        // dictionary order is otherwise unspecified.
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(schema))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func blockJSON(schema: JSONValue, type: ArmType) -> String {
        let schemaText = schemaText(schema)
        let reason = "structured output required: call the set_structured_output tool "
            + "(admiral bridge MCP) exactly once with `type` set to \"\(type.rawValue)\" and "
            + "`output` set to a JSON string matching this schema, then end your turn: "
            + schemaText
        return "{\"decision\":\"block\",\"reason\":\(JSONText.escaped(reason))}"
    }

}
