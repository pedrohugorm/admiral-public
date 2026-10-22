import Foundation

/// UserDefaults-backed goals-nudge configuration (Settings → Watchdog's Goals card edits it; the service
/// re-reads via a provider closure each tick, so edits apply live without a relaunch — the
/// same pattern as `WatchdogConfigStore`).
public final class GoalsNudgeConfigStore {
    private let defaults: UserDefaults
    private let key = "admiral.goals.nudge.config.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> GoalsNudgeConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(GoalsNudgeConfig.self, from: data)
        else { return .default }
        return config
    }

    public func save(_ config: GoalsNudgeConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
