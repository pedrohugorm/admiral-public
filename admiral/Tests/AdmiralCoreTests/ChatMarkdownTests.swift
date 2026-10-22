import XCTest
@testable import AdmiralCore

/// Markdown blocks in a chat message: tables become grids, code fences and headings their
/// own blocks, and anything that doesn't parse cleanly stays a paragraph.
final class ChatMarkdownTests: XCTestCase {
    /// The shape claude writes: a lead-in sentence, a table, then a bulleted list.
    func testTableBetweenProseBecomesATable() {
        let text = """
            There are two metrics so far.

            | # | Metric | Formula | Baseline |
            |---|---|---|---|
            | 1 | Hit rate | Hits ÷ all lookups | TBD |
            | 1a | Miss cost (guard) | Misses × `retry cost` | 0% |

            Open decisions:
            - Define a hit.
            - Pick a window.
            """
        XCTAssertEqual(ChatMarkdown.blocks(text), [
            .paragraph("There are two metrics so far."),
            .table(header: ["#", "Metric", "Formula", "Baseline"], rows: [
                ["1", "Hit rate", "Hits ÷ all lookups", "TBD"],
                ["1a", "Miss cost (guard)", "Misses × `retry cost`", "0%"],
            ]),
            .paragraph("Open decisions:\n- Define a hit.\n- Pick a window."),
        ])
    }

    func testAlignedSeparatorAndNoOuterPipes() {
        XCTAssertEqual(ChatMarkdown.blocks("| a | b |\n|:--|--:|\n| 1 | 2 |"),
                       [.table(header: ["a", "b"], rows: [["1", "2"]])])
        XCTAssertTrue(ChatMarkdown.isSeparator("---|:---:"))
    }

    /// A ragged row is padded or trimmed to the header, and `\|` stays a literal pipe.
    func testRaggedRowsAndEscapedPipes() {
        let blocks = ChatMarkdown.blocks("| a | b |\n|---|---|\n| only |\n| x | y | z |\n| p \\| q | r |")
        XCTAssertEqual(blocks, [.table(header: ["a", "b"], rows: [["only", ""], ["x", "y"], ["p | q", "r"]])])
    }

    /// Pipes without a separator row under them are just text.
    func testPipesWithoutASeparatorStayText() {
        XCTAssertEqual(ChatMarkdown.blocks("| not a table |\njust text"),
                       [.paragraph("| not a table |\njust text")])
    }

    func testCodeFenceAndHeading() {
        let text = "## Plan\nRun this:\n```bash\nswift test\n| not | a table |\n```\nDone."
        XCTAssertEqual(ChatMarkdown.blocks(text), [
            .heading(level: 2, text: "Plan"),
            .paragraph("Run this:"),
            .code(language: "bash", text: "swift test\n| not | a table |"),
            .paragraph("Done."),
        ])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(ChatMarkdown.blocks("```\nlet x = 1"), [.code(language: nil, text: "let x = 1")])
    }

    /// A copied table round-trips: its markdown parses back to the same table.
    func testCopiedMarkdownParsesBackToTheSameTable() {
        let header = ["#", "Metric"], rows = [["1", "Hit rate"], ["1a", "a | b"]]
        let copied = ChatMarkdown.markdown(header: header, rows: rows)
        XCTAssertEqual(copied, "| # | Metric |\n|---|---|\n| 1 | Hit rate |\n| 1a | a \\| b |")
        XCTAssertEqual(ChatMarkdown.blocks(copied), [.table(header: header, rows: rows)])
    }

    /// Tab-separated for spreadsheets: one line per row, one tab per column, no stray tabs.
    func testCopiedTSVIsOneLinePerRow() {
        XCTAssertEqual(ChatMarkdown.tsv(header: ["a", "b"], rows: [["1", "two\tcells"], ["x", "y"]]),
                       "a\tb\n1\ttwo cells\nx\ty")
    }

    func testPlainMessageIsOneParagraph() {
        XCTAssertEqual(ChatMarkdown.blocks("Fixed. Tests pass."), [.paragraph("Fixed. Tests pass.")])
        XCTAssertEqual(ChatMarkdown.blocks("#hashtag is not a heading"), [.paragraph("#hashtag is not a heading")])
    }
}
