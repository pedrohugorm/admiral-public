import XCTest
@testable import AdmiralCore

@MainActor
final class HookInjectionTests: XCTestCase {
    func testCommissionInjectsSettingsAndWritesHookFile() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: support) }
        let host = FakeTerminalHost()
        let zsh = AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles")
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            defaultAgentType: zsh, supportDir: support,
            hookHelper: "/X/admiral-hook")

        let session = manager.commission(callsign: "x", cwd: "/tmp")

        let last = try XCTUnwrap(host.spawned.first?.args.last)
        XCTAssertTrue(last.contains("--session-id"))
        XCTAssertTrue(last.contains("--settings '"), "appended --settings <path>: \(last)")
        let settingsURL = AdmiralPaths.settingsFile(base: support, token: session.token)
        XCTAssertTrue(last.contains(settingsURL.path))
        XCTAssertTrue(fm.fileExists(atPath: settingsURL.path))
        let data = try Data(contentsOf: settingsURL)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys),
                       ["PostToolUse", "Stop", "UserPromptSubmit", "Notification", "PreToolUse",
                        "SessionStart"],
                       "commission injects only the events Admiral's own features need — the "
                       + "touched-repos log, the structured-output tripwire, the watchdog's "
                       + "prompt log, the chat view, and the goals reminder's reset after "
                       + "clear/compact. Governance is hookd, registered "
                       + "globally, and must not reappear here.")
        XCTAssertNil(obj["permissions"], "hooks-only — never touch permissions")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/X/admiral-hook"))
    }

    func testCommissionInjectsBridgeMCPConfig() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: support) }
        let zsh = AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles")
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/bin/zsh", defaultAgentType: zsh, supportDir: support,
            bridgeMCPCommand: "/X/admiral-bridge-mcp")

        let session = manager.commission(callsign: "x", cwd: "/tmp")

        // The claude command gained `--mcp-config '<path>'`, and that config registers our binary.
        let mcpURL = AdmiralPaths.mcpConfigFile(base: support, token: session.token)
        let last = try XCTUnwrap(host.spawned.first?.args.last)
        XCTAssertTrue(last.contains("--mcp-config '\(mcpURL.path)'"), "appended --mcp-config <path>: \(last)")
        XCTAssertTrue(fm.fileExists(atPath: mcpURL.path), "bridge mcp config written")
        let text = String(decoding: try Data(contentsOf: mcpURL), as: UTF8.self)
        XCTAssertTrue(text.contains("\"bridge\""), "registers a server named bridge: \(text)")
        XCTAssertTrue(text.contains("/X/admiral-bridge-mcp"), "points at the bundled relay: \(text)")
    }

    func testDeleteRemovesSessionDir() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: support) }
        let zsh = AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles")
        let manager = SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/bin/zsh", defaultAgentType: zsh, supportDir: support,
            hookHelper: "/X/admiral-hook")
        let session = manager.commission(callsign: "x", cwd: "/tmp")
        let dir = AdmiralPaths.sessionDir(base: support, token: session.token)
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
        manager.delete(session.id)
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
    }

    /// Best-effort hook: if the settings file can't be written, `commission` must DECLINE to
    /// inject `--settings` (claude refuses to launch on a missing path → a dead session).
    /// Force a write failure by pointing `supportDir` at a regular FILE: `sessions/<token>/
    /// settings.json` underneath it can't be created (ENOTDIR).
    func testWriteFailureLeavesArgsUntouched() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("supportfile-\(UUID().uuidString)")
        try "not a directory".write(to: support, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: support) }
        let host = FakeTerminalHost()
        let zsh = AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles")
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/zsh",
            defaultAgentType: zsh, supportDir: support,
            hookHelper: "/X/admiral-hook")

        _ = manager.commission(callsign: "x", cwd: "/tmp")

        let last = try XCTUnwrap(host.spawned.first?.args.last)
        XCTAssertTrue(last.contains("--session-id"), "session still launches")
        XCTAssertFalse(last.contains("--settings"), "no hook injected when the settings write fails: \(last)")
    }

    func testNoHookCommandLeavesArgsUntouched() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/usr/bin/claude")
        _ = manager.commission(callsign: "x", cwd: "/tmp")
        XCTAssertFalse((host.spawned.first?.args.joined(separator: " ") ?? "").contains("--settings"))
    }
}
