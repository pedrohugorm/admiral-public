import Foundation

/// The goal messages the hook helper prints, and the wire JSON that carries them.
///
/// **The JSON IS the mechanism.** A hook's plain stdout is never shown in the transcript, so
/// a bare string reaches the model and nobody else — which is exactly how a reminder becomes
/// invisible. `systemMessage` is the field Claude Code shows the user; `additionalContext`
/// (UserPromptSubmit) and `reason` (Stop) are what reach the model. Every payload here is
/// hand-built with a fixed key order, like `StopInstruction`, so tests can assert the bytes.
public enum GoalsReminder {
    /// One line for the user. With nothing open it ASKS for goals rather than reporting
    /// their absence — "no goals set" is a status nobody can act on, and this line is the
    /// only part of the mechanism a human ever sees.
    public static func systemMessage(for goals: SessionGoals?) -> String {
        guard let goals, !goals.outstanding.isEmpty else {
            return goals?.visible.isEmpty == false
                ? "⚑ All goals met. Set the next goals now."
                : "⚑ Set goals for this session — what would prove it done?"
        }
        let (met, total) = goals.progress
        let ids = goals.outstanding.map(\.id).joined(separator: ", ")
        return "⚑ Goals \(met)/\(total) — still open: \(ids)"
    }

    /// The one exception, the same wording on every prompt. A request that changes anything is
    /// never a skip; "nothing to track" was a judgment call models made too often.
    static let skipRule = "Skip only if this prompt is a pure question or chat and you will "
        + "edit, run, send or ship nothing for it. Any request that does is not a skip: set "
        + "goals first. If you skip, say nothing about it."

    /// The instruction the model acts on. Every prompt gets one: with goals open it is a
    /// reminder to resolve them, and without it is a prompt to set some — a session that
    /// never set goals is exactly the one that most needs asking.
    public static func context(for goals: SessionGoals?) -> String {
        guard let goals, !goals.outstanding.isEmpty else {
            // Once every goal is met, the next request gets goals before anything else, and
            // only a pure question or chat may skip them. A session that never set goals keeps
            // the one-off opt-out.
            let headline = goals?.visible.isEmpty == false
                ? "every goal is met. Before you do anything else, call `set_goal_self` with the goals for this request."
                : "set goals for this session. Before you do anything else, call `set_goal_self` with the goals for this request."
            let optOut = skipRule
            return """
                ADMIRAL GOALS — \(headline)
                Set them with `set_goal_self` (admiral bridge MCP): the OUTCOMES this \
                request asked for — what will be true when it is done, in the words it was \
                asked in — each with the check that proves it. Not the commands you will run \
                to get there, and nothing the request did not ask for. Each one must be able \
                to FAIL: spend them on what would break quietly, not on a bullet-by-bullet \
                transcript of the ask. And each must be CLOSEABLE — an open goal keeps this \
                session probed and nagged, so one that can always be pursued further never \
                lets it stop. \(optOut)
                """
        }
        let open = goals.outstanding
        let (met, total) = goals.progress
        let list = open.map { "  \($0.id)) \($0.text)" }.joined(separator: "\n")
        return """
            ADMIRAL GOALS — \(met)/\(total) met, \(open.count) still open:
            \(list)
            When one is met, call `update_goals` (admiral bridge MCP) with its id in `done` — \
            or in `cancelled` if it no longer applies. Setting a new goal list is refused \
            while any of these is open. Keep working toward the rest; do not restate them \
            back to the user.
            """
    }

    /// The short form sent when the session was already given `context(for:)` unchanged.
    /// Context accumulates until compaction, so the full text is sent once per change. With
    /// goals open there is nothing to add (the list is already in context, and the Stop review
    /// re-lists them); without, a prompt may be the first with work in it, so a line still asks.
    public static func followUp(for goals: SessionGoals?) -> String? {
        guard let goals, !goals.outstanding.isEmpty else {
            let state = goals?.visible.isEmpty == false ? "every goal is met" : "none set"
            return "ADMIRAL GOALS — \(state). Call `set_goal_self` before anything else, as "
                + "described earlier. " + skipRule
        }
        return nil
    }

    /// `UserPromptSubmit` output: the visible line on EVERY prompt — goals are only useful if
    /// the session is asked about them while it still has the chance to set or close them —
    /// and `context` (nil = none) added to the turn's context.
    public static func promptJSON(for goals: SessionGoals?, context: String?) -> String {
        let message = "{\"systemMessage\":\(JSONText.escaped(systemMessage(for: goals)))"
        guard let context else { return message + "}" }
        return message
            + ",\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\""
            + ",\"additionalContext\":\(JSONText.escaped(context))}}"
    }

    /// The first time a session sees this reminder: the full context.
    public static func promptJSON(for goals: SessionGoals?) -> String {
        promptJSON(for: goals, context: context(for: goals))
    }

    /// `Stop` output: block the turn once so the session reviews its goals before finishing.
    public static func stopReviewJSON(for goals: SessionGoals) -> String {
        let open = goals.outstanding
        let list = open.map { "\($0.id)) \($0.text)" }.joined(separator: "; ")
        let reason = "goal review — you are ending the turn with \(open.count) goal"
            + "\(open.count == 1 ? "" : "s") still open: \(list). For each: if it is met, call "
            + "`update_goals` with its id in `done`; if it no longer applies, put it in "
            + "`cancelled`; if there is a next step you can take toward it, take it now. Before "
            + "calling a goal blocked, check the blocker's live state (a CI run that already "
            + "failed is work to fix, not a wait). End your turn only when every open goal is "
            + "waiting on something outside this session or something only the user can "
            + "unblock, and name what."
        return "{\"decision\":\"block\",\"reason\":\(JSONText.escaped(reason))"
            + ",\"systemMessage\":\(JSONText.escaped(systemMessage(for: goals)))}"
    }

    /// The reminder for the session a hook payload names, or nil when it owes nothing. The full
    /// context goes out only when it differs from what the session was last sent (the
    /// `.reminded` marker); otherwise the short `followUp`. The marker is written before the
    /// reply, so a failed write re-sends next time rather than going quiet.
    ///
    /// `prepending` (another feature's context, e.g. `GroupReminder`) goes first in the same
    /// `additionalContext`: one prompt gets one hook reply, so the arms share it.
    public static func promptJSON(payload: Data, base: URL, prepending extra: String? = nil) -> String? {
        guard let sessionID = sessionID(in: payload) else { return nil }
        let goals = GoalsStore(base: base).goals(forSession: sessionID)
        let full = context(for: goals)
        let marker = AdmiralPaths.goalsRemindedFile(base: base, session: sessionID)
        let own: String?
        if (try? String(contentsOf: marker, encoding: .utf8)) == full {
            own = followUp(for: goals)
        } else {
            try? full.write(to: marker, atomically: true, encoding: .utf8)
            own = full
        }
        let parts = [extra, own].compactMap { $0 }
        return promptJSON(for: goals, context: parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
    }

    /// Forget what the session was sent, so the next prompt carries the full context again.
    /// Called when compaction drops the earlier reminder from the session's context.
    public static func forgetSent(payload: Data, base: URL) {
        guard let sessionID = sessionID(in: payload) else { return }
        try? FileManager.default.removeItem(at: AdmiralPaths.goalsRemindedFile(base: base, session: sessionID))
    }

    public static func sessionID(in payload: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let sessionID = obj["session_id"] as? String, !sessionID.isEmpty else { return nil }
        return sessionID
    }
}

/// JSON string literals (with quotes) — via JSONSerialization so every escape rule matches
/// the wire. Shared by every hand-built hook payload.
public enum JSONText {
    public static func escaped(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let text = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }
}
