import XCTest
import SQLite3
@testable import AdmiralCore

/// Launching a session on a CC Switch provider. The provider's env rides in the session's
/// own `--settings` file — the highest-precedence settings source claude has — so the tab
/// talks to that endpoint while every other tab, and `~/.claude/settings.json`, is untouched.
@MainActor
final class CCSwitchLaunchTests: XCTestCase {
    /// The catalog reads WHICHEVER database it is pointed at — the Settings → Sessions
    /// override is honored end-to-end, not only the default location. Machine-independent:
    /// everything asserted comes from the fixture, not ~/.cc-switch.
    func testLoadReadsTheDatabaseItIsGiven() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-ccswitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("custom.db").path
        try writeCatalogDatabase(at: path)

        let providers = CCSwitchCatalog.load(databasePath: path)
        XCTAssertEqual(providers.map(\.name), ["Elsewhere"], "the fixture's row, not the machine's")
        XCTAssertEqual(providers.first?.baseURL, "https://elsewhere.test/v1")
    }

    /// A minimal CC Switch database: one claude provider that redirects, one inert claude
    /// row (empty env — filtered), one bash row (wrong app_type — filtered).
    private func writeCatalogDatabase(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "ccswitch-fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not create \(path)"])
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE providers (id TEXT, name TEXT, settings_config TEXT, app_type TEXT);
            INSERT INTO providers VALUES ('p1', 'Elsewhere',
                '{"env":{"ANTHROPIC_BASE_URL":"https://elsewhere.test/v1"}}', 'claude');
            INSERT INTO providers VALUES ('inert', 'Inert', '{}', 'claude');
            INSERT INTO providers VALUES ('other-app', 'Other app', '{}', 'bash');
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ccswitch-fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "fixture SQL failed"])
        }
    }

    func testSessionSettingsCarryProviderEnvAlongsideHooks() {
        let json = HookSettings.json(
            helper: "/bin/helper",
            providerEnv: ["ANTHROPIC_BASE_URL": "https://api.fireworks.ai/inference"]
        )

        let env = json["env"] as? [String: String]
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"], "https://api.fireworks.ai/inference")
        XCTAssertNotNil(json["hooks"], "the provider env must not displace the hooks Admiral needs")
    }

    func testSessionSettingsOmitEnvWithoutAProvider() {
        XCTAssertNil(HookSettings.json(helper: "/bin/helper", providerEnv: nil)["env"],
                     "a stock session must not carry an env block at all")
    }

    func testCommissionWithProviderWritesItsEnvIntoThatSessionsSettings() throws {
        let support = temporaryDirectory()
        let manager = makeManager(supportDir: support)
        let provider = CCSwitchProvider(
            id: "kimi", name: "Kimi via Fireworks AI",
            env: ["ANTHROPIC_BASE_URL": "https://api.fireworks.ai/inference",
                  "ANTHROPIC_MODEL": "accounts/fireworks/models/kimi-k3[1M]"]
        )

        let session = manager.commission(callsign: "worker", cwd: "/tmp", provider: provider)

        let settings = try settingsJSON(support: support, token: session.token)
        let env = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://api.fireworks.ai/inference")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "accounts/fireworks/models/kimi-k3[1M]")
        XCTAssertEqual(session.providerName, "Kimi via Fireworks AI", "the tab must be able to say what it runs on")
    }

    func testCommissionWithoutProviderLeavesTheSessionOnStockAnthropic() throws {
        let support = temporaryDirectory()
        let manager = makeManager(supportDir: support)

        let session = manager.commission(callsign: "worker", cwd: "/tmp")

        let settings = try settingsJSON(support: support, token: session.token)
        XCTAssertNil(settings["env"])
        XCTAssertNil(session.providerName)
    }

    /// The token is an API credential: it must not be world-readable next to the hooks.
    func testProviderSettingsFileIsOwnerReadableOnly() throws {
        let support = temporaryDirectory()
        let manager = makeManager(supportDir: support)
        let provider = CCSwitchProvider(id: "k", name: "K", env: ["ANTHROPIC_AUTH_TOKEN": "fw-secret"])

        let session = manager.commission(callsign: "worker", cwd: "/tmp", provider: provider)

        let url = AdmiralPaths.settingsFile(base: support, token: session.token)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }

    // MARK: - The selection survives a relaunch

    func testLaunchOptionsRememberTheChosenProvider() {
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)"))
        let store = LaunchOptionsStore(defaults: defaults)
        var options = store.load()
        options.providerID = "kimi"

        store.save(options)

        XCTAssertEqual(store.load().providerID, "kimi")
    }

    /// Settings saved before this feature existed must still load — otherwise every
    /// existing user's launch options silently reset to the defaults.
    func testLaunchOptionsSavedBeforeProvidersStillLoad() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)"))
        let legacy = #"{"managed":true,"permissionMode":"plan","appendSystemPrompt":false,"extraFlags":"-v"}"#
        defaults.set(Data(legacy.utf8), forKey: "admiral.launchOptions.v1")

        let options = LaunchOptionsStore(defaults: defaults).load()

        XCTAssertEqual(options.permissionMode, .plan, "legacy settings must survive, not reset")
        XCTAssertNil(options.providerID)
    }

    func testRestoredSessionComesBackOnTheSameProvider() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)"))
        let store = OpenSessionsStore(defaults: defaults)

        store.upsert(OpenSessionRecord(cwd: "/tmp", sessionID: "sid-1", callsign: "worker", providerID: "kimi"))

        XCTAssertEqual(store.all().first?.providerID, "kimi")
    }

    func testSessionsRecordedBeforeProvidersStillRestore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)"))
        let legacy = #"[{"cwd":"/tmp","sessionID":"sid-1","callsign":"worker"}]"#
        defaults.set(Data(legacy.utf8), forKey: "admiral.openSessions.v1")

        let records = OpenSessionsStore(defaults: defaults).all()

        XCTAssertEqual(records.count, 1, "a session stored before providers must still restore")
        XCTAssertNil(records[0].providerID)
    }

    /// The whole point of routing this through a per-session file: a tab on a provider must
    /// not drag its sibling along. Fails the moment the env is hoisted anywhere shared — the
    /// manager's `environmentOverrides`, the process environment, the global settings.
    func testAProviderTabDoesNotPullTheNextTabOntoItsEndpoint() throws {
        let support = temporaryDirectory()
        let host = FakeTerminalHost()
        let manager = makeManager(supportDir: support, catalog: [Self.kimi], host: host)
        _ = manager.commission(callsign: "on-kimi", cwd: "/tmp", provider: Self.kimi)

        let plain = manager.commission(callsign: "on-anthropic", cwd: "/tmp")

        XCTAssertNil(settingsJSONOptional(support: support, token: plain.token)?["env"],
                     "the sibling's settings file must carry no provider env")
        XCTAssertNil(host.lastEnv["ANTHROPIC_BASE_URL"],
                     "nor may it reach the sibling through the spawned process environment")
        XCTAssertNil(plain.providerName)
    }

    // MARK: - The provider survives the relaunch paths

    func testReloadingATabKeepsItOnItsProvider() throws {
        let support = temporaryDirectory()
        let manager = makeManager(supportDir: support, catalog: [Self.kimi])
        let session = manager.commission(callsign: "worker", cwd: "/tmp", provider: Self.kimi)

        let reloaded = try XCTUnwrap(manager.reload(session.id))

        XCTAssertEqual(reloaded.providerID, "kimi", "a reloaded tab must not drop back to Anthropic")
        let env = try XCTUnwrap(settingsJSON(support: support, token: reloaded.token)["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://api.fireworks.ai/inference")
    }

    /// Relabelling rewrites the restore record — it must carry the provider along, or the
    /// tab comes back on Anthropic after the next relaunch.
    func testSettingATeamDoesNotEraseTheStoredProvider() throws {
        let support = temporaryDirectory()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)"))
        let store = OpenSessionsStore(defaults: defaults)
        let manager = makeManager(supportDir: support, catalog: [Self.kimi], openSessions: store)
        let session = manager.commission(callsign: "worker", cwd: "/tmp", provider: Self.kimi)

        manager.setTeam(session.id, team: "alpha")

        XCTAssertEqual(store.all().first?.providerID, "kimi")
    }

    // MARK: - Helpers

    private static let kimi = CCSwitchProvider(
        id: "kimi", name: "Kimi via Fireworks AI",
        env: ["ANTHROPIC_BASE_URL": "https://api.fireworks.ai/inference"]
    )

    /// Isolated stores throughout: a test must never write into the real Admiral's
    /// open-sessions list, appearances or touched-repo log.
    private func makeManager(
        supportDir: URL,
        catalog: [CCSwitchProvider] = [],
        openSessions: OpenSessionsStore? = nil,
        host: FakeTerminalHost? = nil
    ) -> SessionManager {
        SessionManager(
            host: host ?? FakeTerminalHost(),
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/zsh",
            defaultAgentType: .claudeZshRecipe(options: .default),
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: openSessions ?? OpenSessionsStore(defaults: tempDefaults()),
            supportDir: supportDir,
            hookHelper: "/bin/admiral-hook",
            touchedReposStore: TouchedReposStore(defaults: tempDefaults()),
            providerResolver: { id in catalog.first { $0.id == id } }
        )
    }

    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-support-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func settingsJSONOptional(support: URL, token: String) -> [String: Any]? {
        let url = AdmiralPaths.settingsFile(base: support, token: token)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func settingsJSON(support: URL, token: String) throws -> [String: Any] {
        let url = AdmiralPaths.settingsFile(base: support, token: token)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
