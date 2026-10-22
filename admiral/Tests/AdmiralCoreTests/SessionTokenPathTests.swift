import XCTest
@testable import AdmiralCore

/// `ADMIRAL_SESSION` reaches the hook helper through the environment and names a directory
/// under `sessions/`; whatever it holds, that directory stays directly inside `sessions/`.
/// Pure path assertions in a unique temp dir.
final class SessionTokenPathTests: XCTestCase {
    func testATokenCannotEscapeTheSessionsFolder() throws {
        let fm = FileManager.default
        // `base` sits two levels inside a unique root, so even an unsanitized `../../x` (the
        // mutation this test exists to catch) would land inside that root, never beyond it.
        let root = fm.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString)")
        let base = root.appendingPathComponent("a/base")
        defer { try? fm.removeItem(at: root) }   // only this test's temp dir
        let sessions = base.appendingPathComponent("sessions").standardizedFileURL.path

        for token in ["../../x", "..", ".", "", "a/../../b", "/etc", "x/y", "..\u{2215}x", "~", "../x"] {
            let dir = AdmiralPaths.sessionDir(base: base, token: token).standardizedFileURL
            XCTAssertEqual(dir.deletingLastPathComponent().path, sessions, "token \(token.debugDescription) → \(dir.path)")
            XCTAssertFalse(["", ".", ".."].contains(dir.lastPathComponent), token)
            XCTAssertTrue(fm.fileExists(atPath: dir.path), "created where it belongs")
        }
        // Every file the helper derives from a token lands in that one folder too.
        let log = AdmiralPaths.touchedLog(base: base, token: "../../x").standardizedFileURL
        XCTAssertEqual(log.deletingLastPathComponent().deletingLastPathComponent().path, sessions)
        // Nothing was created beside `sessions/` or above `base`.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path), ["sessions"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["a"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("a").path), ["base"])
    }

    func testAUUIDTokenIsUnchanged() {
        let token = UUID().uuidString
        XCTAssertEqual(AdmiralPaths.sanitized(token), token)
        XCTAssertEqual(AdmiralPaths.sanitized(token.lowercased()), token.lowercased())
    }
}
