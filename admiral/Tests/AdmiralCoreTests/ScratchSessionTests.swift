import XCTest
@testable import AdmiralCore

@MainActor
final class ScratchSessionTests: XCTestCase {
    private func tempDefaults() -> UserDefaults { UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")! }

    private func manager(_ store: OpenSessionsStore) -> SessionManager {
        SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/usr/bin/claude",
            appearanceStore: SessionAppearanceStore(defaults: tempDefaults()),
            openSessionsStore: store
        )
    }

    func testScratchCommissionSkipsRestoreRecordAndSelection() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        let m = manager(store)
        let anchor = m.commission(callsign: "anchor", cwd: "/a")
        let scratch = m.commission(callsign: "quirky_otter", cwd: "/b", scratch: true)
        XCTAssertTrue(scratch.scratch)
        XCTAssertEqual(store.all().map(\.callsign), ["anchor"], "scratch tabs are never restorable")
        XCTAssertEqual(m.selectedID, anchor.id, "a scratch tab must not steal focus")
    }

    /// ⌘S promotes the selected tab, and only a scratch one: the Session menu item and the ⌘/
    /// palette row both ask this, so neither offers to promote a regular tab.
    func testOnlyASelectedScratchTabIsPromotable() {
        let m = manager(OpenSessionsStore(defaults: tempDefaults()))
        let regular = m.commission(callsign: "anchor", cwd: "/a")
        let scratch = m.commission(callsign: "quirky_otter", cwd: "/b", scratch: true)
        m.selectedID = regular.id
        XCTAssertNil(m.selectedScratchTab)
        m.selectedID = scratch.id
        XCTAssertEqual(m.selectedScratchTab?.id, scratch.id)
        m.selectedID = nil
        XCTAssertNil(m.selectedScratchTab)
        m.selectedID = scratch.id
        m.promote(scratch.id)
        XCTAssertNil(m.selectedScratchTab, "once promoted it is a regular tab")
    }

    func testPromoteFlipsFlagAndPersists() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        let m = manager(store)
        let scratch = m.commission(callsign: "quirky_otter", cwd: "/b", scratch: true)
        m.promote(scratch.id)
        XCTAssertEqual(m.sessions.first?.scratch, false)
        XCTAssertEqual(store.all().map(\.callsign), ["quirky_otter"], "promotion makes it restorable")
        m.promote(scratch.id)  // idempotent: second promote is a no-op
        XCTAssertEqual(store.all().count, 1)
    }

    func testSetTeamOnScratchDoesNotCreateRestoreRecord() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        let m = manager(store)
        let scratch = m.commission(callsign: "t", cwd: "/b", scratch: true)
        m.setTeam(scratch.id, team: "alpha")
        XCTAssertTrue(store.all().isEmpty, "setTeam's upsert must respect the scratch gate")
    }

    func testReloadCarriesScratchForward() {
        let store = OpenSessionsStore(defaults: tempDefaults())
        let m = manager(store)
        let scratch = m.commission(callsign: "t", cwd: "/tmp", scratch: true)
        let fresh = m.reload(scratch.id)
        XCTAssertEqual(fresh?.scratch, true)
        XCTAssertTrue(store.all().isEmpty)
    }
}
