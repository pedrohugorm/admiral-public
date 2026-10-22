import XCTest
@testable import AdmiralCore

final class PRWatchStoreTests: XCTestCase {
    private var base: URL!
    private var store: PRWatchStore!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("prwatch-store-\(UUID().uuidString)")
        store = PRWatchStore(base: base)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func state() -> PRWatchState {
        var state = PRWatchState()
        let digest = PRDigest(number: 7, title: "t", url: "u", state: .mergeable,
                              checks: .passed, approvals: 1)
        state.repos["/a"] = [digest]
        state.announced[PRWatchState.key(root: "/a", number: 7)] = digest
        state.checkedAt = Date(timeIntervalSince1970: 100)
        return state
    }

    func testRoundTrip() {
        store.set(state(), forSession: "sid-1")
        XCTAssertEqual(store.state(forSession: "sid-1"), state())
    }

    func testSessionsAreIsolatedAndUnknownIsNil() {
        store.set(state(), forSession: "sid-1")
        XCTAssertNil(store.state(forSession: "sid-2"))
    }

    func testNilRemovesTheFile() {
        store.set(state(), forSession: "sid-1")
        store.set(nil, forSession: "sid-1")
        XCTAssertNil(store.state(forSession: "sid-1"))
    }

    /// A session id arrives from a hook payload — it must not be able to escape the directory.
    func testPathIsUnderPRWatchAndSanitized() {
        let url = AdmiralPaths.prWatchFile(base: base, session: "../../etc/passwd")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "pr-watch")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }
}
