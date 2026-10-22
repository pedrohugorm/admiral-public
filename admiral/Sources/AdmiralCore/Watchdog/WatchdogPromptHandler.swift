import Foundation

/// Handles a Claude Code `UserPromptSubmit` payload in the hook helper: appends the prompt
/// text to the session's `prompts.jsonl` so the app-side watchdog can match trigger phrases.
/// Cheap and local only — UserPromptSubmit hooks block the agent, so append-and-return.
public enum WatchdogPromptHandler {
    /// Cap per record so a single `write(2)` carries the whole line (see `AtomicAppend`).
    public static let maxPromptLength = 4000

    public static func handle(payload: Data, base: URL, token: String,
                              now: () -> String = PostToolUseHandler.timestamp) {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              obj["hook_event_name"] as? String == "UserPromptSubmit",
              let prompt = obj["prompt"] as? String, !prompt.isEmpty else { return }
        let event = PromptEvent(ts: now(), prompt: String(prompt.prefix(maxPromptLength)))
        guard let data = try? JSONEncoder().encode(event) else { return }
        AtomicAppend.line(data, to: AdmiralPaths.promptsLog(base: base, token: token))
    }
}
