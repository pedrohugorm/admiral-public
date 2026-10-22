import XCTest
@testable import AdmiralCore

@MainActor
final class AnthropicBackendTests: XCTestCase {

    // Same minimal fixture as SessionManagerTests: default stores, fake host,
    // a claudeHome under /tmp so no real session files are read.
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTabResolutionByDisplayNameCaseInsensitive() {
        let mgr = SessionManager(host: FakeTerminalHost(), claudeHome: tempDir(),
                                 executablePath: "/usr/bin/claude")
        _ = mgr.commission(callsign: "Nasty Bug", cwd: "/tmp")
        let backend: AnthropicBackend = mgr
        let tab = backend.tab(named: "nasty bug")
        XCTAssertNotNil(tab)
        XCTAssertEqual(tab?.name, "Nasty-Bug", "commission sanitizes the name; lookup by the spaced form still resolves")
        XCTAssertTrue(tab?.isManaged ?? false) // commissioned claude gets a --session-id
        XCTAssertNil(backend.tab(named: "no such tab"))
    }

    func testLiveStatusReadsSessionFileFreshly() throws {
        let home = tempDir()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        let mgr = SessionManager(host: FakeTerminalHost(), claudeHome: home,
                                 executablePath: "/usr/bin/claude")
        let session = mgr.commission(callsign: "worker", cwd: "/tmp")
        let sid = try XCTUnwrap(session.claudeSessionID)
        let backend: AnthropicBackend = mgr

        func writeStatus(_ status: String) throws {
            let file = ["pid": 999, "sessionId": sid, "status": status,
                        "updatedAt": Date().timeIntervalSince1970] as [String: Any]
            try JSONSerialization.data(withJSONObject: file)
                .write(to: home.appendingPathComponent("sessions/999.json"))
        }

        try writeStatus("busy")
        XCTAssertEqual(backend.liveStatus(tabID: session.id), .busy)
        try writeStatus("idle")
        XCTAssertEqual(backend.liveStatus(tabID: session.id), .idle) // fresh, not cached
    }

    func testInjectForwardsToTerminal() {
        let host = FakeTerminalHost()
        let mgr = SessionManager(host: host, claudeHome: tempDir(),
                                 executablePath: "/usr/bin/claude")
        let session = mgr.commission(callsign: "w", cwd: "/tmp")
        (mgr as AnthropicBackend).inject(tabID: session.id, text: "hello api")
        XCTAssertTrue(host.combined.contains("hello api"))
    }

    func testTranscriptPathFallsBackToDeterministicPathForFreshTab() throws {
        // A freshly commissioned tab has no transcript FILE yet, so the resolved
        // transcriptPath is nil — but the backend must still return the deterministic
        // path (from the --session-id + cwd) so the endpoint can inject and then poll it.
        let home = tempDir()
        let mgr = SessionManager(host: FakeTerminalHost(), claudeHome: home,
                                 executablePath: "/usr/bin/claude")
        let session = mgr.commission(callsign: "fresh", cwd: "/tmp")
        let sid = try XCTUnwrap(session.claudeSessionID)
        let backend: AnthropicBackend = mgr

        let path = try XCTUnwrap(backend.transcriptPath(tabID: session.id))
        let expected = home.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.encodeProjectDir("/tmp"))
            .appendingPathComponent("\(sid).jsonl").path
        XCTAssertEqual(path, expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "the deterministic path is returned before the file exists")
    }
}
