import XCTest
@testable import AdmiralCore

final class TouchedReposReaderTests: XCTestCase {
    func testPathsAreNamespacedByToken() {
        let base = URL(fileURLWithPath: "/tmp/admiral-paths-test")
        let log = AdmiralPaths.touchedLog(base: base, token: "tok")
        let settings = AdmiralPaths.settingsFile(base: base, token: "tok")
        XCTAssertEqual(log.path, "/tmp/admiral-paths-test/sessions/tok/touched.jsonl")
        XCTAssertEqual(settings.path, "/tmp/admiral-paths-test/sessions/tok/settings.json")
    }

    func testAggregatesByRootInFirstTouchedOrder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agg-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let log = dir.appendingPathComponent("touched.jsonl")
        let lines = [
            #"{"ts":"1","tool":"Write","filePath":"/a/x","repoRoot":"/a","branch":"main","insideSessionRoot":true}"#,
            #"{"ts":"2","tool":"Edit","filePath":"/b/y","repoRoot":"/b","branch":"dev","insideSessionRoot":false}"#,
            #"{"ts":"3","tool":"Edit","filePath":"/a/z","repoRoot":"/a","branch":"main","insideSessionRoot":true}"#,
            #"{"ts":"4","tool":"Write","filePath":"/t/n","repoRoot":null,"branch":null,"insideSessionRoot":false}"#,
        ]
        try lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)

        let repos = TouchedReposReader.read(logURL: log)
        XCTAssertEqual(repos.map(\.root), ["/a", "/b"])   // null-root line ignored
        XCTAssertEqual(repos[0].filesWritten, 2)
        XCTAssertTrue(repos[0].insideSessionRoot)
        XCTAssertEqual(repos[1].branches, ["dev"])
    }

    /// A repo written to on more than one branch collects every distinct branch (first-seen
    /// order), so each branch's PR can be surfaced — instead of collapsing to a single branch.
    func testCollectsDistinctBranchesPerRoot() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let log = dir.appendingPathComponent("touched.jsonl")
        let lines = [
            #"{"ts":"1","tool":"Write","filePath":"/a/x","repoRoot":"/a","branch":"main","insideSessionRoot":true}"#,
            #"{"ts":"2","tool":"Edit","filePath":"/a/y","repoRoot":"/a","branch":"feature/one","insideSessionRoot":true}"#,
            #"{"ts":"3","tool":"Edit","filePath":"/a/z","repoRoot":"/a","branch":"main","insideSessionRoot":true}"#,
            #"{"ts":"4","tool":"Edit","filePath":"/a/w","repoRoot":"/a","branch":"feature/two","insideSessionRoot":true}"#,
        ]
        try lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)

        let repos = TouchedReposReader.read(logURL: log)
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].branches, ["main", "feature/one", "feature/two"])
        XCTAssertEqual(repos[0].filesWritten, 4)
    }

    func testMissingLogReturnsEmpty() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)/touched.jsonl")
        XCTAssertEqual(TouchedReposReader.read(logURL: url), [])
    }
}
