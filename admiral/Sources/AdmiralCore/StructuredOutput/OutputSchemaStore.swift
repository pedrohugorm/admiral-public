import Foundation

/// A tab's own output schema: what every turn in it must deliver through
/// `set_structured_output(type: "output")`. Two processes use it: the app sets and clears it,
/// and the hook helper re-arms the `output` slot from it on every prompt.
public enum OutputSchemaStore {
    public static func schema(base: URL, session: String) -> JSONValue? {
        let url = AdmiralPaths.outputSchemaFile(base: base, session: session)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Store `schema` (nil clears). Refuses a schema that is not strict, with the reasons;
    /// a nil return means it was stored.
    @discardableResult
    public static func set(_ schema: JSONValue?, base: URL, session: String) -> [String]? {
        let url = AdmiralPaths.outputSchemaFile(base: base, session: session)
        guard let schema else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let problems = StrictSchema.violations(schema)
        guard problems.isEmpty else { return problems }
        guard let data = try? JSONEncoder().encode(schema),
              (try? data.write(to: url, options: .atomic)) != nil else {
            return ["could not write the schema file"]
        }
        return nil
    }

    /// The `UserPromptSubmit` side: a new prompt owes a new answer. Re-arms the `output` slot
    /// with the stored schema, a fresh budget, and the next round number; no schema, no-op.
    public static func rearm(base: URL, token: String, session: String) {
        guard let schema = schema(base: base, session: session) else { return }
        let previous = StructuredOutputStore.read(base: base, token: token, type: .output)
        StructuredOutputStore.write(
            StructuredOutputState(schema: schema, delivery: .jsonText,
                                  round: (previous?.round ?? 0) + 1),
            base: base, token: token, type: .output)
    }
}

/// "Strict" JSON Schema, checked when a tab's output schema is set rather than discovered
/// later: the same contract OpenAI-style strict mode holds, narrowed to what
/// `JSONSchemaValidator` enforces — so nothing in an accepted schema is silently ignored.
public enum StrictSchema {
    static let allowedKeywords: Set<String> = [
        "type", "properties", "required", "items", "enum", "const",
        "additionalProperties", "description", "title",
    ]
    static let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]

    /// Every reason `schema` is not strict, by JSON path; empty = strict.
    public static func violations(_ schema: JSONValue) -> [String] {
        guard case .object = schema, schema["type"]?.stringValue == "object" else {
            return ["$: the root must be an object schema (\"type\": \"object\")"]
        }
        return check(schema, at: "$")
    }

    private static func check(_ node: JSONValue, at path: String) -> [String] {
        guard case let .object(fields) = node else { return ["\(path): must be a schema object"] }
        var problems: [String] = []
        for key in fields.keys.sorted() where !allowedKeywords.contains(key) {
            problems.append("\(path): keyword \"\(key)\" is not supported in a strict schema")
        }
        guard let type = node["type"]?.stringValue, types.contains(type) else {
            return problems + ["\(path): needs a single \"type\" (one of \(types.sorted().joined(separator: ", ")))"]
        }
        problems += valueProblems(node, type: type, at: path)
        switch type {
        case "object":
            guard case let .object(props)? = node["properties"] else {
                return problems + ["\(path): an object needs \"properties\""]
            }
            if node["additionalProperties"]?.boolValue != false {
                problems.append("\(path): an object needs \"additionalProperties\": false")
            }
            // Read through `compactMap` below, a non-list or a non-name would just vanish.
            if let raw = node["required"], raw.arrayValue?.allSatisfy({ $0.stringValue != nil }) != true {
                problems.append("\(path): \"required\" must be an array of property names")
            }
            let required = Set(node["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            for name in props.keys.sorted() where !required.contains(name) {
                problems.append("\(path).\(name): every property must be listed in \"required\"")
            }
            // With additionalProperties false, a required name with no property can never be met.
            for name in required.sorted() where props[name] == nil {
                problems.append("\(path).\(name): listed in \"required\" but not in \"properties\"")
            }
            for (name, sub) in props.sorted(by: { $0.key < $1.key }) {
                problems += check(sub, at: "\(path).\(name)")
            }
        case "array":
            guard let items = node["items"] else { return problems + ["\(path): an array needs \"items\""] }
            problems += check(items, at: "\(path)[]")
        default:
            break
        }
        return problems
    }

    /// `enum` and `const` are compared literally by the validator: an `enum` that is not a
    /// non-empty array would be skipped (or met by nothing), and a value of another type than
    /// the node's can never be the answer.
    private static func valueProblems(_ node: JSONValue, type: String, at path: String) -> [String] {
        var problems: [String] = []
        if let raw = node["enum"] {
            if let values = raw.arrayValue, !values.isEmpty {
                for value in values where !JSONSchemaValidator.matches(value, type: type) {
                    problems.append("\(path): enum value \(JSONSchemaValidator.literal(value)) does not match \"type\": \"\(type)\"")
                }
            } else {
                problems.append("\(path): \"enum\" must be a non-empty array of values")
            }
        }
        if let value = node["const"], !JSONSchemaValidator.matches(value, type: type) {
            problems.append("\(path): const \(JSONSchemaValidator.literal(value)) does not match \"type\": \"\(type)\"")
        }
        return problems
    }
}
