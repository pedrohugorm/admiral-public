import Foundation

/// Builds the per-session `--mcp-config` JSON that registers Admiral's OWN bridge MCP server
/// (the bundled `admiral-bridge-mcp` relay) as `bridge`, so an Admiral-hosted claude reaches
/// this instance's bridge with no dependency on the external iterm2-bridge package. The relay
/// reads `ADMIRAL_SESSION` / `ADMIRAL_SOCKET` from the environment Admiral already injects, so
/// the config needs only the command. Injected non-strict, so the user's other MCP servers
/// (brain, etc.) still load alongside it.
public enum BridgeMCPConfig {
    public static func json(command: String) -> [String: Any] {
        ["mcpServers": ["bridge": ["command": command]]]
    }

    /// Writes the MCP config to `url`. Returns true only if the file was actually written — so
    /// the caller can DECLINE to inject `--mcp-config` on failure rather than point claude at a
    /// missing file (which would refuse to launch). Best-effort: a write failure degrades to
    /// "no bridge," never a broken session.
    @discardableResult
    public static func write(command: String, to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json(command: command),
            options: .withoutEscapingSlashes
        ) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch { return false }
        return true
    }
}
