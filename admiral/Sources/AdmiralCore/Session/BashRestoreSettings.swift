import Foundation

/// Settings → Sessions → bash TUI reopen. On Admiral quit we snapshot each bash tab's
/// process tree; on relaunch we re-run a command ONLY when its executable basename is on
/// this allowlist (never an arbitrary argv from `ps`).
public struct BashRestoreSettings: Codable, Equatable, Sendable {
    /// Master switch. Off ⇒ bash tabs restore as a blank zsh even if a TUI was running.
    public var enabled: Bool
    /// Executable basenames (e.g. `k9s`, `htop`). Compared case-insensitively to `ps`
    /// argv0's last path component. Args are never restored — only the bare tool name.
    public var allowlist: [String]

    public init(enabled: Bool = true, allowlist: [String] = Self.defaultAllowlist) {
        self.enabled = enabled
        self.allowlist = Self.normalize(allowlist)
    }

    public static let `default` = BashRestoreSettings()

    public static let defaultAllowlist: [String] = [
        "k9s", "htop", "btop", "lazygit", "vim", "nvim", "less", "man", "top",
    ]

    /// Lowercased, trimmed, non-empty, unique, sorted — the shape Settings edits and
    /// ProcessTree matching both use.
    public var allowlistSet: Set<String> { Set(Self.normalize(allowlist)) }

    public static func normalize(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in names {
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !n.isEmpty, !n.contains("/"), !n.contains(" "), seen.insert(n).inserted else { continue }
            out.append(n)
        }
        return out.sorted()
    }
}

/// Profile-aware UserDefaults store (same suite pattern as `LaunchOptionsStore`).
public final class BashRestoreSettingsStore {
    private let defaults: UserDefaults
    private let key = "admiral.bashRestore.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> BashRestoreSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(BashRestoreSettings.self, from: data)
        else { return .default }
        return BashRestoreSettings(enabled: value.enabled, allowlist: value.allowlist)
    }

    public func save(_ settings: BashRestoreSettings) {
        let normalized = BashRestoreSettings(enabled: settings.enabled, allowlist: settings.allowlist)
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: key)
            defaults.synchronize()
        }
    }
}
