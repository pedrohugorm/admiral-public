import Foundation

/// A session's PR watch memory on disk, one file per session under
/// `<base>/pr-watch/<sessionID>.json`.
///
/// A **file** rather than `UserDefaults` for the same reason as `GoalsStore`: it is the
/// re-trigger guard, and a guard that lives in memory announces everything again on the next
/// launch. Keyed by `claudeSessionID` so it survives an app relaunch *and* a `--resume`, and
/// so the bridge's `pr_status` tool reads exactly what the watcher wrote.
public final class PRWatchStore {
    private let base: URL

    public init(base: URL) { self.base = base }

    public func state(forSession sessionID: String) -> PRWatchState? {
        let url = AdmiralPaths.prWatchFile(base: base, session: sessionID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PRWatchState.self, from: data)
    }

    public func set(_ state: PRWatchState?, forSession sessionID: String) {
        let url = AdmiralPaths.prWatchFile(base: base, session: sessionID)
        guard let state, let data = try? JSONEncoder().encode(state) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
