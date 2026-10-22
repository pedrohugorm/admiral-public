import Foundation
import Combine

/// A session's goals on disk, one file per session under `<base>/goals/<sessionID>.json`.
///
/// Keyed by the persistent `claudeSessionID` — the same keying as `SessionAppearanceStore`
/// and `WatchdogStateStore` — so goals survive app relaunch and `--resume`.
///
/// A **file**, not `UserDefaults`, because two processes read it: the app (the bridge tool,
/// the nudge, the panel) and the `admiral-hook` helper, which reminds the session of its open
/// goals on every prompt. The helper has no access to the app's defaults, and a mirrored copy
/// would be one more thing to keep in sync.
public final class GoalsStore: ObservableObject {
    private let base: URL

    /// Fires after every write. The Footprint panel reads goals straight from the file, so this
    /// is its only cue that they changed — from a bridge tool, the nudge, or the panel's own menu —
    /// even while the session sits idle and nothing else redraws.
    public let objectWillChange = ObservableObjectPublisher()

    public init(base: URL) { self.base = base }

    public func goals(forSession sessionID: String) -> SessionGoals? {
        let url = AdmiralPaths.goalsFile(base: base, session: sessionID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionGoals.self, from: data)
    }

    /// `nil` — or an empty list — removes the file, so "no goals" has one representation
    /// and both readers have one thing to check.
    public func set(_ goals: SessionGoals?, forSession sessionID: String) {
        // After the write, so whatever redraws on the signal reads the new file.
        defer { objectWillChange.send() }
        let url = AdmiralPaths.goalsFile(base: base, session: sessionID)
        guard let goals, !goals.isEmpty, let data = try? JSONEncoder().encode(goals) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Read-modify-write of one session's goals; no-op when it has none.
    public func update(forSession sessionID: String, _ body: (inout SessionGoals) -> Void) {
        guard var goals = goals(forSession: sessionID) else { return }
        body(&goals)
        set(goals, forSession: sessionID)
    }
}
