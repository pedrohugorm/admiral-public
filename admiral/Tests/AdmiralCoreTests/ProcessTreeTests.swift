import XCTest
@testable import AdmiralCore

final class ProcessTreeTests: XCTestCase {
    /// Exercises the REAL `ps` drain. This is the test that would have caught the
    /// pipe-buffer deadlock: `ps -axo command` output exceeds 64KB on a machine with
    /// Electron apps, so a snapshot that waits before draining hangs here forever.
    /// It must return promptly with a populated tree that includes launchd (pid 1).
    func testSnapshotDrainsAndIncludesLaunchd() {
        let snap = ProcessTree.snapshot()
        XCTAssertGreaterThan(snap.count, 10, "ps snapshot should list many processes")
        XCTAssertNotNil(snap[1], "launchd (pid 1) must be present")
    }

    /// A pid with no claude descendant resolves to nil (fast, no hang).
    func testFindClaudePidReturnsNilForNonClaudeTree() {
        // pid 1 (launchd) is not claude and we are not under it as a 'claude' command.
        let snap: ProcessTree.Snapshot = [
            1: (ppid: 0, command: "/sbin/launchd"),
            42: (ppid: 1, command: "/bin/zsh"),
        ]
        XCTAssertNil(ProcessTree.findClaudePid(spawnPid: 42, snapshot: snap))
    }

    /// A descendant whose command looks like claude is found.
    func testFindClaudePidWalksDescendants() {
        let snap: ProcessTree.Snapshot = [
            100: (ppid: 1, command: "/bin/zsh -ilc exec claude"),
            101: (ppid: 100, command: "node /opt/claude/cli.js --permission-mode bypassPermissions"),
        ]
        XCTAssertEqual(ProcessTree.findClaudePid(spawnPid: 100, snapshot: snap), 100)
        let snap2: ProcessTree.Snapshot = [
            200: (ppid: 1, command: "/bin/zsh"),
            201: (ppid: 200, command: "claude"),
        ]
        XCTAssertEqual(ProcessTree.findClaudePid(spawnPid: 200, snapshot: snap2), 201)
    }
}
