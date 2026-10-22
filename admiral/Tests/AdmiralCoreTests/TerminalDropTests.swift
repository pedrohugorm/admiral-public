import XCTest
@testable import AdmiralCore

final class TerminalDropTests: XCTestCase {
    /// An iTerm2 drop of two PDFs in iCloud Drive must type the identical text here:
    /// the spaces and the `~`s escaped, the paths space-joined, then iTerm2's trailing space.
    func testTwoICloudPDFsTypeWhatITerm2Types() {
        let text = TerminalDrop.pasteText(paths: [
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Documents/Reports/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0-list.pdf",
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Documents/Reports/Quarterly Report - Q3 2026.pdf",
        ])
        XCTAssertEqual(text,
            #"/Users/me/Library/Mobile\ Documents/com\~apple\~CloudDocs/Documents/Reports/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0-list.pdf"#
            + " "
            + #"/Users/me/Library/Mobile\ Documents/com\~apple\~CloudDocs/Documents/Reports/Quarterly\ Report\ -\ Q3\ 2026.pdf"#
            + " ")
    }

    /// Every character iTerm2 escapes gets exactly one backslash — the backslash itself included,
    /// and not re-escaped by the ones added after it — tab, CR and LF too.
    func testEscapesEachOfITerm2sShellCharactersOnce() {
        let path = ##"/a\b c(d)e"f&g'h!i$j<k>l;m|n*o?p[q]r#s`t{u}v^w+x=y@z~"## + "\t\r\n"
        XCTAssertEqual(TerminalDrop.pasteText(paths: [path]),
                       ##"/a\\b\ c\(d\)e\"f\&g\'h\!i\$j\<k\>l\;m\|n\*o\?p\[q\]r\#s\`t\{u\}v\^w\+x\=y\@z\~"##
                       + "\\\t\\\r\\\n ")
    }

    /// Characters outside iTerm2's set pass through untouched.
    func testLeavesOtherCharactersAlone() {
        XCTAssertEqual(TerminalDrop.pasteText(paths: ["/keep-_.,%:é/ok"]), "/keep-_.,%:é/ok ")
    }

    /// No files on the drag means nothing to type — the view refuses the drop.
    func testNothingDroppedTypesNothing() {
        XCTAssertNil(TerminalDrop.pasteText(paths: []))
    }
}
