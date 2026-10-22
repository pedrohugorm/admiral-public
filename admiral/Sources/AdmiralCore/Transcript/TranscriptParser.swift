import Foundation

/// Parses Claude Code transcript JSONL lines into a `Conversation`. Pure and
/// side-effect-free so it can be unit-tested against golden fixtures; file IO and
/// tailing live in `TranscriptStore`.
public enum TranscriptParser {
    public static func parse(lines: [String]) -> Conversation {
        var turns: [Turn] = []
        var toolIndexByID: [String: Int] = [:]
        var results: [String: (text: String, isError: Bool)] = [:]
        var firstUserText: String?
        var titles = TitleAccumulator()
        let plan = PlanFolder()
        let decoder = JSONDecoder()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let raw = try? decoder.decode(RawLine.self, from: data)
            else { continue }

            titles.ingest(raw)
            switch raw.type {
            case "user":
                handleUser(raw, turns: &turns, results: &results, firstUserText: &firstUserText)
            case "assistant":
                handleAssistant(raw, turns: &turns, toolIndexByID: &toolIndexByID, plan: plan)
            default:
                break
            }
        }

        applyResults(results, to: &turns, toolIndexByID: toolIndexByID)
        plan.applyResults(results)

        return Conversation(title: titles.resolved ?? firstUserText, turns: turns, plan: plan.model())
    }

    /// The plan folded from the WHOLE file.
    ///
    /// `TranscriptStore.loadTail` renders only the tail, which is right for turns and wrong
    /// for the plan: a plan is cumulative, so a task created 700 lines ago is still on the
    /// list, and dropping it turns the panel's "3 / 5" into a lie. Gated by a cheap substring
    /// check first (like `latestTitle`), then run through the SAME line handlers as a full
    /// parse so the two paths cannot disagree about what a task is.
    public static func plan(lines: [String]) -> PlanModel? {
        var turns: [Turn] = []
        var toolIndexByID: [String: Int] = [:]
        var results: [String: (text: String, isError: Bool)] = [:]
        var firstUserText: String?
        let plan = PlanFolder()
        let decoder = JSONDecoder()

        for line in lines where isPlanRelevant(line) {
            guard let data = line.data(using: .utf8),
                  let raw = try? decoder.decode(RawLine.self, from: data) else { continue }
            switch raw.type {
            case "user":
                handleUser(raw, turns: &turns, results: &results, firstUserText: &firstUserText)
            case "assistant":
                handleAssistant(raw, turns: &turns, toolIndexByID: &toolIndexByID, plan: plan)
            default:
                break
            }
        }
        plan.applyResults(results)
        return plan.model()
    }

    /// `Task #` catches the tool_result lines that carry each `TaskCreate`'s real id.
    static func isPlanRelevant(_ line: String) -> Bool {
        line.contains("TaskCreate") || line.contains("TaskUpdate")
            || line.contains("TodoWrite") || line.contains("Task #")
    }

    // MARK: - Line handlers

    private static func handleUser(
        _ raw: RawLine,
        turns: inout [Turn],
        results: inout [String: (text: String, isError: Bool)],
        firstUserText: inout String?
    ) {
        guard let content = raw.message?.content else { return }
        switch content {
        case let .string(text):
            appendUser(text, id: stableID(raw, block: 0, text: text), turns: &turns, firstUserText: &firstUserText)
        case let .array(blocks):
            for (index, block) in blocks.enumerated() {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue {
                        appendUser(text, id: stableID(raw, block: index, text: text),
                                   turns: &turns, firstUserText: &firstUserText)
                    }
                case "tool_result":
                    guard let id = block["tool_use_id"]?.stringValue else { continue }
                    results[id] = (block["content"]?.asText ?? "", block["is_error"]?.boolValue ?? false)
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private static func handleAssistant(
        _ raw: RawLine,
        turns: inout [Turn],
        toolIndexByID: inout [String: Int],
        plan: PlanFolder
    ) {
        guard let content = raw.message?.content else { return }
        let model = raw.message?.model
        for (index, block) in content.blocks.enumerated() {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    turns.append(.assistant(id: stableID(raw, block: index, text: text), markdown: text, model: model))
                }
            case "thinking":
                if let text = block["thinking"]?.stringValue, !text.isEmpty {
                    turns.append(.thinking(id: stableID(raw, block: index, text: text), text: text))
                }
            case "tool_use":
                let id = block["id"]?.stringValue ?? stableID(raw, block: index, text: block["name"]?.stringValue ?? "")
                let name = block["name"]?.stringValue ?? "tool"
                let params = ToolFormatter.params(name: name, input: block["input"])
                turns.append(.tool(id: id, name: name, params: params, result: nil, state: .running))
                toolIndexByID[id] = turns.count - 1
                plan.recordToolUse(id: id, name: name, input: block["input"])
            default:
                break
            }
        }
    }

    private static func appendUser(_ text: String, id: String, turns: inout [Turn], firstUserText: inout String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if firstUserText == nil { firstUserText = trimmed }
        turns.append(.user(id: id, text: text))
    }

    /// A turn's id: the transcript line's own `uuid` plus the block's position in it, so
    /// re-parsing the same file yields the same ids (a random id per parse made the SSE feed
    /// re-send the whole tail every poll). A line without a uuid falls back to a hash of what
    /// it says — still stable across parses.
    static func stableID(_ raw: RawLine, block: Int, text: String) -> String {
        if let uuid = raw.uuid, !uuid.isEmpty { return "\(uuid).\(block)" }
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
        for byte in "\(raw.type ?? "")|\(raw.timestamp ?? "")|\(block)|\(text)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "h" + String(hash, radix: 16) + ".\(block)"
    }

    private static func applyResults(
        _ results: [String: (text: String, isError: Bool)],
        to turns: inout [Turn],
        toolIndexByID: [String: Int]
    ) {
        for (id, index) in toolIndexByID {
            guard let result = results[id],
                  case let .tool(tid, name, params, _, _) = turns[index] else { continue }
            turns[index] = .tool(
                id: tid, name: name, params: params,
                result: result.text, state: result.isError ? .error : .success
            )
        }
    }
}
