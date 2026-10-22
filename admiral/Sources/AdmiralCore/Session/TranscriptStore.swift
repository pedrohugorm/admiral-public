import Foundation

/// Loads a transcript file into a `Conversation`. Renders the tail (last N lines)
/// so large transcripts stay cheap, but recovers the title from a lightweight
/// full-file scan (title lines can predate the tail window). The app re-loads on a
/// timer for live updates.
public enum TranscriptStore {
    public static func loadTail(path: String, maxLines: Int = 600) -> Conversation {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .empty
        }
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = allLines.count > maxLines ? Array(allLines.suffix(maxLines)) : allLines

        var convo = TranscriptParser.parse(lines: tail)
        if convo.title == nil {
            convo.title = latestTitle(in: allLines)
        }
        // The turns are the tail; the plan is the whole file. Only pay for the extra scan
        // once the file actually outgrew the window.
        if allLines.count > maxLines {
            convo.plan = TranscriptParser.plan(lines: allLines)
        }
        return convo
    }

    /// Scan only lines that could be title lines (cheap substring gate) and keep the
    /// last of each kind; custom wins over ai-title wins over agent-name.
    private static func latestTitle(in lines: [String]) -> String? {
        let decoder = JSONDecoder()
        var titles = TitleAccumulator()
        for line in lines {
            guard line.contains("title") || line.contains("agent-name") else { continue }
            guard let data = line.data(using: .utf8),
                  let raw = try? decoder.decode(RawLine.self, from: data) else { continue }
            titles.ingest(raw)
        }
        return titles.resolved
    }
}
