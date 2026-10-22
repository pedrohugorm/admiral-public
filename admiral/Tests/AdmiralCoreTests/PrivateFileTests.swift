import XCTest
@testable import AdmiralCore

/// Files holding conversation text, prompts or a provider token are the user's alone: `0600`
/// files in `0700` folders. Every file here is created inside a unique temp dir.
@MainActor
final class PrivateFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }   // only this test's own temp dir
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    /// A pre-existing file made the way older builds made them: world-readable.
    private func legacyFile(_ url: URL, _ text: String = "old\n") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    func testWriteCreatesAndReplacesFilesAs0600() throws {
        let fresh = dir.appendingPathComponent("fresh.json")
        try PrivateFile.write(Data("{}".utf8), to: fresh)
        XCTAssertEqual(try mode(fresh), 0o600)

        let old = dir.appendingPathComponent("old.json")
        try legacyFile(old)
        try PrivateFile.write("new", to: old)
        XCTAssertEqual(try mode(old), 0o600)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "the temp file is renamed into place, never left behind")
    }

    func testDirectoryIsCreatedAndTightenedTo0700() throws {
        let made = dir.appendingPathComponent("a/b")
        XCTAssertTrue(PrivateFile.directory(made))
        XCTAssertEqual(try mode(made), 0o700)

        let loose = dir.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(PrivateFile.directory(loose))
        XCTAssertEqual(try mode(loose), 0o700)
    }

    func testAppendedLogsAre0600AndTightenAnOlderFile() throws {
        let fresh = dir.appendingPathComponent("chat/s.jsonl")
        AtomicAppend.line(Data("{}".utf8), to: fresh)
        XCTAssertEqual(try mode(fresh), 0o600)

        let old = dir.appendingPathComponent("old.jsonl")
        try legacyFile(old)
        AtomicAppend.line(Data("{}".utf8), to: old)
        XCTAssertEqual(try mode(old), 0o600)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old\n{}\n")
    }

    /// `~/.claude/groups/`: folder 0700, each conversation file 0600, and a file an older build
    /// left 0644 is tightened by the next message.
    func testGroupTranscriptFolderAndFilesArePrivate() throws {
        let store = GroupStore(base: dir.appendingPathComponent("support"))
        let transcript = GroupTranscript(dir: dir.appendingPathComponent("claude/groups"))
        store.transcript = transcript
        let group = try store.create(name: "Ops", members: [UUID(), UUID()]).get()
        store.append(to: group.id, author: .human, name: "You", colorHex: nil, symbol: nil,
                     text: "first", target: .everyone)
        XCTAssertEqual(try mode(transcript.dir), 0o700)
        XCTAssertEqual(try mode(transcript.url(for: group)), 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.url(for: group).path)
        store.append(to: group.id, author: .human, name: "You", colorHex: nil, symbol: nil,
                     text: "second", target: .everyone)
        XCTAssertEqual(try mode(transcript.url(for: group)), 0o600)
        XCTAssertEqual(try String(contentsOf: transcript.url(for: group), encoding: .utf8)
            .split(separator: "\n").count, 2)
    }

    /// `<support>/groups/`: the group list, each log, cursors, callsigns and the sidebar order.
    func testSupportGroupFilesAre0600() throws {
        let base = dir.appendingPathComponent("support")
        let store = GroupStore(base: base)
        let a = UUID()
        let group = try store.create(name: "Ops", members: [a, UUID()]).get()
        store.append(to: group.id, author: .human, name: "You", colorHex: nil, symbol: nil,
                     text: "hello", target: .everyone)
        store.setCursor(a, group: group.id, to: 1)
        GroupFiles.writeCallsigns(peers: [], base: base)
        SidebarOrderStore(base: base).save([group.id])

        XCTAssertEqual(try mode(AdmiralPaths.groupsDir(base: base)), 0o700)
        for url in [AdmiralPaths.groupsFile(base: base),
                    AdmiralPaths.groupLogFile(base: base, group: group.id),
                    AdmiralPaths.groupCursorsFile(base: base, group: group.id),
                    AdmiralPaths.groupCallsignsFile(base: base),
                    AdmiralPaths.sidebarOrderFile(base: base)] {
            XCTAssertEqual(try mode(url), 0o600, url.lastPathComponent)
        }
    }

    func testChatLedgerFilesAre0600() throws {
        let base = dir.appendingPathComponent("support")
        ChatLedger.append(ChatEvent(ts: "2026-01-01T00:00:00Z", kind: .prompt, text: "secret plan"), base: base, session: "s1")
        ChatLedger.setMode(.chat, base: base, session: "s1")
        ChatLedger.markInjected("typed", source: "admiral", base: base, session: "s1")
        _ = ChatLedger.consumeInjected(prompt: "typed", base: base, session: "s1")
        for url in [ChatLedger.url(base: base, session: "s1"), ChatLedger.modeURL(base: base, session: "s1"),
                    ChatLedger.injectedURL(base: base, session: "s1")] {
            XCTAssertEqual(try mode(url), 0o600, url.lastPathComponent)
        }
    }

    func testForkedTranscriptIs0600() throws {
        let cwd = "/work/proj"
        let projects = dir.appendingPathComponent("projects/\(TranscriptLocator.encodeProjectDir(cwd))")
        let oldID = "11111111-2222-3333-4444-555555555555", newID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try legacyFile(projects.appendingPathComponent("\(oldID).jsonl"), #"{"sessionId":"\#(oldID)"}"#)
        let path = try XCTUnwrap(TranscriptFork.clone(sourceID: oldID, newID: newID, cwd: cwd, claudeHome: dir))
        XCTAssertEqual(try mode(URL(fileURLWithPath: path)), 0o600)
    }

    func testHookSettingsFileIs0600() throws {
        let url = dir.appendingPathComponent("sessions/t/settings.json")
        XCTAssertTrue(HookSettings.write(helper: "/x/admiral-hook", providerEnv: ["ANTHROPIC_AUTH_TOKEN": "t"], to: url))
        XCTAssertEqual(try mode(url), 0o600)
    }
}
