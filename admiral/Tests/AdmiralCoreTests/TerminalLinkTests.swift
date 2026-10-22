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

    /// Only http/https/mailto open as web links. Any other scheme a session prints — a system
    /// settings pane, a custom app URL handler, ssh — resolves to nothing, so a click runs nothing.
    func testOnlyHttpHttpsAndMailtoOpenAsWebLinks() {
        for ok in ["http://example.com", "HTTPS://example.com/x", "mailto:a@example.com"] {
            XCTAssertEqual(TerminalLink.resolve(ok, cwd: "/work", fileExists: { _ in false }),
                           .web(URL(string: ok)!), ok)
        }
        for bad in ["x-apple.systempreferences:com.apple.preference.security", "ssh://host",
                    "vscode://file/etc/hosts", "javascript:alert(1)", "smb://server/share",
                    "someapp://do-something"] {
            XCTAssertEqual(TerminalLink.resolve(bad, cwd: "/work", fileExists: { _ in true }), .none, bad)
        }
        XCTAssertFalse(TerminalLink.isWebURL(URL(string: "ftp://example.com")!))
    }

    /// A file opening would run — an app bundle, a script by extension, anything with the
    /// executable bit, or a link to one — resolves to `.reveal` (Finder), never `.file`.
    /// Ordinary files and folders still open. Real files in a unique temp dir; nothing is run.
    func testRunnableFilesAreRevealedNotOpened() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }   // removes only the dir this test created

        func file(_ name: String, mode: Int = 0o644) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("inert\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }
        let notes = try file("notes.md")
        let folder = dir.appendingPathComponent("plain-folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = try file("tool-no-extension", mode: 0o755)
        let command = try file("go.command")
        let webloc = try file("site.webloc")
        let bundle = dir.appendingPathComponent("Thing.app/Contents/MacOS")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let renamedBundle = dir.appendingPathComponent("Disguised")
        try fm.createDirectory(at: renamedBundle.appendingPathComponent("Contents/MacOS"),
                               withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("readme.md")
        try fm.createSymbolicLink(at: alias, withDestinationURL: tool)

        let cwd = dir.path
        XCTAssertEqual(TerminalLink.resolve("notes.md", cwd: cwd), .file(notes.standardizedFileURL))
        XCTAssertEqual(TerminalLink.resolve("plain-folder", cwd: cwd), .file(folder.standardizedFileURL))
        for (raw, url) in [("tool-no-extension", tool), ("go.command", command), ("site.webloc", webloc),
                           ("Thing.app", dir.appendingPathComponent("Thing.app")),
                           ("Disguised", renamedBundle), ("readme.md", alias)] {
            XCTAssertEqual(TerminalLink.resolve(raw, cwd: cwd), .reveal(url.standardizedFileURL), raw)
        }
        XCTAssertEqual(TerminalLink.forFile(notes), .file(notes))
        XCTAssertEqual(TerminalLink.forFile(tool), .reveal(tool))
    }

    func testEmptyLinkIsNone() {
        XCTAssertEqual(TerminalLink.resolve("   ", cwd: "/work", fileExists: { _ in true }), .none)
    }
}
