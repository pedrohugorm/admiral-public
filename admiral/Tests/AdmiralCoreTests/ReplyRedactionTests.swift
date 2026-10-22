import XCTest
@testable import AdmiralCore

/// The Admiral side of PHI-redacted reply copies: the `admiral` mod in every claude tab, the
/// per-tab flag that turns it on, and reading back what it wrote for the SSE feed.
@MainActor
final class ReplyRedactionTests: XCTestCase {
    private func tempDefaults() -> UserDefaults { UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")! }

    private func manager() -> (SessionManager, FakeTerminalHost, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("admiral-redact-\(UUID().uuidString)")
        let host = FakeTerminalHost()
        let claude = AgentType(id: "claude_code", displayName: "Claude", executableName: "zsh",
                               defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
                               symbolName: "sparkles")
        let m = SessionManager(host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"),
                               executablePath: "/bin/zsh", defaultAgentType: claude,
                               appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
                               openSessionsStore: OpenSessionsStore(defaults: tempDefaults()),
                               supportDir: base)
        return (m, host, base)
    }

    private func flagged(_ m: SessionManager, _ s: AgentSession) -> Bool {
        FileManager.default.fileExists(
            atPath: AdmiralPaths.redactRepliesFlag(base: m.supportDir, token: s.token).path)
    }

    func testSettingOnFlagsEveryTabAndOffFlagsNone() {
        let (m, _, base) = manager()
        defer { try? FileManager.default.removeItem(at: base) }
        var on = false
        m.redactReplies = { on }
        let permanent = m.commission(callsign: "keep", cwd: "/a")
        let scratch = m.commission(callsign: "scout", cwd: "/b", scratch: true)
        XCTAssertFalse(flagged(m, permanent))
        XCTAssertFalse(flagged(m, scratch), "off: the mod writes nothing and calls no model")

        on = true
        m.syncRedactionFlags()
        XCTAssertTrue(flagged(m, permanent), "on reaches tabs already running")
        XCTAssertTrue(flagged(m, scratch))
        let later = m.commission(callsign: "new", cwd: "/c")
        XCTAssertTrue(flagged(m, later), "and tabs launched after")

        on = false
        m.syncRedactionFlags()
        XCTAssertFalse(flagged(m, permanent))
        XCTAssertFalse(flagged(m, later))
    }

    /// Every claude tab loads the mod and is told where its flag and output folder are.
    func testEveryManagedTabLoadsTheModWithItsPaths() throws {
        let (m, host, base) = manager()
        defer { try? FileManager.default.removeItem(at: base) }
        let mod = base.appendingPathComponent("mods/admiral")
        try FileManager.default.createDirectory(at: mod, withIntermediateDirectories: true)
        m.modDir = mod.path
        _ = m.commission(callsign: "keep", cwd: "/a")
        let scratch = m.commission(callsign: "scout", cwd: "/b", scratch: true)
        XCTAssertEqual(host.spawned.count, 2)
        for spawn in host.spawned {
            XCTAssertTrue(spawn.args.joined(separator: " ").contains("--plugin-dir '\(mod.path)'"),
                          "got: \(spawn.args)")
        }
        XCTAssertEqual(host.lastEnv["ADMIRAL_REDACT_FLAG"],
                       AdmiralPaths.redactRepliesFlag(base: base, token: scratch.token).path)
        XCTAssertEqual(host.lastEnv["ADMIRAL_REDACTED_DIR"],
                       AdmiralPaths.redactedOutputDir(base: base, token: scratch.token).path)
        XCTAssertEqual(host.lastEnv["ADMIRAL_OUTPUT_FILE"],
                       AdmiralPaths.structuredOutputFile(base: base, token: scratch.token).path)
    }

    /// The copies decode exactly as the mod writes them (nulls, `completedAt` passed through
    /// from the slot file); a half-written one is skipped until it decodes. With the flag off
    /// the feed gets nil and streams the raw slot instead.
    func testFeedReadsTheModsOutputCopiesOnlyWhileFlagged() throws {
        let (m, _, base) = manager()
        defer { try? FileManager.default.removeItem(at: base) }
        var on = true
        m.redactReplies = { on }
        let s = m.commission(callsign: "keep", cwd: "/a")
        let dir = AdmiralPaths.redactedOutputDir(base: base, token: s.token)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func put(_ name: String, _ body: String) throws {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
        try put("output-1.json", #"{"round":1,"status":"fulfilled","result":{"slack_reply":"[REDACTED] ok"},"completedAt":781000000.5,"violations":null,"failed":false,"model":"sonnet"}"#)
        try put("output-2.json", #"{"round":2,"status":"fulfilled","result":null,"completedAt":null,"violations":null,"failed":true,"model":"sonnet"}"#)
        try put("output-3.json", #"{"round":3,"stat"#)  // mid-write
        let copies = try XCTUnwrap(m.feedRedactedOutput(tabID: s.id)).sorted { $0.round < $1.round }
        XCTAssertEqual(copies, [
            RedactedOutput(round: 1, status: .fulfilled, result: .object(["slack_reply": .string("[REDACTED] ok")]),
                           completedAt: Date(timeIntervalSinceReferenceDate: 781000000.5)),
            RedactedOutput(round: 2, status: .fulfilled, failed: true),
        ])

        on = false
        m.syncRedactionFlags()
        XCTAssertNil(m.feedRedactedOutput(tabID: s.id))
    }
}
