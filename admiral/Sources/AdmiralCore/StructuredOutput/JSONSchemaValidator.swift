import Foundation

/// Minimal JSON Schema validation over `JSONValue` — the subset the structured-output
/// loop needs: `type`, `properties`, `required`, `items`, `enum`, `const`,
/// `additionalProperties` (boolean form), and nesting. Unsupported keywords are
/// ignored (permissive), per the spec. No external dependencies (AdmiralCore invariant).
public enum JSONSchemaValidator {
    /// Human-readable violations (`$.foo[2].bar: expected integer`); empty = valid.
    public static func validate(_ value: JSONValue, against schema: JSONValue,
                                at path: String = "$") -> [String] {
        guard case .object = schema else { return [] }  // non-object schema: permissive
        var violations: [String] = []

        if let type = schema["type"]?.stringValue, !matches(value, type: type) {
            // Wrong type: deeper checks would only cascade noise.
            return ["\(path): expected \(type)"]
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            // Name them. "not one of the allowed enum values" is the one violation a model
            // cannot act on — it burns a retry guessing, and there are only three.
            violations.append("\(path): \(literal(value)) is not one of: "
                + allowed.map(literal).joined(separator: ", "))
        }
        if let const = schema["const"], value != const {
            violations.append("\(path): must equal the const value")
        }
        if case let .object(fields) = value {
            if let required = schema["required"]?.arrayValue {
                for name in required.compactMap(\.stringValue).sorted() where fields[name] == nil {
                    violations.append("\(path).\(name): required property missing")
                }
            }
            let propSchemas: [String: JSONValue] = {
                if case let .object(p)? = schema["properties"] { return p }
                return [:]
            }()
            for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                if let sub = propSchemas[name] {
                    violations += validate(field, against: sub, at: "\(path).\(name)")
                } else if schema["additionalProperties"]?.boolValue == false {
                    violations.append("\(path).\(name): additional property not allowed")
                }
            }
        }
        if case let .array(elements) = value, let itemSchema = schema["items"] {
            for (i, element) in elements.enumerated() {
                violations += validate(element, against: itemSchema, at: "\(path)[\(i)]")
            }
        }
        return violations
    }

    /// A value as it would appear in the schema, so the model can copy it back verbatim.
    static func literal(_ value: JSONValue) -> String {
        switch value {
        case let .string(s): return JSONText.escaped(s)
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        case let .number(n):
            return n.isFinite && n.rounded() == n ? String(Int(n)) : String(n)
        case .array, .object:
            return (try? JSONEncoder().encode(value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        }
    }

    /// The one place a value is held to a `type` — `StrictSchema` asks it too, so a schema it
    /// accepts can't name an `enum` or `const` this would reject.
    static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string),
             ("boolean", .bool), ("null", .null), ("number", .number):
            return true
        case let ("integer", .number(n)):
            return n.isFinite && n.rounded() == n
        default:
            return false
        }
    }
}
