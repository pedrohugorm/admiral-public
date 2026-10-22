import Foundation

/// Incremental reader for a session's `prompts.jsonl`. The caller keeps the returned byte
/// offset and passes it back next tick, so each prompt is seen exactly once. Only complete
/// (newline-terminated) lines are consumed — a torn concurrent append is left for the next
/// read. A file smaller than the offset (deleted/recreated) restarts from zero.
public enum PromptLogReader {
    public static func read(url: URL, offset: UInt64) -> (events: [PromptEvent], offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset > size ? 0 : offset
        guard size > start else { return ([], start) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], start) }

        // Consume only through the last newline; the remainder is a line still being written.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = data[data.startIndex...lastNewline]
        let decoder = JSONDecoder()
        let events = complete.split(separator: 0x0A).compactMap {
            try? decoder.decode(PromptEvent.self, from: Data($0))
        }
        return (events, start + UInt64(complete.count))
    }
}
