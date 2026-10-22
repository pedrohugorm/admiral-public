import Foundation

/// Finds the real `claude` pid given the pid Admiral spawned. A descendant-only port
/// of the Python bridge's `find_claude_pid`: `claude` (a binary that may fork/launch a
/// child) is at the spawned pid or below it. Admiral is claude's PARENT, so unlike the
/// bridge's in-session MCP we walk only self + descendants, never ancestors.
public enum ProcessTree {
    public typealias Snapshot = [Int32: (ppid: Int32, command: String)]

    /// A `ps` snapshot: pid → (ppid, command).
    public static func snapshot() -> Snapshot {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = Pipe()
        do { try ps.run() } catch { return [:] }
        // Drain the pipe BEFORE waiting. `ps -axo command` output on this machine
        // (Electron apps carry multi-KB command lines) exceeds the 64KB pipe buffer,
        // so calling waitUntilExit() before reading DEADLOCKS — ps blocks writing a
        // full pipe while we block waiting for it to exit. readDataToEndOfFile drains
        // as ps writes, letting it finish; then the wait returns immediately.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var snap: Snapshot = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.drop { $0 == " " }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            snap[pid] = (ppid, String(parts[2]))
        }
        return snap
    }

    private static func looksLikeClaude(_ command: String) -> Bool {
        command.lowercased().contains("claude")
    }

    /// The claude pid at `spawnPid` (its own command), else the first descendant whose
    /// command looks like claude; nil if none.
    public static func findClaudePid(spawnPid: Int32, snapshot snap: Snapshot? = nil) -> Int32? {
        let snap = snap ?? snapshot()
        if let own = snap[spawnPid], looksLikeClaude(own.command) {
            return spawnPid
        }
        var children: [Int32: [Int32]] = [:]
        for (pid, value) in snap { children[value.ppid, default: []].append(pid) }
        var stack = children[spawnPid] ?? []
        var seen = Set<Int32>()
        while let pid = stack.popLast() {
            if seen.contains(pid) { continue }
            seen.insert(pid)
            guard let entry = snap[pid] else { continue }
            if looksLikeClaude(entry.command) { return pid }
            stack.append(contentsOf: children[pid] ?? [])
        }
        return nil
    }

    private static let shellBasenames: Set<String> = [
        "zsh", "bash", "sh", "dash", "fish", "login", "-zsh", "-bash", "-sh",
    ]

    /// Among descendants of `spawnPid`, return the basename of an allowlisted TUI if one
    /// is running (deepest match wins). Never returns arguments — only a safe bare name
    /// like `k9s`. Nil when the allowlist is empty or nothing matches.
    public static func allowlistedRestoreCommand(
        spawnPid: Int32,
        allowlist: Set<String>,
        snapshot snap: Snapshot? = nil
    ) -> String? {
        let allow = Set(allowlist.map { $0.lowercased() }.filter { !$0.isEmpty })
        guard !allow.isEmpty else { return nil }
        let snap = snap ?? snapshot()
        var children: [Int32: [Int32]] = [:]
        for (pid, value) in snap { children[value.ppid, default: []].append(pid) }

        var best: (depth: Int, name: String)?
        var stack: [(Int32, Int)] = (children[spawnPid] ?? []).map { ($0, 1) }
        var seen = Set<Int32>()
        while let (pid, depth) = stack.popLast() {
            if seen.contains(pid) { continue }
            seen.insert(pid)
            if let kids = children[pid] { stack.append(contentsOf: kids.map { ($0, depth + 1) }) }
            guard let entry = snap[pid] else { continue }
            guard let name = executableBasename(entry.command) else { continue }
            if shellBasenames.contains(name) { continue }
            guard allow.contains(name) else { continue }
            if best == nil || depth >= best!.depth { best = (depth, name) }
        }
        return best?.name
    }

    /// First token of a `ps` command line → lowercase basename (`/opt/homebrew/bin/k9s` → `k9s`).
    static func executableBasename(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let token = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? trimmed
        let base = (token as NSString).lastPathComponent.lowercased()
        return base.isEmpty ? nil : base
    }
}
