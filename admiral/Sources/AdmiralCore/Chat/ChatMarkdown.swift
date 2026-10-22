import Foundation

/// A chat message split into the markdown blocks the view draws differently: tables as a
/// grid, fenced code as a monospaced block, headings in bold, everything else as paragraphs
/// (whose inline markdown — bold, code spans, links, list bullets — the view styles as text).
///
/// Only what claude actually writes is recognised; anything that doesn't parse cleanly stays
/// a paragraph, so a message is never lost to a half-parsed block.
public enum ChatBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
}

public enum ChatMarkdown {
    public static func blocks(_ text: String) -> [ChatBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ChatBlock] = []
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ```lang … ``` — an unclosed fence runs to the end of the message.
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                i += 1
                continue
            }

            // | a | b |  +  |---|---|  +  rows
            if isRow(trimmed), i + 1 < lines.count, isSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let header = cells(trimmed)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, isRow(lines[j].trimmingCharacters(in: .whitespaces)) {
                    rows.append(normalized(cells(lines[j].trimmingCharacters(in: .whitespaces)), to: header.count))
                    j += 1
                }
                flush()
                blocks.append(.table(header: header, rows: rows))
                i = j
                continue
            }

            // # Heading
            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    // MARK: - Copying a table

    /// The table as markdown — pastes back as a table anywhere markdown renders.
    public static func markdown(header: [String], rows: [[String]]) -> String {
        func row(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        return ([row(header), "|" + Array(repeating: "---", count: header.count).joined(separator: "|") + "|"]
                + rows.map(row)).joined(separator: "\n")
    }

    /// The table as tab-separated values — what a spreadsheet takes as rows and columns.
    public static func tsv(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { cells in
            cells.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func isRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.count > 1
    }

    /// `|---|:---:|---:|` (outer pipes optional, at least one column).
    static func isSeparator(_ line: String) -> Bool {
        let body = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let columns = body.split(separator: "|", omittingEmptySubsequences: false)
        return !columns.isEmpty && line.contains("-") && columns.allSatisfy { column in
            let c = column.trimmingCharacters(in: .whitespaces)
            return c.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil
        }
    }

    /// A row's cells: split on unescaped `|`, outer pipes dropped, `\|` kept as a pipe.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        cells.append(current)
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|"), line.count > 1, !line.hasSuffix("\\|") { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Pad or trim a row to the header's width, so a ragged row can't break the grid.
    static func normalized(_ row: [String], to width: Int) -> [String] {
        row.count >= width ? Array(row.prefix(width)) : row + Array(repeating: "", count: width - row.count)
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }
}
