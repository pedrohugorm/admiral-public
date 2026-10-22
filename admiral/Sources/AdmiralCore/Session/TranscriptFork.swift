import Foundation

/// Forks a session's transcript so it can be resumed as an independent copy. Claude's
/// transcript lives at `projects/<enc-cwd>/<sessionId>.jsonl` and every line embeds that
/// id; we copy it to `<newId>.jsonl` rewriting the id throughout, so the clone is a
/// self-consistent, standalone transcript that `claude --resume <newId>` opens cleanly.
/// The id is a UUID, so a global text replace is safe (no false matches).
public enum TranscriptFork {
    /// Clone `sourceID`'s transcript under `newID` in the same cwd. Returns the new file's
    /// path, or nil if the source transcript is missing/unreadable or the write fails.
    @discardableResult
    public static func clone(sourceID: String, newID: String, cwd: String, claudeHome: URL) -> String? {
        let dir = claudeHome.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.encodeProjectDir(cwd))
        let source = dir.appendingPathComponent("\(sourceID).jsonl")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        let dest = dir.appendingPathComponent("\(newID).jsonl")
        do {
            try text.replacingOccurrences(of: sourceID, with: newID)
                .write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return dest.path
    }
}
