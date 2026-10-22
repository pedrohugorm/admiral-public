import Foundation

/// The hook side of the Chat view: turns claude's hook payloads into chat-ledger events, and
/// keeps the built-in `AskUserQuestion` out of a session whose tab is showing Chat.
///
/// Cheap and local only — these hooks run inline with the agent. Every entry point is a
/// silent no-op on a payload it can't read, so a malformed hook never wedges a session.
public enum ChatHookHandler {
    /// The bridge mirror the model is sent to instead of the built-in.
    public static let mirrorToolName = "mcp__bridge__AskUserQuestion"

    public static func prompt(payload: Data, base: URL, now: () -> String = PostToolUseHandler.timestamp) {
        guard let (obj, session) = parse(payload),
              let prompt = obj["prompt"] as? String, !prompt.isEmpty else { return }
        let source = ChatLedger.consumeInjected(prompt: prompt, base: base, session: session)
        ChatLedger.append(ChatEvent(ts: now(), kind: .prompt, text: prompt, source: source),
                          base: base, session: session)
    }

    /// `last_assistant_message` is read from the payload, never from the transcript: the
    /// transcript can lag the Stop, so reading it would show the previous turn's reply.
    public static func stop(payload: Data, base: URL, now: () -> String = PostToolUseHandler.timestamp) {
        guard let (obj, session) = parse(payload),
              let message = obj["last_assistant_message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ChatLedger.append(ChatEvent(ts: now(), kind: .reply, text: message), base: base, session: session)
    }

    /// Only the notifications that mean claude is blocked on the user become chat events.
    static let blockingNotifications: Set<String> = ["permission_prompt", "elicitation_dialog"]

    public static func notification(payload: Data, base: URL, now: () -> String = PostToolUseHandler.timestamp) {
        guard let (obj, session) = parse(payload),
              let type = obj["notification_type"] as? String,
              blockingNotifications.contains(type) else { return }
        let message = obj["message"] as? String ?? "claude needs your permission"
        ChatLedger.append(ChatEvent(ts: now(), kind: .needs, text: message), base: base, session: session)
    }

    /// The deny JSON for the built-in `AskUserQuestion` while the session's tab shows Chat;
    /// nil (allow) otherwise, so a Terminal-mode tab keeps claude's own dialog.
    public static func preToolUse(payload: Data, base: URL) -> String? {
        guard let (obj, session) = parse(payload),
              obj["tool_name"] as? String == "AskUserQuestion",
              ChatLedger.mode(base: base, session: session) == .chat else { return nil }
        return denyJSON
    }

    public static let denyReason =
        "The user is in Admiral's chat view, where the built-in AskUserQuestion cannot be "
        + "answered. Call \(mirrorToolName) with exactly the same input instead. If that tool "
        + "is unavailable, ask the questions as plain text in your reply and end your turn."

    public static var denyJSON: String {
        let object: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": denyReason,
        ]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(_ payload: Data) -> ([String: Any], String)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let session = obj["session_id"] as? String, !session.isEmpty else { return nil }
        return (obj, session)
    }
}
