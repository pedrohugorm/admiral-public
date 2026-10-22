import XCTest
@testable import AdmiralCore

final class LaunchOptionsTests: XCTestCase {
    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
    }

    // MARK: - Command-line composition (exact strings — this IS the launch contract)

    func testDefaultIsManagedBypassWithAppend() {
        XCTAssertEqual(
            LaunchOptions.default.claudeCommandLine(),
            #"extra=(); [[ -f ./APPEND_SYSTEM_PROMPT.md ]] && "#
                + #"extra=(--append-system-prompt "$(cat ./APPEND_SYSTEM_PROMPT.md)"); "#
                + #"command claude --permission-mode bypassPermissions "${extra[@]}" "#
                + #"--session-id {{ADMIRAL_SESSION_ID}} --name {{ADMIRAL_SESSION_NAME}}"#
        )
    }

    func testUnmanagedIsTheLegacyRecipeByteForByte() {
        // Master toggle OFF = the pre-settings recipe: plain `claude`, so the user's shell
        // function/alias (or claude's standard prompts) decide. Must stay byte-identical.
        var options = LaunchOptions()
        options.managed = false
        XCTAssertEqual(
            options.claudeCommandLine(),
            "claude --session-id {{ADMIRAL_SESSION_ID}} --name {{ADMIRAL_SESSION_NAME}}"
        )
    }

    func testAppendDisabledDropsThePreambleAndArray() {
        var options = LaunchOptions()
        options.appendSystemPrompt = false
        XCTAssertEqual(
            options.claudeCommandLine(),
            "command claude --permission-mode bypassPermissions "
                + "--session-id {{ADMIRAL_SESSION_ID}} --name {{ADMIRAL_SESSION_NAME}}"
        )
    }

    func testPermissionModeIsSpelledLikeTheCLI() {
        for (mode, spelling) in [
            (PermissionMode.default, "default"),
            (.acceptEdits, "acceptEdits"),
            (.bypassPermissions, "bypassPermissions"),
            (.plan, "plan"),
        ] as [(PermissionMode, String)] {
            var options = LaunchOptions()
            options.permissionMode = mode
            XCTAssertTrue(
                options.claudeCommandLine().contains("--permission-mode \(spelling) "),
                "\(mode) must render as --permission-mode \(spelling)"
            )
        }
    }

    func testExtraFlagsAppendTrimmedAtTheEnd() {
        var options = LaunchOptions()
        options.extraFlags = "  --model opus  "
        XCTAssertTrue(options.claudeCommandLine().hasSuffix(
            "--name {{ADMIRAL_SESSION_NAME}} --model opus"))

        options.extraFlags = "   "
        XCTAssertTrue(options.claudeCommandLine().hasSuffix("--name {{ADMIRAL_SESSION_NAME}}"),
                      "whitespace-only extra flags must append nothing")
    }

    func testExtraFlagsIgnoredWhenUnmanaged() {
        var options = LaunchOptions()
        options.managed = false
        options.extraFlags = "--model opus"
        XCTAssertEqual(
            options.claudeCommandLine(),
            "claude --session-id {{ADMIRAL_SESSION_ID}} --name {{ADMIRAL_SESSION_NAME}}"
        )
    }

    func testRecipeCarriesBothPlaceholdersAndEndsWithClaude() {
        // commission appends `--settings`/`--mcp-config` to the LAST arg, so the claude
        // invocation must be the final statement of the managed script.
        let line = LaunchOptions.default.claudeCommandLine()
        XCTAssertTrue(line.contains("--session-id {{ADMIRAL_SESSION_ID}}"))
        XCTAssertTrue(line.contains("--name {{ADMIRAL_SESSION_NAME}}"))
        XCTAssertFalse(line.hasSuffix(";"), "claude must be the last statement")
    }

    func testZshRecipeAgentTypeWrapsTheCommandLine() {
        let type = AgentType.claudeZshRecipe(options: .default)
        XCTAssertEqual(type.id, "claude_code")
        XCTAssertEqual(type.executableName, "zsh")
        XCTAssertEqual(type.defaultArgs, ["-ilc", LaunchOptions.default.claudeCommandLine()])
    }

    // MARK: - Store

    func testStoreRoundTripsAndDefaultsWhenEmptyOrCorrupt() {
        let defaults = tempDefaults()
        let store = LaunchOptionsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default, "empty store yields the default options")

        var options = LaunchOptions()
        options.managed = false
        options.permissionMode = .acceptEdits
        options.appendSystemPrompt = false
        options.extraFlags = "--model opus"
        options.ccSwitchBookmark = Data([0x62, 0x6f, 0x6f, 0x6b])
        store.save(options)
        XCTAssertEqual(store.load(), options)

        defaults.set(Data("not json".utf8), forKey: "admiral.launchOptions.v1")
        XCTAssertEqual(store.load(), .default, "corrupt data degrades to the default")
    }

    // MARK: - CC Switch location

    /// Options persisted before the picked location existed — including ones carrying the old
    /// typed-path `ccSwitchDatabaseOverride` — must decode, not fall back to `.default`, which
    /// would silently reset every other Settings → Sessions choice.
    func testLegacyOptionsDecodeWithoutAPickedLocation() {
        for legacy in [
            #"{"managed":false,"permissionMode":"plan","appendSystemPrompt":false,"extraFlags":"--x"}"#,
            #"{"managed":false,"permissionMode":"plan","appendSystemPrompt":false,"extraFlags":"--x","ccSwitchDatabaseOverride":"/elsewhere/cc-switch.db"}"#,
        ] {
            let defaults = tempDefaults()
            defaults.set(Data(legacy.utf8), forKey: "admiral.launchOptions.v1")

            let options = LaunchOptionsStore(defaults: defaults).load()
            XCTAssertFalse(options.managed, "the legacy JSON must decode, not reset to default")
            XCTAssertNil(options.ccSwitchBookmark, "no picked location: CC Switch's standard one")
        }
    }
}

@MainActor
final class LaunchOptionsCommissionTests: XCTestCase {
    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
    }

    private func manager(host: FakeTerminalHost, provider: @escaping () -> AgentType,
                         hookHelper: String? = nil, supportDir: URL? = nil) -> SessionManager {
        SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/bin/zsh",
            defaultAgentTypeProvider: provider,
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: OpenSessionsStore(defaults: tempDefaults()),
            supportDir: supportDir ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("support-\(UUID().uuidString)"),
            hookHelper: hookHelper,
            touchedReposStore: TouchedReposStore(defaults: tempDefaults())
        )
    }

    func testProviderWinsOverDefaultAgentTypeAndIsReadFreshEachCommission() throws {
        let host = FakeTerminalHost()
        var options = LaunchOptions()
        let manager = manager(host: host, provider: { .claudeZshRecipe(options: options) })

        _ = manager.commission(callsign: "a", cwd: "/tmp")
        let first = try XCTUnwrap(host.spawned.first?.args.last)
        XCTAssertTrue(first.hasPrefix("extra=();"), "managed recipe spawns: \(first)")
        XCTAssertTrue(first.contains("command claude --permission-mode bypassPermissions"))

        options.managed = false  // Settings → Sessions edit between commissions
        _ = manager.commission(callsign: "b", cwd: "/tmp")
        let second = try XCTUnwrap(host.spawned.last?.args.last)
        XCTAssertTrue(second.hasPrefix("claude --session-id"),
                      "provider must be re-read at the next commission: \(second)")
    }

    func testManagedRecipeStillGetsPlaceholderSubstitutionAndSettingsInjection() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: support) }
        let host = FakeTerminalHost()
        let manager = manager(host: host, provider: { .claudeZshRecipe(options: .default) },
                              hookHelper: "/X/admiral-hook", supportDir: support)

        let session = manager.commission(callsign: "x", cwd: "/tmp")

        let last = try XCTUnwrap(host.spawned.first?.args.last)
        let sid = try XCTUnwrap(session.claudeSessionID)
        XCTAssertTrue(last.contains("--session-id \(sid)"), "placeholder substituted: \(last)")
        XCTAssertFalse(last.contains("{{ADMIRAL_SESSION_ID}}"))
        XCTAssertFalse(last.contains("{{ADMIRAL_SESSION_NAME}}"))
        XCTAssertTrue(last.contains("--settings '"),
                      "hook injection appends to the claude statement: \(last)")
    }
}
