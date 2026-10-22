import Foundation

/// UserDefaults-backed watchdog configuration (Settings → Watchdog edits it; the service
/// re-reads via a provider closure each tick, so edits apply live without a relaunch —
/// the same pattern as the launch-options provider).
public final class WatchdogConfigStore {
    private let defaults: UserDefaults
    private let key = "admiral.watchdog.config.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> WatchdogConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(WatchdogConfig.self, from: data)
        else { return .default }
        return config
    }

    public func save(_ config: WatchdogConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
