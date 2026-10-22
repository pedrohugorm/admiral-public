import Foundation

/// UserDefaults-backed store of `WatchdogState` keyed by the session's persistent id
/// (its `claudeSessionID`) — the same keying as `SessionAppearanceStore`, so an armed
/// watchdog survives app relaunch and `--resume`, and two tabs in one folder stay
/// independent. Single-writer: only the app process (WatchdogService) touches it.
public final class WatchdogStateStore {
    private let defaults: UserDefaults
    private let key = "admiral.watchdogStates.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func state(forSession sessionID: String) -> WatchdogState? {
        load()[sessionID]
    }

    /// `nil` removes the entry (session forgotten).
    public func set(_ state: WatchdogState?, forSession sessionID: String) {
        var map = load()
        map[sessionID] = state
        save(map)
    }

    private func load() -> [String: WatchdogState] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: WatchdogState].self, from: data)
        else { return [:] }
        return map
    }

    private func save(_ map: [String: WatchdogState]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }
}
