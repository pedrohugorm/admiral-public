import Foundation

/// How Admiral finds a GitHub token and the `gh` binary.
///
/// Admiral is Finder-launched, so it inherits neither the user's `PATH` nor their
/// `GITHUB_TOKEN`, and `gh` has **no stored credentials** to fall back on — without a token
/// `gh pr list` fails and returns nothing, so the sidebar's PR status silently goes blank.
///
/// Lives in `AdmiralCore` rather than `App` so it stays covered by `swift test`. (It was
/// originally lifted out of `GitHubService` so the `admiral-hook` helper could share it for
/// `one_pr_per_ticket`; that rule now lives in hookd, and only `GitHubService` calls this.)
public enum GitHubEnvironment {
    /// `gh`'s own precedence is `GH_TOKEN` then `GITHUB_TOKEN`; the login-shell fallback
    /// keeps `GitHubService`'s order.
    public static func token(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let token = nonEmpty(environment["GH_TOKEN"]) { return token }
        if let token = nonEmpty(environment["GITHUB_TOKEN"]) { return token }
        return loginEnvValue("GITHUB_TOKEN") ?? loginEnvValue("GH_TOKEN")
    }

    /// The user's `PATH`, which a Finder-launched app does not inherit.
    public static func loginPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        loginEnvValue("PATH") ?? environment["PATH"] ?? "/usr/bin:/bin"
    }

    public static func ghPath(searchPath: @autoclosure () -> String = loginPath()) -> String {
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        for directory in searchPath().split(separator: ":") {
            let candidate = "\(directory)/gh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "gh"
    }

    /// Reads a variable from an interactive login shell.
    ///
    /// The value is isolated between `<<` and `>>` because a login zsh also emits
    /// shell-integration escape sequences on stdout, which would otherwise corrupt it.
    ///
    /// The `-i` is load-bearing: a non-interactive `zsh -c` does not source `~/.zshrc` (and
    /// so never reaches the `~/.bashrc` that exports the token).
    public static func loginEnvValue(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "printf '<<%s>>' \"$\(name)\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard let open = text.range(of: "<<"),
              let close = text.range(of: ">>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return nonEmpty(String(text[open.upperBound..<close.lowerBound]))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
