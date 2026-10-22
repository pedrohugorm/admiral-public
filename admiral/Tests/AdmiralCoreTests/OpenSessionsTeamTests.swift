import XCTest
@testable import AdmiralCore

final class OpenSessionsTeamTests: XCTestCase {
    func testTeamRoundTrips() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = OpenSessionsStore(defaults: defaults)
        store.upsert(OpenSessionRecord(cwd: "/w", sessionID: "s", callsign: "c", teamName: "platform"))
        XCTAssertEqual(store.all().first?.teamName, "platform")
    }

    func testLegacyRecordDecodesWithNilTeam() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // Simulate a record persisted before teamName existed.
        let legacy = #"[{"cwd":"/w","sessionID":"s","callsign":"c"}]"#
        defaults.set(Data(legacy.utf8), forKey: "admiral.openSessions.v1")
        XCTAssertNil(OpenSessionsStore(defaults: defaults).all().first?.teamName)
    }

    func testAgentTypeIDRoundTripAndLegacyNil() {
        let defaults = UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
        let store = OpenSessionsStore(defaults: defaults)
        store.upsert(OpenSessionRecord(
            cwd: "/w", sessionID: "s", callsign: "c", agentTypeID: "bash"))
        XCTAssertEqual(store.all().first?.agentTypeID, "bash")
        XCTAssertTrue(store.all().first?.isBash == true)

        // Legacy payload without agentTypeID still decodes as Claude (not bash).
        let legacy = #"[{"cwd":"/x","sessionID":"y","callsign":"z"}]"#.data(using: .utf8)!
        defaults.set(legacy, forKey: "admiral.openSessions.v1")
        let decoded = OpenSessionsStore(defaults: defaults).all()
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].agentTypeID)
        XCTAssertFalse(decoded[0].isBash)
    }
}
