import Foundation

/// Builds a `PlanModel` (the plan/todo card) by folding the tool-call stream.
///
/// Two sources, one model:
///  - **Task\*** — `TaskCreate` adds an item (id taken from its result "Task #N"),
///    `TaskUpdate {taskId,status}` changes its state. This is what the user's
///    sessions actually emit.
///  - **TodoWrite** — a full `{todos:[{content,status}]}` snapshot; latest wins.
///
/// A TodoWrite snapshot, if present, takes precedence (it is itself the whole list).
final class PlanFolder {
    private struct Create { let subject: String; var taskID: String? }

    private var creates: [String: Create] = [:]   // tool_use_id -> Create
    private var createOrder: [String] = []        // tool_use_ids, in emission order
    private var updates: [(taskID: String, status: String)] = []
    private var todoSnapshot: [PlanItem]?

    func recordToolUse(id: String, name: String, input: JSONValue?) {
        switch name {
        case "TaskCreate":
            let subject = input?["subject"]?.stringValue ?? "(task)"
            creates[id] = Create(subject: subject, taskID: nil)
            createOrder.append(id)
        case "TaskUpdate":
            guard let taskID = input?["taskId"]?.stringValue else { return }
            let status = input?["status"]?.stringValue ?? "in_progress"
            updates.append((taskID, status))
        case "TodoWrite":
            guard let todos = input?["todos"]?.arrayValue else { return }
            todoSnapshot = todos.enumerated().map { idx, t in
                let content = t["content"]?.stringValue ?? ""
                return PlanItem(
                    id: content.isEmpty ? "todo-\(idx)" : content,
                    title: content,
                    state: PlanItemState(statusString: t["status"]?.stringValue)
                )
            }
        default:
            break
        }
    }

    /// Resolve each `TaskCreate`'s numeric task id from its tool result text.
    func applyResults(_ results: [String: (text: String, isError: Bool)]) {
        for id in createOrder {
            guard let result = results[id], let taskID = Self.parseTaskID(result.text) else { continue }
            creates[id]?.taskID = taskID
        }
    }

    func model() -> PlanModel? {
        if let snapshot = todoSnapshot, !snapshot.isEmpty {
            return PlanModel(items: snapshot)
        }
        guard !createOrder.isEmpty else { return nil }

        var statusByTask: [String: String] = [:]
        for update in updates { statusByTask[update.taskID] = update.status }

        var items: [PlanItem] = []
        for createID in createOrder {
            guard let create = creates[createID] else { continue }
            let taskID = create.taskID ?? createID
            let status = statusByTask[taskID] ?? "pending"
            if status == "deleted" { continue }
            items.append(PlanItem(id: taskID, title: create.subject, state: PlanItemState(statusString: status)))
        }
        return items.isEmpty ? nil : PlanModel(items: items)
    }

    /// "Task #2 created successfully: …" -> "2"
    static func parseTaskID(_ text: String) -> String? {
        guard let range = text.range(of: #"Task #(\d+)"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: "#").last.map(String.init)
    }
}
