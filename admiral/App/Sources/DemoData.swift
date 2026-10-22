import Foundation
import AdmiralCore

/// Seeds a realistic fleet + the reference "Scheduled ordering" conversation so the
/// UI can be screenshotted without a live agent. Enabled via `ADMIRAL_DEMO=1`.
enum DemoData {
    @MainActor
    static func seed(into manager: SessionManager) {
        // Sibling list entries for visual fidelity.
        for (name, branch, status) in [
            ("Loyalty rewards", "work/delivery-app", SessionStatus.idle),
            ("Loyalty Rewards System", "", SessionStatus.idle),
            ("Debug promo code", "debug/promo-delivery", SessionStatus.idle),
        ] {
            var s = AgentSession(callsign: name, cwd: NSHomeDirectory() + "/workspace/coffee-ordering", status: status, title: name)
            s.gitBranch = branch.isEmpty ? nil : branch
            manager.register(s, handle: nil)
        }

        let convo = TranscriptParser.parse(lines: lines)
        var session = AgentSession(
            callsign: "Scheduled ordering",
            cwd: NSHomeDirectory() + "/workspace/coffee-ordering",
            status: .busy,
            title: convo.title
        )
        session.gitBranch = "cloud/scheduled-ordering"
        // A Claude session id + transcript on disk so the tab opens in Chat with the sample
        // conversation (the README main-window shot). Written under the (isolated) support dir.
        let sid = "demo-scheduled-ordering"
        let transcript = manager.supportDir.appendingPathComponent("demo-\(sid).jsonl")
        try? (stamped(lines + chatLines).joined(separator: "\n") + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        session.claudeSessionID = sid
        session.transcriptPath = transcript.path
        ChatLedger.setMode(.chat, base: manager.supportDir, session: sid)
        manager.register(session, handle: nil)
        manager.setConversation(session.id, convo)
        manager.selectedID = session.id
    }

    /// Adds the timestamp/uuid/sessionId a real transcript line carries (Chat history needs them).
    private static func stamped(_ raw: [String]) -> [String] {
        let start = Date().addingTimeInterval(-Double(raw.count) * 40)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return raw.enumerated().map { i, line in
            guard var obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String != "ai-title" else { return line }
            obj["timestamp"] = fmt.string(from: start.addingTimeInterval(Double(i) * 40))
            obj["uuid"] = UUID().uuidString.lowercased()
            obj["sessionId"] = "demo-scheduled-ordering"
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return line }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The rest of the sample conversation, shown in Chat.
    static let chatLines: [String] = [
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Schema and checkout are done:\n\n- `orders.scheduled_for` (nullable `timestamptz`) with a migration and an index\n- Checkout shows a **Deliver later** picker limited to store hours\n\nNow wiring the delivery queue worker so scheduled orders are released 20 minutes before their slot."}]}}"#,
        #"{"type":"user","message":{"role":"user","content":"Make sure orders scheduled outside store hours are rejected server-side too."}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Good call. I'll add `validateScheduledWindow` to `OrderService.create` so it returns `422` with a clear message, plus tests for before-open, after-close and holiday slots."}]}}"#,
    ]

    static let lines: [String] = [
        #"{"type":"ai-title","aiTitle":"Implement scheduled ordering"}"#,
        #"{"type":"user","message":{"role":"user","content":"Add scheduled ordering so customers can pick a future delivery time when placing an order."}}"#,
        #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"I'll add a `scheduledFor` field to the order schema, a time-picker to checkout, and a fulfillment worker that holds orders until the scheduled window."}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TaskCreate","input":{"subject":"Add scheduledFor to order schema"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Task #1 created successfully: Add scheduledFor to order schema"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"TaskCreate","input":{"subject":"Add time picker to checkout"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Task #2 created successfully: Add time picker to checkout"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"TaskCreate","input":{"subject":"Wire delivery queue worker"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"Task #3 created successfully: Wire delivery queue worker"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"u1","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"u2","name":"TaskUpdate","input":{"taskId":"2","status":"completed"}}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"u3","name":"TaskUpdate","input":{"taskId":"3","status":"in_progress"}}]}}"#,
    ]
}
