import Foundation

/// Activity state of a session, sourced from `~/.claude/sessions/<pid>.json`.
public enum SessionStatus: String, Sendable, Codable, CaseIterable {
    case busy
    case idle
    /// Admiral's own marker: the claude process exited and the tab is back at its shell.
    case shell
    case unknown

    /// Parse the raw `status` string claude writes, defaulting to `.unknown`.
    ///
    /// Claude's `"shell"` is not our `.shell`: it writes it for a finished turn while a
    /// background task (a `run_in_background` Bash) is still running. That session is idle
    /// and alive, and reading it as exited took it out of the watchdog, the goals nudge and
    /// PR watch for as long as its CI watcher ran.
    public init(raw: String?) {
        if raw == "shell" { self = .idle; return }
        self = SessionStatus(rawValue: raw ?? "") ?? .unknown
    }
}
