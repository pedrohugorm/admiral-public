import XCTest
@testable import AdmiralCore

/// Values spliced into the `zsh -ilc` launch line, and the hook command claude runs, reach the
/// program as one literal word whatever they hold.
///
/// SAFETY: the only command any payload here could ever smuggle is `touch <marker>`, where the
/// marker sits in a fresh temp dir that is also the shell's HOME, TMPDIR and cwd. The tests
/// assert the marker was NOT created. Nothing here deletes, moves or overwrites anything.
@MainActor
final class ShellQuoteTests: XCTestCase {
    func testSingleWrapsAndEscapesEmbeddedQuotes() {
        XCTAssertEqual(ShellQuote.single("plain"), "'plain'")
        XCTAssertEqual(ShellQuote.single(""), "''")
        XCTAssertEqual(ShellQuote.single("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellQuote.single("'"), #"''\'''"#)
        XCTAssertEqual(ShellQuote.single("$(x) `y` \"z\" \\"), #"'$(x) `y` "z" \'"#)
    }

    /// The quoted word, handed to a real `sh` and `zsh` (no rc files), prints back exactly the
    /// input and runs none of it.
    func testQuotedWordRoundTripsThroughARealShellAndRunsNothing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("quote-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }   // only the temp dir this test made
        let marker = dir.appendingPathComponent("marker").path

        let payloads = [
            "it's",
            "'; touch \(marker); echo '",
            "$(touch \(marker))",
            "`touch \(marker)`",
            "a\"b\\c $X * ? [x] {a,b} ! # & | < > ; end\nsecond line",
            "''",
            #"'\''"#,
        ]
        for shell in [["/bin/sh", "-c"], ["/bin/zsh", "-f", "-c"]] {
            for payload in payloads {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell[0])
                process.arguments = Array(shell.dropFirst()) + ["printf %s " + ShellQuote.single(payload)]
                process.environment = ["HOME": dir.path, "TMPDIR": dir.path + "/", "PATH": "/usr/bin:/bin"]
                process.currentDirectoryURL = dir
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(String(decoding: data, as: UTF8.self), payload, "\(shell[0]): \(payload)")
                XCTAssertEqual(process.terminationStatus, 0, "\(shell[0]): \(payload)")
                XCTAssertFalse(fm.fileExists(atPath: marker), "\(shell[0]) ran part of: \(payload)")
            }
        }
    }

    // MARK: - commission's launch line

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")! }

    private let claude = AgentType(
        id: "claude_code", displayName: "Claude", executableName: "zsh",
        defaultArgs: ["-ilc", "command claude --session-id \(SessionManager.sessionIDPlaceholder) --name \(SessionManager.sessionNamePlaceholder)"],
        symbolName: "sparkles")

    private func manager(_ host: FakeTerminalHost, support: URL, helper: String? = nil) -> SessionManager {
        SessionManager(host: host, claudeHome: support.appendingPathComponent("claude"), executablePath: "/bin/zsh",
                       appearanceStore: SessionAppearanceStore(defaults: defaults()),
                       openSessionsStore: OpenSessionsStore(defaults: defaults()),
                       supportDir: support, hookHelper: helper,
                       touchedReposStore: TouchedReposStore(defaults: defaults()))
    }

    /// Every path commission splices in (`--settings`, `--plugin-dir`) and the hook helper's
    /// path inside the settings file go through `ShellQuote.single`, so an apostrophe in a
    /// folder name cannot end the quoted word. Asserted on strings only; nothing is spawned.
    func testPathsInTheLaunchLineAndHookCommandAreQuoted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("Pat's support")
        let mod = root.appendingPathComponent("Pat's mod")
        try fm.createDirectory(at: mod, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("Pat's app/admiral-hook").path

        let host = FakeTerminalHost()
        let sessions = manager(host, support: support, helper: helper)
        sessions.modDir = mod.path
        let session = sessions.commission(callsign: "w", cwd: root.path, agentType: claude)
        let line = try XCTUnwrap(host.spawned.first?.args.last)

        let settings = AdmiralPaths.settingsFile(base: support, token: session.token).path
        XCTAssertTrue(line.contains(" --settings " + ShellQuote.single(settings)), line)
        XCTAssertTrue(line.contains(" --plugin-dir " + ShellQuote.single(mod.path)), line)
        XCTAssertTrue(HookSettings.command(helper: helper, event: "Stop").hasPrefix(ShellQuote.single(helper) + " "))
        let written = try String(contentsOfFile: settings, encoding: .utf8)
        XCTAssertTrue(written.contains(#"Pat'\\''s app"#), "the settings file carries the quoted helper")
    }

    /// A session id that is not a UUID, or a model/effort outside their closed sets, is refused:
    /// nothing is spawned or added, and the result has no claude session id.
    func testCommissionRefusesValuesThatAreNotWhatTheyClaim() {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("refuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let host = FakeTerminalHost()
        let sessions = manager(host, support: support)
        let refused = [
            sessions.commission(callsign: "a", cwd: "/x", agentType: claude, sessionID: "abc; echo hi"),
            sessions.commission(callsign: "b", cwd: "/x", agentType: claude, sessionID: "../../x"),
            sessions.commission(callsign: "c", cwd: "/x", agentType: claude, model: "opus --verbose"),
            sessions.commission(callsign: "d", cwd: "/x", agentType: claude, effort: "high; echo hi"),
        ]
        XCTAssertTrue(refused.allSatisfy { $0.claudeSessionID == nil })
        XCTAssertTrue(host.spawned.isEmpty, "nothing launched")
        XCTAssertTrue(sessions.sessions.isEmpty, "nothing added")

        let ok = sessions.commission(callsign: "e", cwd: "/x", agentType: claude,
                                     sessionID: "6F9619FF-8B86-4011-B42D-00C04FC964FF", model: "haiku", effort: "low")
        XCTAssertEqual(ok.claudeSessionID, "6F9619FF-8B86-4011-B42D-00C04FC964FF")
        let line = host.spawned.first?.args.last ?? ""
        XCTAssertTrue(line.contains("--session-id 6F9619FF-8B86-4011-B42D-00C04FC964FF"), line)
        XCTAssertTrue(line.hasSuffix(" --model haiku --effort low"), line)
    }
}
