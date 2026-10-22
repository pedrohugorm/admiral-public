import XCTest
import SQLite3
@testable import AdmiralCore

/// The CC Switch catalog: Admiral reads that app's SQLite config read-only to offer its
/// Claude provider configs as a per-session launch target. Nothing here ever writes to
/// CC Switch's database.
final class CCSwitchProviderTests: XCTestCase {
    // MARK: - Parsing

    func testParsesProviderEnvFromSettingsConfig() throws {
        let rows = [
            CCSwitchRow(id: "abc", name: "Kimi via Fireworks AI", settingsConfig: """
                {"env":{"ANTHROPIC_BASE_URL":"https://api.fireworks.ai/inference",\
                "ANTHROPIC_AUTH_TOKEN":"fw-secret","ANTHROPIC_MODEL":"kimi-k3[1M]"}}
                """)
        ]

        let providers = CCSwitchCatalog.providers(from: rows)

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].id, "abc")
        XCTAssertEqual(providers[0].name, "Kimi via Fireworks AI")
        XCTAssertEqual(providers[0].env["ANTHROPIC_BASE_URL"], "https://api.fireworks.ai/inference")
        XCTAssertEqual(providers[0].env["ANTHROPIC_MODEL"], "kimi-k3[1M]")
    }

    /// `default` and `Claude Official` carry `{}` — selecting one must mean "stock
    /// Anthropic", which is the un-ticked checkbox, not a provider row that injects nothing.
    func testSkipsProvidersThatOverrideNothing() {
        let rows = [
            CCSwitchRow(id: "default", name: "default", settingsConfig: "{}"),
            CCSwitchRow(id: "official", name: "Claude Official", settingsConfig: #"{"env":{}}"#),
            CCSwitchRow(id: "broken", name: "Corrupt", settingsConfig: "not json"),
            CCSwitchRow(id: "glm", name: "GLM", settingsConfig: #"{"env":{"ANTHROPIC_BASE_URL":"https://x"}}"#)
        ]

        XCTAssertEqual(CCSwitchCatalog.providers(from: rows).map(\.id), ["glm"])
    }

    // MARK: - Reading CC Switch's database

    func testLoadsProvidersFromCCSwitchDatabase() throws {
        let db = try makeFixtureDatabase(rows: [
            ("kimi", "claude", "Kimi", #"{"env":{"ANTHROPIC_BASE_URL":"https://fireworks"}}"#),
            ("codex", "codex", "OpenAI", #"{"env":{"OPENAI_BASE_URL":"https://openai"}}"#),
            ("default", "claude", "default", "{}")
        ])
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }

        let providers = CCSwitchCatalog.load(databasePath: db.path)

        XCTAssertEqual(providers.map(\.name), ["Kimi"], "claude configs only, and only ones that override something")
    }

    func testMissingDatabaseYieldsNoProvidersInsteadOfFailing() {
        XCTAssertTrue(CCSwitchCatalog.load(databasePath: "/nonexistent/cc-switch.db").isEmpty)
    }

    // MARK: - A picked location (security-scoped bookmark, Settings → Sessions → Choose…)

    func testReadsTheDatabaseInAPickedFolder() throws {
        let db = try makeFixtureDatabase(rows: [
            ("kimi", "claude", "Kimi", #"{"env":{"ANTHROPIC_BASE_URL":"https://fireworks"}}"#)
        ])
        let folder = db.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = try CCSwitchCatalog.bookmark(for: folder)

        XCTAssertEqual(CCSwitchCatalog.load(bookmark: bookmark).map(\.name), ["Kimi"])
        XCTAssertEqual(CCSwitchCatalog.location(from: bookmark)?.resolvingSymlinksInPath().path,
                       folder.resolvingSymlinksInPath().path)
    }

    func testReadsAPickedDatabaseFile() throws {
        let db = try makeFixtureDatabase(rows: [
            ("glm", "claude", "GLM", #"{"env":{"ANTHROPIC_BASE_URL":"https://x"}}"#)
        ])
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }

        XCTAssertEqual(CCSwitchCatalog.load(bookmark: try CCSwitchCatalog.bookmark(for: db)).map(\.name), ["GLM"])
    }

    func testAPickedFolderThatIsGoneYieldsNoProviders() throws {
        let db = try makeFixtureDatabase(rows: [
            ("glm", "claude", "GLM", #"{"env":{"ANTHROPIC_BASE_URL":"https://x"}}"#)
        ])
        let bookmark = try CCSwitchCatalog.bookmark(for: db.deletingLastPathComponent())
        try FileManager.default.removeItem(at: db.deletingLastPathComponent())

        XCTAssertTrue(CCSwitchCatalog.load(bookmark: bookmark).isEmpty)
    }

    // MARK: - Fixture

    private func makeFixtureDatabase(rows: [(String, String, String, String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccswitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cc-switch.db")

        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw XCTSkip("sqlite3 unavailable")
        }
        defer { sqlite3_close(handle) }
        let create = """
            CREATE TABLE providers (id TEXT NOT NULL, app_type TEXT NOT NULL, name TEXT NOT NULL,
            settings_config TEXT NOT NULL, PRIMARY KEY (id, app_type));
            """
        XCTAssertEqual(sqlite3_exec(handle, create, nil, nil, nil), SQLITE_OK)
        for (id, app, name, config) in rows {
            let escaped = config.replacingOccurrences(of: "'", with: "''")
            let insert = "INSERT INTO providers VALUES ('\(id)','\(app)','\(name)','\(escaped)');"
            XCTAssertEqual(sqlite3_exec(handle, insert, nil, nil, nil), SQLITE_OK)
        }
        return url
    }
}
