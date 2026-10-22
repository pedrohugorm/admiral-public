import XCTest
@testable import AdmiralCore

final class BashRestoreSettingsTests: XCTestCase {
    func testNormalizeDropsPathsArgsAndDupes() {
        let n = BashRestoreSettings.normalize([
            "K9s", " k9s ", "/opt/homebrew/bin/k9s", "htop -d 1", "", "htop",
        ])
        XCTAssertEqual(n, ["htop", "k9s"])
    }

    func testStoreRoundTrip() {
        let defaults = UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
        let store = BashRestoreSettingsStore(defaults: defaults)
        store.save(BashRestoreSettings(enabled: false, allowlist: ["k9s", "vim"]))
        let loaded = store.load()
        XCTAssertFalse(loaded.enabled)
        XCTAssertEqual(loaded.allowlist, ["k9s", "vim"])
    }
}

final class BashRestoreCommandTests: XCTestCase {
    func testAllowlistedDeepestWins() {
        let snap: ProcessTree.Snapshot = [
            1: (ppid: 0, command: "/sbin/launchd"),
            10: (ppid: 1, command: "/bin/zsh -il"),
            11: (ppid: 10, command: "/opt/homebrew/bin/k9s"),
            12: (ppid: 11, command: "k9s-helper"),  // not allowlisted
        ]
        let cmd = ProcessTree.allowlistedRestoreCommand(
            spawnPid: 10, allowlist: ["k9s", "htop"], snapshot: snap)
        XCTAssertEqual(cmd, "k9s")
    }

    func testNonAllowlistedIgnored() {
        let snap: ProcessTree.Snapshot = [
            10: (ppid: 1, command: "/bin/zsh"),
            11: (ppid: 10, command: "kubectl delete pod x"),
        ]
        XCTAssertNil(ProcessTree.allowlistedRestoreCommand(
            spawnPid: 10, allowlist: ["k9s"], snapshot: snap))
    }

    func testBasenameOnlyNoArgs() {
        XCTAssertEqual(ProcessTree.executableBasename("/opt/homebrew/bin/k9s --foo"), "k9s")
    }

    func testRestoreCommandSurvivesStructuralUpsert() {
        let defaults = UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
        let store = OpenSessionsStore(defaults: defaults)
        store.upsert(OpenSessionRecord(
            cwd: "/tmp", sessionID: "sid", callsign: "K9",
            agentTypeID: "bash", restoreCommand: "k9s"))
        XCTAssertEqual(store.all().first?.restoreCommand, "k9s")

        // Structural upsert omits restoreCommand — must keep the snapped TUI.
        store.upsert(OpenSessionRecord(
            cwd: "/tmp", sessionID: "sid", callsign: "K9", agentTypeID: "bash"))
        XCTAssertEqual(store.all().first?.restoreCommand, "k9s")

        store.setRestoreCommand(sessionID: "sid", command: nil)
        XCTAssertNil(store.all().first?.restoreCommand)
    }
}
