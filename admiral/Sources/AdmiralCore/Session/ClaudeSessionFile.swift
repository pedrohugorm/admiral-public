import Foundation

/// Decoded `~/.claude/sessions/<pid>.json` — maps a running `claude` pid to its
/// session id, cwd, and live status.
public struct ClaudeSessionFile: Decodable, Sendable {
    public let pid: Int?
    public let sessionId: String?
    public let cwd: String?
    public let status: String?
    public let updatedAt: Double?
    public let name: String?
    /// The session's messaging socket — how a hail or a rename reaches it.
    public let messagingSocketPath: String?

    /// Whether the socket is still there. A registry entry outlives its process, so the
    /// socket's existence — not the file's — is what makes a session addressable.
    public var isAddressable: Bool {
        guard let messagingSocketPath, !messagingSocketPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: messagingSocketPath)
    }

    public init(
        pid: Int?, sessionId: String?, cwd: String?, status: String?,
        updatedAt: Double?, name: String?, messagingSocketPath: String?
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
        self.name = name
        self.messagingSocketPath = messagingSocketPath
    }

    /// Read and decode the session file for a pid, if present.
    public static func read(pid: Int32, claudeHome: URL) -> ClaudeSessionFile? {
        let url = claudeHome.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    }

    /// The freshest file (by `updatedAt`) for a session id: a resumed or relaunched claude
    /// leaves the old pid's file behind, and its status is stale.
    public static func newest(sessionId: String, claudeHome: URL) -> ClaudeSessionFile? {
        all(claudeHome: claudeHome).filter { $0.sessionId == sessionId }
            .max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }
    }

    /// Decode every `sessions/<pid>.json` under claudeHome (ignoring unreadable ones), so a
    /// session can be matched by its stable `sessionId` rather than a pid that needs a fragile
    /// process-tree walk and doesn't survive resume.
    public static func all(claudeHome: URL) -> [ClaudeSessionFile] {
        let dir = claudeHome.appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            (try? Data(contentsOf: dir.appendingPathComponent(name)))
                .flatMap { try? decoder.decode(ClaudeSessionFile.self, from: $0) }
        }
    }
}
