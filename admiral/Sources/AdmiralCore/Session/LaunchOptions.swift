import Foundation

/// `--permission-mode` values claude accepts. Raw values are the CLI spelling.
public enum PermissionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case `default`
    case acceptEdits
    case bypassPermissions
    case plan

    public var id: String { rawValue }
}

/// How Admiral composes the `claude` command line for a managed session
/// (Settings → Sessions).
///
/// With `managed` on (the default), Admiral owns the launch flags: the recipe runs
/// `command claude` — which skips personal shell functions and aliases — with
/// `permissionMode`, the optional `APPEND_SYSTEM_PROMPT.md` append, and `extraFlags`.
/// Every machine gets the same session behavior with zero shell setup.
///
/// With `managed` off, the recipe is the pre-settings one: plain `claude`, so the user's
/// shell configuration decides (a personal `claude` function/alias applies, and without
/// one claude runs with its standard permission prompts).
public struct LaunchOptions: Codable, Equatable, Sendable {
    public var managed: Bool
    public var permissionMode: PermissionMode
    /// When managed: if the session's cwd contains `APPEND_SYSTEM_PROMPT.md`, append its
    /// content via `--append-system-prompt`. The file is read by zsh at launch time in the
    /// session's cwd, so the content needs no Swift-side shell quoting.
    public var appendSystemPrompt: Bool
    /// When managed: extra flags appended verbatim to the claude invocation.
    public var extraFlags: String
    /// The CC Switch provider new sessions use WHEN the New-session form's custom-model box
    /// is ticked (`CCSwitchProvider.id`). Selecting one here launches nothing and changes no
    /// running session; nil means none is configured and the box has nothing to offer.
    public var providerID: String?

    /// Where the CC Switch provider list is read from (Settings → Sessions → Choose…): a
    /// security-scoped bookmark to CC Switch's folder or to a database file, read through
    /// `CCSwitchCatalog.load(bookmark:)`. Nil means CC Switch's standard location. Optional so
    /// options persisted before this field existed still decode.
    public var ccSwitchBookmark: Data?

    /// Launch tabs with `crossSessionInbound: "accept"`, so Admiral can reach them over
    /// claude's messaging socket — PR WATCH and the watchdog then arrive as messages instead
    /// of being typed into the input box. Without it a `bypassPermissions` tab holds every
    /// socket message for approval. Also lets the user's other claude sessions message the
    /// tab without review. Optional so options saved before it existed decode; nil = on.
    public var acceptPeerMessages: Bool?
    public var acceptsPeerMessages: Bool { acceptPeerMessages ?? true }

    public init(
        managed: Bool = true,
        permissionMode: PermissionMode = .bypassPermissions,
        appendSystemPrompt: Bool = true,
        extraFlags: String = "",
        providerID: String? = nil,
        ccSwitchBookmark: Data? = nil
    ) {
        self.managed = managed
        self.permissionMode = permissionMode
        self.appendSystemPrompt = appendSystemPrompt
        self.extraFlags = extraFlags
        self.providerID = providerID
        self.ccSwitchBookmark = ccSwitchBookmark
    }

    public static let `default` = LaunchOptions()

    /// The command string for the `zsh -ilc` recipe, carrying the session-id and name
    /// placeholders `SessionManager.commission` substitutes. The claude invocation is the
    /// LAST statement so commission's appended `--settings`/`--mcp-config` land on it.
    public func claudeCommandLine() -> String {
        let idFlags = "--session-id \(SessionManager.sessionIDPlaceholder)"
            + " --name \(SessionManager.sessionNamePlaceholder)"
        guard managed else { return "claude \(idFlags)" }

        var line = ""
        var claude = "command claude --permission-mode \(permissionMode.rawValue)"
        if appendSystemPrompt {
            line += #"extra=(); [[ -f ./APPEND_SYSTEM_PROMPT.md ]] && "#
                + #"extra=(--append-system-prompt "$(cat ./APPEND_SYSTEM_PROMPT.md)"); "#
            claude += #" "${extra[@]}""#
        }
        line += claude + " " + idFlags
        let extra = extraFlags.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { line += " " + extra }
        return line
    }
}

/// UserDefaults-backed persistence for `LaunchOptions`. Injected with the app's
/// profile-aware suite so a dev instance's launch settings never touch the default
/// instance's. A missing or corrupt value yields `.default` rather than throwing.
public final class LaunchOptionsStore {
    private let defaults: UserDefaults
    private let key = "admiral.launchOptions.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LaunchOptions {
        guard let data = defaults.data(forKey: key),
              let options = try? JSONDecoder().decode(LaunchOptions.self, from: data)
        else { return .default }
        return options
    }

    public func save(_ options: LaunchOptions) {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: key) }
    }
}

public extension AgentType {
    /// The app's real launch recipe: claude through an interactive login zsh (which sources
    /// the user's PATH/env — a Finder-launched app inherits neither), running the command
    /// line `options` composes. Lives here, not in the app, so `swift test` covers it.
    static func claudeZshRecipe(options: LaunchOptions) -> AgentType {
        AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", options.claudeCommandLine()],
            symbolName: "sparkles"
        )
    }
}
