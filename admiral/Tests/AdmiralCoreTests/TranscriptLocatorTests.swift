import XCTest
@testable import AdmiralCore

final class TranscriptLocatorTests: XCTestCase {
    /// Ported verbatim from the Go TUI's `TestEncodeProjectDir` (activity_test.go) so
    /// Admiral's encoder stays byte-identical to the bridge's.
    func testEncodeProjectDir() {
        let cases = [
            "/Users/me/code/admiral": "-Users-me-code-admiral",
            "/Users/me/code/brain_mcp": "-Users-me-code-brain-mcp",     // '_' -> '-'
            "/Users/me/foo.bar": "-Users-me-foo-bar",                   // '.' -> '-'
        ]
        for (input, want) in cases {
            XCTAssertEqual(TranscriptLocator.encodeProjectDir(input), want)
        }
    }

    /// Ported from the Go TUI's `TestResolvePathFallbackNewest` (session_test.go): with
    /// no session file, the legacy bridge-style resolve returns the newest .jsonl in the
    /// cwd's project dir. (Admiral-spawned sessions use resolveOwn instead; this guards
    /// the adopted/legacy path.)
    func testResolvePathFallbackNewest() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("admiral-home-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("projects/\(TranscriptLocator.encodeProjectDir("/Users/me/p2"))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let old = dir.appendingPathComponent("old.jsonl")
        let newer = dir.appendingPathComponent("new.jsonl")
        try "{}\n".write(to: old, atomically: true, encoding: .utf8)
        try "{}\n".write(to: newer, atomically: true, encoding: .utf8)
        // make `old` actually older
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)

        let resolved = TranscriptLocator.resolve(pid: 0, fallbackCwd: "/Users/me/p2", claudeHome: home)
        XCTAssertEqual(resolved.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       newer.resolvingSymlinksInPath().path)
    }

    func testResolveViaSessionFile() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("admiral-home-\(UUID().uuidString)")
        let cwd = "/Users/me/code/demo"
        let sessionID = "abc-123"
        let projectDir = home.appendingPathComponent("projects/\(TranscriptLocator.encodeProjectDir(cwd))")
        try fm.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let pid: Int32 = 9001
        let sessionJSON = #"{"pid":9001,"sessionId":"abc-123","cwd":"/Users/me/code/demo","status":"busy"}"#
        try sessionJSON.write(to: home.appendingPathComponent("sessions/\(pid).json"), atomically: true, encoding: .utf8)
        let transcript = projectDir.appendingPathComponent("\(sessionID).jsonl")
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#.write(to: transcript, atomically: true, encoding: .utf8)

        let resolved = TranscriptLocator.resolve(pid: pid, fallbackCwd: cwd, claudeHome: home)
        XCTAssertEqual(resolved.path, transcript.path)
        XCTAssertEqual(resolved.file?.sessionId, "abc-123")
        XCTAssertEqual(resolved.file?.status, "busy")

        let convo = TranscriptStore.loadTail(path: transcript.path)
        XCTAssertEqual(convo.turns.count, 1)
        try? fm.removeItem(at: home)
    }

    /// `resolveOwn` prefers the exact `<sessionID>.jsonl` over any other file present.
    func testResolveOwnPrefersExactSessionID() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("admiral-home-\(UUID().uuidString)")
        let cwd = "/Users/me/code/ai"
        let dir = home.appendingPathComponent("projects/\(TranscriptLocator.encodeProjectDir(cwd))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let sid = "11112222-3333-4444-5555-666677778888"
        try "x".write(to: dir.appendingPathComponent("\(UUID().uuidString).jsonl"), atomically: true, encoding: .utf8)
        let mine = dir.appendingPathComponent("\(sid).jsonl")
        try "y".write(to: mine, atomically: true, encoding: .utf8)

        let path = TranscriptLocator.resolveOwn(
            sessionID: sid, cwd: cwd, spawnedAt: .distantPast, claudeHome: home
        )
        XCTAssertEqual(path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       mine.resolvingSymlinksInPath().path)
    }

    /// The creation-date gate: a file created before the spawn is NOT this session's —
    /// `resolveOwn` excludes it (returns nil) rather than leaking another session's data.
    func testResolveOwnExcludesPreSpawnFiles() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("admiral-home-\(UUID().uuidString)")
        let cwd = "/Users/me/code/ai"
        let dir = home.appendingPathComponent("projects/\(TranscriptLocator.encodeProjectDir(cwd))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let existing = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try "old".write(to: existing, atomically: true, encoding: .utf8)

        // Spawned in the far future relative to the file → excluded (no exact id match).
        XCTAssertNil(TranscriptLocator.resolveOwn(
            sessionID: nil, cwd: cwd, spawnedAt: .distantFuture, claudeHome: home
        ), "a pre-spawn file must not be adopted as this session's transcript")
        // Spawned in the far past → the file is at/after the cutoff → it IS ours.
        XCTAssertEqual(TranscriptLocator.resolveOwn(
            sessionID: nil, cwd: cwd, spawnedAt: .distantPast, claudeHome: home
        ).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       existing.resolvingSymlinksInPath().path)
    }
}
