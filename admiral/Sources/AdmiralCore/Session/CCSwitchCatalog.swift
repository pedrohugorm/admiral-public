import Foundation
import SQLite3

/// One Claude provider config as CC Switch stores it: a name and the environment that
/// points claude at somewhere other than Anthropic (`ANTHROPIC_BASE_URL`,
/// `ANTHROPIC_AUTH_TOKEN`, and the model names for each slot).
///
/// Admiral never authors these — CC Switch owns the values, and a second editor here is
/// how you end up debugging the wrong copy. They are read, offered, and injected verbatim.
public struct CCSwitchProvider: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let env: [String: String]

    public init(id: String, name: String, env: [String: String]) {
        self.id = id
        self.name = name
        self.env = env
    }

    /// Where a session using this provider will send its requests, for the UI to show
    /// before you launch. Nil for a config that sets no base URL.
    public var baseURL: String? { env["ANTHROPIC_BASE_URL"] }
}

/// A raw `providers` row, before its JSON is understood. Separate from the SQLite read so
/// the parsing rules are testable without a database.
public struct CCSwitchRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let settingsConfig: String

    public init(id: String, name: String, settingsConfig: String) {
        self.id = id
        self.name = name
        self.settingsConfig = settingsConfig
    }
}

/// Reads CC Switch's provider list. Strictly read-only: Admiral opens the database with
/// `SQLITE_OPEN_READONLY` and, if the running app holds it (WAL), reads a throwaway copy
/// instead. Nothing here writes to CC Switch, ever.
public enum CCSwitchCatalog {
    /// The provider a tab should launch on, by id or exact name (any case); nil for an empty
    /// key (stock Anthropic). An unknown key names the ones that exist.
    public static func resolve(_ key: String?, from providers: () -> [CCSwitchProvider] = { load() })
        -> Result<CCSwitchProvider?, ScheduleLaunchError> {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return .success(nil) }
        let all = providers()
        guard let match = all.first(where: {
            $0.id == key || $0.name.compare(key, options: .caseInsensitive) == .orderedSame
        }) else {
            let known = all.map(\.name).sorted().joined(separator: ", ")
            return .failure(ScheduleLaunchError(message: "unknown provider '\(key)' — known: \(known.isEmpty ? "(none)" : known)"))
        }
        return .success(match)
    }

    /// CC Switch's standard location. Sandboxed, the home directory is the app's container, so
    /// this finds nothing there and the real folder is reached only through a picked location
    /// (`load(bookmark:)`).
    public static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db").path
    }

    /// The providers wherever Settings → Sessions says CC Switch lives — the one entry point
    /// every catalog reader goes through, so a change there moves all of them at once.
    /// `bookmark` is a security-scoped bookmark to the folder (or database file) the user picked;
    /// nil means the standard location. A picked location, never a typed path, because it is the
    /// only grant that lets a sandboxed app read outside its container. Access is held only for
    /// the read.
    public static func load(bookmark: Data?) -> [CCSwitchProvider] {
        guard let bookmark else { return load() }
        guard let location = location(from: bookmark) else { return [] }
        let scoped = location.startAccessingSecurityScopedResource()
        defer { if scoped { location.stopAccessingSecurityScopedResource() } }
        return load(databasePath: databasePath(at: location))
    }

    /// A read-only, security-scoped bookmark to a folder or database file the user picked.
    public static func bookmark(for location: URL) throws -> Data {
        try location.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                  includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where a bookmark points; nil once it no longer resolves (the folder was deleted).
    public static func location(from bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// `cc-switch.db` inside a picked folder; a picked file is the database itself. Picking the
    /// folder is what lets the `-wal`/`-shm` siblings be read too.
    public static func databasePath(at location: URL) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return location.path }
        return location.appendingPathComponent("cc-switch.db").path
    }

    /// Keeps only configs that actually redirect claude. CC Switch's `default` and
    /// `Claude Official` rows carry an empty config — "stock Anthropic" is the un-ticked
    /// checkbox, not a provider that injects nothing.
    public static func providers(from rows: [CCSwitchRow]) -> [CCSwitchProvider] {
        rows.compactMap { row in
            guard let data = row.settingsConfig.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let env = object["env"] as? [String: String],
                  !env.isEmpty
            else { return nil }
            return CCSwitchProvider(id: row.id, name: row.name, env: env)
        }
    }

    /// The claude providers in the database at `databasePath`, in CC Switch's own order.
    /// A missing, locked or unreadable database yields an empty list — the feature simply
    /// offers nothing rather than failing a launch.
    public static func load(databasePath: String = defaultDatabasePath) -> [CCSwitchProvider] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        if let rows = readRows(at: databasePath) { return providers(from: rows) }
        guard let copy = temporaryCopy(of: databasePath) else { return [] }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        return providers(from: readRows(at: copy.path) ?? [])
    }

    // MARK: - SQLite

    /// Nil means the database could not be read at all (locked, or not a database), which
    /// is the caller's signal to retry against a copy.
    private static func readRows(at path: String) -> [CCSwitchRow]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, name, settings_config FROM providers WHERE app_type = 'claude'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var rows: [CCSwitchRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = column(statement, 0), let name = column(statement, 1),
                      let config = column(statement, 2) else { continue }
                rows.append(CCSwitchRow(id: id, name: name, settingsConfig: config))
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    /// CC Switch runs while Admiral does, so its database is usually in WAL mode with the
    /// journal held open. The `-wal` and `-shm` siblings come along so the copy shows the
    /// same committed state as the original.
    private static func temporaryCopy(of path: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("admiral-ccswitch-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let destination = dir.appendingPathComponent("cc-switch.db")
        do {
            try fm.copyItem(atPath: path, toPath: destination.path)
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: destination.path + suffix)
        }
        return destination
    }
}
