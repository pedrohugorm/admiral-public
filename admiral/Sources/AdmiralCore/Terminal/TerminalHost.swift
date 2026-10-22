import Foundation

/// Opaque handle to a spawned PTY-backed process.
public protocol TerminalHandle: AnyObject {
    var pid: Int32? { get }
}

/// The single seam through which Admiral talks to a terminal. The app provides a
/// SwiftTerm-backed implementation; tests provide a fake. Centralizing PTY access
/// here keeps the "how do we reach a terminal" decision at one site.
@MainActor
public protocol TerminalHost: AnyObject {
    /// Spawn `executable args` in a PTY at `cwd`. `onExit` fires when the child ends.
    func spawn(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: String,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) -> TerminalHandle

    /// Write raw text to the child (no implicit newline).
    func send(_ handle: TerminalHandle, text: String)

    /// Type a line and submit it. The SwiftTerm host inserts a pause before the
    /// carriage return so a TUI like claude ingests the paste before the Enter
    /// (otherwise the Enter is swallowed and nothing is submitted).
    func submit(_ handle: TerminalHandle, text: String)

    /// Submit `prompt`, its pasted part as one bracketed paste where the program accepts one.
    func submit(_ handle: TerminalHandle, prompt: TerminalPrompt)

    /// Terminate the child process backing a handle (used when deleting a session).
    func terminate(_ handle: TerminalHandle)

    /// Visible terminal viewport as plain text (one line per row, right-trimmed), or nil
    /// when this host cannot read a screen (tests without a live emulator).
    func captureVisibleText(_ handle: TerminalHandle) -> String?

    /// Write raw bytes to the PTY with NO trailing Enter — for key chords / CSI sequences.
    /// Distinct from `submit`, which pastes text then presses Return.
    func sendRaw(_ handle: TerminalHandle, text: String)
}

public extension TerminalHost {
    func submit(_ handle: TerminalHandle, text: String) {
        send(handle, text: text)
        send(handle, text: "\r")
    }

    /// A host that cannot paste types the whole prompt.
    func submit(_ handle: TerminalHandle, prompt: TerminalPrompt) {
        submit(handle, text: prompt.text)
    }

    func captureVisibleText(_ handle: TerminalHandle) -> String? { nil }

    func sendRaw(_ handle: TerminalHandle, text: String) {
        send(handle, text: text)
    }

    /// Default: signal the child's process group (pgid == pid for a setsid session
    /// leader), reaping grandchildren too. Hosts may override with a cleaner teardown.
    /// `pid > 1` guards against `kill(-0, …)` / `kill(-1, …)` hitting our own group.
    func terminate(_ handle: TerminalHandle) {
        if let pid = handle.pid, pid > 1 { kill(-pid, SIGTERM) }
    }
}
