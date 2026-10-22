import Foundation

/// Why Admiral is posting a macOS notification. Each kind has its own Settings toggle
/// (`admiral.notify.*`, default on) under the master `admiral.notificationsEnabled`.
public enum NotificationKind: String, CaseIterable, Sendable {
    /// Claude is asking a question (`PreToolUse` / `AskUserQuestion`).
    case question
    /// Claude is blocked on the user: permission prompt, elicitation, idle, agent input.
    case needsInput
    /// A terminal notification claude sent itself (OSC 9 / 777).
    case terminal
    /// A tab is actually done: the watchdog's "claims done", every goal met.
    case done
    /// A nudge that tells the tab to keep going (watchdog probe / goals nag). Off by default.
    /// Those nudges are typed into the tab and do not notify today; the kind exists so a
    /// future producer is gated, and off, from its first post.
    case nudge
    /// A station asked for one through the bridge `notify` tool. Master toggle only.
    case agent

    /// UserDefaults key of this kind's toggle; nil = only the master gates it.
    public var defaultsKey: String? {
        switch self {
        case .question: return NotificationPolicy.questionKey
        case .needsInput: return NotificationPolicy.needsInputKey
        case .terminal: return NotificationPolicy.terminalKey
        case .done: return NotificationPolicy.doneKey
        case .nudge: return NotificationPolicy.nudgeKey
        case .agent: return nil
        }
    }

    /// Whether a missing key means on. Only nudges are opt-in.
    public var defaultOn: Bool { self != .nudge }

    /// Skipped while the user is already looking at that tab (app active + tab selected).
    /// A question always notifies; a nudge and an explicit `notify` always did too.
    public var suppressedWhileViewing: Bool {
        self == .terminal || self == .needsInput
    }
}

/// The single answer to "may this notification be posted?". `NotificationService.post` is
/// the only caller, so no producer can bypass the settings.
public enum NotificationPolicy {
    public static let masterKey = "admiral.notificationsEnabled"
    public static let questionKey = "admiral.notify.question"
    public static let needsInputKey = "admiral.notify.needsInput"
    public static let terminalKey = "admiral.notify.terminal"
    public static let doneKey = "admiral.notify.done"
    public static let nudgeKey = "admiral.notify.nudge"

    /// A stored value always wins; a missing key falls back to `defaultOn`.
    public static func flag(_ key: String, in defaults: UserDefaults, defaultOn: Bool = true) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultOn
    }

    public static func shouldPost(_ kind: NotificationKind, viewing: Bool,
                                  defaults: UserDefaults = .standard) -> Bool {
        guard flag(masterKey, in: defaults) else { return false }
        if let key = kind.defaultsKey, !flag(key, in: defaults, defaultOn: kind.defaultOn) { return false }
        if viewing && kind.suppressedWhileViewing { return false }
        return true
    }
}

/// What a hook payload says to the user: the kind, the tail of the title after `@CALLSIGN`,
/// and the body. Pure, so the mapping is testable without an app.
public struct HookNotification: Equatable, Sendable {
    public let kind: NotificationKind
    /// "is asking" / "needs you" — the app prefixes `@callsign `.
    public let titleSuffix: String
    public let body: String

    public static let maxBody = 200

    /// `Notification` types that mean claude is waiting on the user.
    static let needsInputTypes: Set<String> =
        ["permission_prompt", "elicitation_dialog", "idle_prompt", "agent_needs_input",
         "elicitation_url_dialog", "worker_permission_prompt"]

    /// nil = nothing to say (other tools, other notification types, unreadable payload).
    public static func from(event: String, payload: Data) -> HookNotification? {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        switch event {
        case "PreToolUse":
            guard obj["tool_name"] as? String == "AskUserQuestion" else { return nil }
            let input = obj["tool_input"] as? [String: Any]
            let questions = input?["questions"] as? [[String: Any]]
            let text = (questions?.first?["question"] as? String)
                ?? (input?["question"] as? String) ?? ""
            let body = truncated(text)
            return HookNotification(kind: .question, titleSuffix: "is asking",
                                    body: body.isEmpty ? "Claude has a question for you" : body)
        case "Notification":
            guard let type = obj["notification_type"] as? String, needsInputTypes.contains(type) else { return nil }
            let message = truncated(obj["message"] as? String ?? "")
            // AskUserQuestion's own permission prompt: the PreToolUse notification covers it.
            if type == "permission_prompt", message.contains("AskUserQuestion") { return nil }
            return HookNotification(kind: .needsInput, titleSuffix: "needs you",
                                    body: message.isEmpty ? "Claude is waiting for you" : message)
        default:
            return nil
        }
    }

    static func truncated(_ text: String, limit: Int = maxBody) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
