import Foundation

/// Reminds a watched session, as it ends a turn, that "done" has to be reported for the
/// watchdog to stop — the agent otherwise finishes the work, says so in prose, and the
/// watchdog stays armed until its next probe.
///
/// The hook helper runs in its own process and the watchdog's phase lives in the app's
/// defaults, so the app mirrors "armed, and for what" into `sessions/<token>/watchdog.json`
/// (`mark`/`unmark`) and the Stop hook reads that. One block per user prompt, like the goal
/// review, so it cannot loop: the session reports or ends its turn.
public enum WatchdogReminder {
    public static let maxBlocksPerPrompt = 1

    private struct Marker: Codable, Equatable { var trigger: String }
    private struct Ledger: Codable { var blocks: Int }

    static func markerURL(base: URL, token: String) -> URL {
        AdmiralPaths.sessionDir(base: base, token: token).appendingPathComponent("watchdog.json")
    }

    private static func ledgerURL(base: URL, token: String) -> URL {
        AdmiralPaths.sessionDir(base: base, token: token)
            .appendingPathComponent("watchdog-reminder.json")
    }

    // MARK: - App side

    /// The watchdog is armed for `trigger`. Writes only on change.
    public static func mark(trigger: String, base: URL, token: String) {
        guard self.trigger(base: base, token: token) != trigger,
              let data = try? JSONEncoder().encode(Marker(trigger: trigger)) else { return }
        let url = markerURL(base: base, token: token)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The watchdog is off for this session.
    public static func unmark(base: URL, token: String) {
        try? FileManager.default.removeItem(at: markerURL(base: base, token: token))
    }

    /// What the watchdog is armed for, or nil when it is not.
    public static func trigger(base: URL, token: String) -> String? {
        (try? Data(contentsOf: markerURL(base: base, token: token)))
            .flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }?.trigger
    }

    // MARK: - Hook side

    /// A new prompt — the reminder gets its budget back.
    public static func reset(base: URL, token: String) {
        try? FileManager.default.removeItem(at: ledgerURL(base: base, token: token))
    }

    /// The Stop block for a watched session, or nil when it is not watched or has already
    /// been reminded since the user last spoke. Spends the budget when it returns a block.
    public static func stopJSON(base: URL, token: String) -> String? {
        guard let trigger = trigger(base: base, token: token) else { return nil }
        let url = ledgerURL(base: base, token: token)
        let spent = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }?.blocks ?? 0
        guard spent < maxBlocksPerPrompt else { return nil }
        if let data = try? JSONEncoder().encode(Ledger(blocks: spent + 1)) {
            try? data.write(to: url, options: .atomic)
        }
        return blockJSON(trigger: trigger)
    }

    static func blockJSON(trigger: String) -> String {
        let reason = "watchdog — a watchdog is watching this session for \"\(trigger)\". If that "
            + "work is done (or the user said it is), report it now: call "
            + "`set_structured_output` with {\"status\":\"done\",\"reason\":\"<what was "
            + "delivered and how it was verified>\"} — that is what turns the watchdog off. "
            + "If it is not done, do not report in_progress: take the next step yourself now. "
            + "Check the live state of anything you are waiting on (a CI run that already "
            + "failed is work to fix, not a wait). End your turn only when the next step is "
            + "waiting on something outside this session or something only the user can "
            + "unblock, and name it."
        let shown = "Watchdog reminder: asked the session to report done if \"\(trigger)\" is finished."
        return "{\"decision\":\"block\",\"reason\":\(JSONText.escaped(reason))"
            + ",\"systemMessage\":\(JSONText.escaped(shown))}"
    }
}
