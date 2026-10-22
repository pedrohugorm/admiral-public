import XCTest
@testable import AdmiralCore

/// Two Admirals on one support folder (a dev build beside the installed app) must not both run
/// its schedules, or every run opens twice.
final class SchedulerLockTests: XCTestCase {
    func testOnlyOneHolderAtATime() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        var first = SchedulerLock(base: base)
        XCTAssertNotNil(first)
        XCTAssertNil(SchedulerLock(base: base), "a second instance gets no lock")
        first = nil
        XCTAssertNotNil(SchedulerLock(base: base), "released when the holder goes away")
    }

    func testTheLockFileIsNotTakenForASchedule() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let lock = SchedulerLock(base: base)
        XCTAssertNotNil(lock)
        XCTAssertEqual(ScheduleStore(base: base).all(), [])
    }
}
