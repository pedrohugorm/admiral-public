import Foundation
@testable import AdmiralCore

/// Records spawns and sends so tests can assert on injected bytes.
@MainActor
final class FakeTerminalHost: TerminalHost {
    final class Handle: TerminalHandle {
        let pid: Int32?
        init(pid: Int32?) { self.pid = pid }
    }

    private(set) var sent: [String] = []
    private(set) var spawned: [(executable: String, args: [String], cwd: String)] = []
    private(set) var lastEnv: [String: String] = [:]
    var nextPID: Int32 = 4242
    /// Simulate SwiftTerm's `shellPid == 0` at spawn time: the handle reports no pid.
    var spawnsWithoutPID = false

    func spawn(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: String,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) -> TerminalHandle {
        spawned.append((executable, args, cwd))
        lastEnv = env
        return Handle(pid: spawnsWithoutPID ? nil : nextPID)
    }

    func send(_ handle: TerminalHandle, text: String) { sent.append(text) }

    /// Optional screen contents tests can preload for `read_screen`.
    var visibleScreen: String? = nil
    func captureVisibleText(_ handle: TerminalHandle) -> String? { visibleScreen }

    func sendRaw(_ handle: TerminalHandle, text: String) { sent.append(text) }

    /// Every prompt submitted, with its pasted part kept apart from the typed text.
    private(set) var prompts: [TerminalPrompt] = []
    func submit(_ handle: TerminalHandle, prompt: TerminalPrompt) {
        prompts.append(prompt)
        sent.append(prompt.text)
        sent.append("\r")
    }

    private(set) var terminatedPIDs: [Int32?] = []
    /// Record instead of signalling a real pid (the default impl would `kill`).
    func terminate(_ handle: TerminalHandle) { terminatedPIDs.append((handle as? Handle)?.pid) }

    /// All injected text concatenated.
    var combined: String { sent.joined() }
}
