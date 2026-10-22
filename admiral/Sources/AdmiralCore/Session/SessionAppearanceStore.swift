import Foundation

/// A user's customization of a session's look, persisted per SESSION so each terminal
/// keeps its own name/color/icon — and a relaunch restores that exact session's look.
public struct SessionAppearance: Codable, Equatable, Sendable {
    public var name: String?
    public var colorHex: String?
    public var symbol: String?

    public init(name: String? = nil, colorHex: String? = nil, symbol: String? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.symbol = symbol
    }

    public var isEmpty: Bool { name == nil && colorHex == nil && symbol == nil }
}

/// UserDefaults-backed store of `SessionAppearance` keyed by the session's persistent id
/// (its `claudeSessionID`). Injected into `SessionManager`; tests pass a throwaway suite.
///
/// Keyed by session, NOT cwd: two terminals in the same folder are independent, and a
/// brand-new terminal (fresh id) never inherits a sibling's name/color/icon. A restored
/// session reuses its saved id, so its own look comes back.
public final class SessionAppearanceStore {
    private let defaults: UserDefaults
    // v2: was keyed by cwd, which made every session in a folder share one look. The old
    // cwd-keyed map is intentionally abandoned (a one-time reset of customizations).
    private let key = "admiral.sessionAppearances.v2"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func appearance(forSession sessionID: String) -> SessionAppearance {
        load()[sessionID] ?? SessionAppearance()
    }

    public func setAppearance(_ appearance: SessionAppearance, forSession sessionID: String) {
        var map = load()
        if appearance.isEmpty { map[sessionID] = nil } else { map[sessionID] = appearance }
        save(map)
    }

    /// Forget a session's saved look (on delete).
    public func remove(forSession sessionID: String) {
        var map = load()
        map[sessionID] = nil
        save(map)
    }

    private func load() -> [String: SessionAppearance] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: SessionAppearance].self, from: data)
        else { return [:] }
        return map
    }

    private func save(_ map: [String: SessionAppearance]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: key) }
    }
}
