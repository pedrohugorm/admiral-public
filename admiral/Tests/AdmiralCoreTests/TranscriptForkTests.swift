import XCTest
@testable import AdmiralCore

final class TranscriptForkTests: XCTestCase {
    func testCloneRewritesIdAndLeavesSourceIntact() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        let cwd = "/Users/me/code/admiral"
        let dir = home.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.encodeProjectDir(cwd))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let oldID = "11111111-2222-3333-4444-555555555555"
        let newID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let src = dir.appendingPathComponent("\(oldID).jsonl")
        let body = [
            #"{"type":"user","sessionId":"\#(oldID)","message":"hi"}"#,
            #"{"type":"assistant","sessionId":"\#(oldID)","leafUuid":"x"}"#,
        ].joined(separator: "\n") + "\n"
        try body.write(to: src, atomically: true, encoding: .utf8)

        let path = TranscriptFork.clone(sourceID: oldID, newID: newID, cwd: cwd, claudeHome: home)
        XCTAssertEqual(path, dir.appendingPathComponent("\(newID).jsonl").path)

        let copied = try String(contentsOf: dir.appendingPathComponent("\(newID).jsonl"), encoding: .utf8)
        XCTAssertTrue(copied.contains(newID), "new id present in the clone")
        XCTAssertFalse(copied.contains(oldID), "old id fully rewritten out of the clone")

        let original = try String(contentsOf: src, encoding: .utf8)
        XCTAssertTrue(original.contains(oldID), "source transcript is left untouched")
        XCTAssertFalse(original.contains(newID))
    }

    func testCloneMissingSourceReturnsNil() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertNil(TranscriptFork.clone(sourceID: "x", newID: "y", cwd: "/tmp", claudeHome: home))
    }
}
