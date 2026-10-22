import Foundation

/// Resolves a session's transcript JSONL path from its pid, mirroring how the Go
/// TUI does it: pid → session file → `projects/<enc-cwd>/<sessionId>.jsonl`, with
/// glob and newest-file fallbacks.
public enum TranscriptLocator {
    /// Encode a cwd the way Claude names its project dir: `/ . _` → `-`.
    public static func encodeProjectDir(_ cwd: String) -> String {
        var out = ""
        out.reserveCapacity(cwd.count)
        for ch in cwd {
            out.append(ch == "/" || ch == "." || ch == "_" ? "-" : ch)
        }
        return out
    }

    /// Best-effort transcript path for a session id + cwd under a claude home.
    public static func resolve(sessionID: String, cwd: String, claudeHome: URL) -> String? {
        let fm = FileManager.default
        let projects = claudeHome.appendingPathComponent("projects")

        let encoded = projects.appendingPathComponent(encodeProjectDir(cwd))
        let primary = encoded.appendingPathComponent("\(sessionID).jsonl")
        if fm.fileExists(atPath: primary.path) { return primary.path }

        if let match = globProjects(named: "\(sessionID).jsonl", under: projects) {
            return match
        }
        return newestJSONL(in: encoded)
    }

    /// Resolve via the pid's session file, then ALWAYS fall through to the newest
    /// .jsonl in the cwd's project dir — a verbatim port of the Go `ResolvePath`.
    /// claude does not always write `sessions/<pid>.json` (e.g. before the first turn),
    /// so the cwd fallback MUST run even when the session file is absent.
    public static func resolve(pid: Int32, fallbackCwd: String, claudeHome: URL) -> (path: String?, file: ClaudeSessionFile?) {
        var file: ClaudeSessionFile?
        if pid > 0,
           let f = ClaudeSessionFile.read(pid: pid, claudeHome: claudeHome),
           let sessionID = f.sessionId {
            file = f
            if let path = resolve(sessionID: sessionID, cwd: f.cwd ?? fallbackCwd, claudeHome: claudeHome) {
                return (path, file)
            }
        }
        // Fallback regardless of session file: newest .jsonl in the encoded cwd dir.
        if !fallbackCwd.isEmpty {
            let dir = claudeHome.appendingPathComponent("projects")
                .appendingPathComponent(encodeProjectDir(fallbackCwd))
            if let path = newestJSONL(in: dir) {
                return (path, file)
            }
        }
        return (nil, file)
    }

    /// Resolve the transcript belonging to *one specific* Admiral-spawned session,
    /// isolated from other sessions sharing the same workspace dir:
    ///   1. the exact `<sessionID>.jsonl` we asked claude to use (`--session-id`), or
    ///   2. the newest `.jsonl` *created at/after* `spawnedAt` — this terminal's own
    ///      file, whatever claude named it, never a pre-existing session's.
    /// Returns nil (caller shows "waiting") until claude writes the first turn, rather
    /// than falling back to the workspace-newest file (which is another session's).
    public static func resolveOwn(
        sessionID: String?, cwd: String, spawnedAt: Date?, claudeHome: URL
    ) -> String? {
        guard !cwd.isEmpty else { return nil }
        let dir = claudeHome.appendingPathComponent("projects")
            .appendingPathComponent(encodeProjectDir(cwd))
        if let sid = sessionID {
            let exact = dir.appendingPathComponent("\(sid).jsonl")
            if FileManager.default.fileExists(atPath: exact.path) { return exact.path }
        }
        return newestJSONL(in: dir, createdAtOrAfter: spawnedAt)
    }

    /// Newest `.jsonl` whose creation date is at/after `floor` (with a small skew
    /// tolerance). With no floor, falls back to newest-by-mtime.
    private static func newestJSONL(in dir: URL, createdAtOrAfter floor: Date?) -> String? {
        guard let floor else { return newestJSONL(in: dir) }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        ) else { return nil }
        let cutoff = floor.addingTimeInterval(-2)  // tolerate a little clock skew
        let mine = files.filter { url in
            url.pathExtension == "jsonl" && (creationDate(url) ?? .distantPast) >= cutoff
        }
        return mine.max { (modDate($0) ?? .distantPast) < (modDate($1) ?? .distantPast) }?.path
    }

    private static func creationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private static func globProjects(named name: String, under projects: URL) -> String? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in dirs {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private static func newestJSONL(in dir: URL) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let jsonl = files.filter { $0.pathExtension == "jsonl" }
        let newest = jsonl.max { a, b in
            (modDate(a) ?? .distantPast) < (modDate(b) ?? .distantPast)
        }
        return newest?.path
    }

    private static func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
