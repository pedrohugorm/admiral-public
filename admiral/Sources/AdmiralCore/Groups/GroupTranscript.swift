import Foundation

/// A readable, durable copy of each group's conversation, next to where claude keeps its own
/// session transcripts but in a folder of its own: `<claude home>/groups/<name>-<id>.jsonl`.
///
/// The live log under Admiral's support dir is working state (the prompt hook reads it, deleting
/// a group removes it). This copy is the record: one `GroupMessage` JSON object per line, never
/// rewritten, kept when the group is deleted. It is not under `projects/`, so claude's own
/// session listing never sees it.
public struct GroupTranscript: Sendable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    /// `<slug of name>-<first 8 of id>.jsonl`. The id keeps two groups with the same slug apart.
    public func url(for group: ChatGroup) -> URL {
        dir.appendingPathComponent("\(Self.slug(group.name))-\(group.id.uuidString.prefix(8).lowercased()).jsonl")
    }

    /// Adds `message` to the group's file. A file that does not exist yet (first message, or a
    /// group that predates the mirror) is written whole from `log`, which already holds `message`.
    /// The folder is `0700` and each file `0600` (`PrivateFile`); a file left `0644` by an older
    /// build is tightened on its next append.
    public func record(_ message: GroupMessage, group: ChatGroup, log: [GroupMessage]) {
        PrivateFile.directory(dir)
        let url = url(for: group)
        if !FileManager.default.fileExists(atPath: url.path) {
            var all = Data()
            for entry in log {
                if let line = try? GroupFiles.encoder.encode(entry) { all.append(line); all.append(0x0A) }
            }
            try? PrivateFile.write(all, to: url)
            return
        }
        guard let line = try? GroupFiles.encoder.encode(message) else { return }
        AtomicAppend.line(line, to: url)
    }

    /// The group was renamed: its file follows, so the folder still reads by name.
    public func renamed(from old: ChatGroup, to new: ChatGroup) {
        let from = url(for: old), to = url(for: new)
        guard from != to, FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.moveItem(at: from, to: to)
    }

    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var collapsed = ""
        for c in mapped where !(c == "-" && collapsed.last == "-") { collapsed.append(c) }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(40)).isEmpty ? "group" : String(trimmed.prefix(40))
    }
}
