import Foundation

/// UserDefaults-backed store of a session's touched-repo footprint, keyed by the session's
/// persistent id (its `claudeSessionID`) — the same mechanism as `OpenSessionsStore` /
/// `SessionAppearanceStore`. So a resumed session restores the repos it had written to,
/// instead of starting empty. PR status is NOT persisted (it's re-fetched live), only the
/// repo set + branch + write count + inside/outside-root flag.
public final class TouchedReposStore {
    private let defaults: UserDefaults
    private let key = "admiral.touchedRepos.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One persisted repo — `TouchedRepo` minus the live `prs` (which are re-fetched). Decodes
    /// the legacy single `branch` key too, so footprints saved before the multi-branch change
    /// restore instead of being dropped.
    private struct Persisted: Codable {
        let root: String
        let branches: [String]
        let filesWritten: Int
        let insideSessionRoot: Bool

        init(root: String, branches: [String], filesWritten: Int, insideSessionRoot: Bool) {
            self.root = root; self.branches = branches
            self.filesWritten = filesWritten; self.insideSessionRoot = insideSessionRoot
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            root = try c.decode(String.self, forKey: .root)
            filesWritten = try c.decode(Int.self, forKey: .filesWritten)
            insideSessionRoot = try c.decode(Bool.self, forKey: .insideSessionRoot)
            if let many = try c.decodeIfPresent([String].self, forKey: .branches) {
                branches = many
            } else {
                branches = (try c.decodeIfPresent(String.self, forKey: .branch)).map { [$0] } ?? []
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(root, forKey: .root)
            try c.encode(branches, forKey: .branches)
            try c.encode(filesWritten, forKey: .filesWritten)
            try c.encode(insideSessionRoot, forKey: .insideSessionRoot)
        }

        private enum CodingKeys: String, CodingKey { case root, branches, branch, filesWritten, insideSessionRoot }
    }

    /// The saved footprint for a session (empty if none / brand-new). `prs` comes back empty.
    public func repos(forSession sessionID: String) -> [TouchedRepo] {
        (load()[sessionID] ?? []).map {
            TouchedRepo(root: $0.root, branches: $0.branches,
                        filesWritten: $0.filesWritten, insideSessionRoot: $0.insideSessionRoot)
        }
    }

    /// Replace the saved footprint for a session (drops `prs` before persisting). An empty
    /// list clears the entry.
    public func setRepos(_ repos: [TouchedRepo], forSession sessionID: String) {
        var map = load()
        if repos.isEmpty {
            map[sessionID] = nil
        } else {
            map[sessionID] = repos.map {
                Persisted(root: $0.root, branches: $0.branches,
                          filesWritten: $0.filesWritten, insideSessionRoot: $0.insideSessionRoot)
            }
        }
        save(map)
    }

    /// Forget a session's footprint (on delete).
    public func remove(forSession sessionID: String) {
        var map = load()
        map[sessionID] = nil
        save(map)
    }

    private func load() -> [String: [Persisted]] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: [Persisted]].self, from: data)
        else { return [:] }
        return map
    }

    private func save(_ map: [String: [Persisted]]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: key) }
    }
}
