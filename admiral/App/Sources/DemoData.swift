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
        manager.register(session, handle: nil)
        manager.setConversation(session.id, convo)
        manager.selectedID = session.id
    }

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
