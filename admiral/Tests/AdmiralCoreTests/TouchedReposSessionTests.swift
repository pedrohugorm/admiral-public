import XCTest
@testable import AdmiralCore

@MainActor
final class TouchedReposSessionTests: XCTestCase {
    private func writeLog(_ lines: [String], base: URL, token: String) throws {
        let url = AdmiralPaths.touchedLog(base: base, token: token)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testRefreshAggregatesAndPreservesPR() async throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: support) }
        let manager = SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/usr/bin/claude", supportDir: support)
        let session = manager.commission(callsign: "x", cwd: "/tmp")

        try writeLog([
            #"{"ts":"1","tool":"Write","filePath":"/a/x","repoRoot":"/a","branch":"main","insideSessionRoot":false}"#,
        ], base: support, token: session.token)

        manager.refreshTouchedRepos(for: session.id)
        try await waitUntil { manager.sessions.first { $0.id == session.id }?.touchedRepos.count == 1 }
        XCTAssertEqual(manager.selectedSession?.touchedRepos.first?.root, "/a")

        // Fetch a PR, then a new write arrives — the PR must survive the refresh.
        manager.setTouchedRepoPRs(session.id, root: "/a",
            prs: [PRStatus(number: 7, title: "t", url: "u", isMerged: false, canMerge: true,
                           approvals: 1, checksPassed: 1, checksRunning: 0, checksFailed: 0)])
        try writeLog([
            #"{"ts":"1","tool":"Write","filePath":"/a/x","repoRoot":"/a","branch":"main","insideSessionRoot":false}"#,
            #"{"ts":"2","tool":"Edit","filePath":"/a/y","repoRoot":"/a","branch":"main","insideSessionRoot":false}"#,
        ], base: support, token: session.token)
        manager.refreshTouchedRepos(for: session.id)
        try await waitUntil { manager.selectedSession?.touchedRepos.first?.filesWritten == 2 }
        XCTAssertEqual(manager.selectedSession?.touchedRepos.first?.prs.first?.number, 7,
                       "PR status preserved across a log refresh")
    }

    /// The footprint persists across relaunch: a second manager sharing the same store
    /// restores the repos for the same session id, and an empty live log does not wipe them.
    func testFootprintPersistsAcrossRelaunch() async throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: support) }
        let suite = "admiral-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TouchedReposStore(defaults: defaults)
        let sid = "fixed-session-id"

        // Run 1: commission at a fixed session id, write a log, refresh → footprint persisted.
        let m1 = SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/usr/bin/claude", supportDir: support, touchedReposStore: store)
        let s1 = m1.commission(callsign: "x", cwd: "/tmp", sessionID: sid)
        try writeLog([
            #"{"ts":"1","tool":"Write","filePath":"/a/x","repoRoot":"/a","branch":"main","insideSessionRoot":false}"#,
        ], base: support, token: s1.token)
        m1.refreshTouchedRepos(for: s1.id)
        try await waitUntil { m1.sessions.first { $0.id == s1.id }?.touchedRepos.count == 1 }
        XCTAssertEqual(store.repos(forSession: sid).map(\.root), ["/a"], "footprint persisted to the store")

        // Run 2 (relaunch): a NEW manager + the SAME store, same session id, EMPTY live log.
        let m2 = SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/usr/bin/claude", supportDir: support, touchedReposStore: store)
        let s2 = m2.commission(callsign: "x", cwd: "/tmp", sessionID: sid)
        XCTAssertEqual(m2.selectedSession?.touchedRepos.map(\.root), ["/a"], "footprint restored on relaunch")
        m2.refreshTouchedRepos(for: s2.id)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(m2.selectedSession?.touchedRepos.map(\.root), ["/a"],
                       "an empty live log must not wipe the restored footprint")
    }

    private func waitUntil(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !cond() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(cond(), "condition not met in time")
    }
}
