import XCTest
@testable import AdmiralCore

final class TerminalLinkTests: XCTestCase {
    /// The bug: claude emits a spec path as a link relative to its workspace (".output/…").
    /// SwiftTerm's default `URL(string:) + NSWorkspace.open` gets a schemeless URL and fails
    /// with -50. Resolve it against the session cwd into a real, openable file URL.
    func testRelativePathResolvesAgainstCwd() {
        let link = TerminalLink.resolve(".output/specs/foo.md", cwd: "/work/proj",
                                        fileExists: { $0 == "/work/proj/.output/specs/foo.md" })
        guard case let .file(url) = link else { return XCTFail("expected .file, got \(link)") }
        XCTAssertEqual(url.path, "/work/proj/.output/specs/foo.md")
    }

    /// A path that doesn't resolve to a real file returns `.none` — the app can beep instead
    /// of handing Launch Services a bad URL (which is what produced the -50 dialog).
    func testRelativePathThatDoesNotExistIsNone() {
        XCTAssertEqual(TerminalLink.resolve(".output/missing.md", cwd: "/work/proj",
                                            fileExists: { _ in false }), .none)
    }

    /// An absolute path with no scheme is also a file — the old default mishandled these too.
    func testAbsolutePathOpensAsFile() {
        let link = TerminalLink.resolve("/Users/x/notes.md", cwd: "/work",
                                        fileExists: { $0 == "/Users/x/notes.md" })
        guard case let .file(url) = link else { return XCTFail("expected .file, got \(link)") }
        XCTAssertEqual(url.path, "/Users/x/notes.md")
    }

    /// A `file://` URL is decoded to its filesystem path (percent-escapes included).
    func testFileURLResolvesToDecodedPath() {
        let link = TerminalLink.resolve("file:///Users/x/a%20b.md", cwd: "/work",
                                        fileExists: { $0 == "/Users/x/a b.md" })
        guard case let .file(url) = link else { return XCTFail("expected .file, got \(link)") }
        XCTAssertEqual(url.path, "/Users/x/a b.md")
    }

    /// Web links pass through untouched (no regression for http/https).
    func testHttpsLinkIsWeb() {
        XCTAssertEqual(TerminalLink.resolve("https://example.com/x", cwd: "/work",
                                            fileExists: { _ in false }),
                       .web(URL(string: "https://example.com/x")!))
    }

    /// The click that beeped: claude ended a sentence on a path, and the link picked out of
    /// the rendered text carried the full stop. The file is there; the period is prose.
    func testASentencesFullStopOnAPathIsForgiven() {
        let file = "/Users/me/Downloads/review_with_transcript.md"
        let exists: (String) -> Bool = { $0 == file }
        XCTAssertEqual(TerminalLink.resolveInProse(file + ".", cwd: "/work", fileExists: exists),
                       .file(URL(fileURLWithPath: file)))
        XCTAssertEqual(TerminalLink.resolveInProse(file + "`).", cwd: "/work", fileExists: exists),
                       .file(URL(fileURLWithPath: file)))
        XCTAssertEqual(TerminalLink.resolveInProse("/nope.md.", cwd: "/work", fileExists: exists), .none)
    }

    /// Longest first: a name that really ends in a dot is not trimmed to a shorter sibling.
    func testTheLongestExistingCandidateWins() {
        let link = TerminalLink.resolveInProse("/w/a.md.", cwd: "/w",
                                               fileExists: { $0 == "/w/a.md." || $0 == "/w/a.md" })
        XCTAssertEqual(link, .file(URL(fileURLWithPath: "/w/a.md.")))
    }

    func testEmptyLinkIsNone() {
        XCTAssertEqual(TerminalLink.resolve("   ", cwd: "/work", fileExists: { _ in true }), .none)
    }
}
