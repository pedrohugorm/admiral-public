import XCTest
@testable import AdmiralCore

/// Schedules are one plain file each under `<supportDir>/schedules/`; a schedule's runs are an
/// append-only index next to it.
final class ScheduleStoreTests: XCTestCase {
    private var base: URL!
    private var store: ScheduleStore!

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("schedules-\(UUID().uuidString)")
        store = ScheduleStore(base: base)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func schedule(_ name: String) -> Schedule {
        Schedule(name: name, cron: "0 9 * * *", cwd: "/tmp", prompt: "report", lastFire: Date(timeIntervalSince1970: 0))
    }

    func testASavedScheduleIsAPlainFileNamedByItsId() throws {
        let s = schedule("nightly")
        store.save(s)
        let file = base.appendingPathComponent("schedules/\(s.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store.all(), [s])
    }

    func testSchedulesListByName() {
        ["b", "a", "c"].forEach { store.save(schedule($0)) }
        XCTAssertEqual(store.all().map(\.name), ["a", "b", "c"])
    }

    func testARunIsReadBackAsItsLatestLine() {
        let s = schedule("nightly")
        store.save(s)
        var run = ScheduleRun(id: "r1", trigger: .cron, status: .running, startedAt: Date(timeIntervalSince1970: 10),
                              callsign: "nightly", sessionID: "sid-1")
        store.record(run, for: s.id)
        run.status = .succeeded
        run.endedAt = Date(timeIntervalSince1970: 20)
        store.record(run, for: s.id)
        XCTAssertEqual(store.runs(for: s.id), [run])
    }

    func testRunsAreNewestFirst() {
        let s = schedule("nightly")
        store.save(s)
        for i in 1...3 {
            store.record(ScheduleRun(id: "r\(i)", trigger: .cron, status: .succeeded,
                                     startedAt: Date(timeIntervalSince1970: Double(i))), for: s.id)
        }
        XCTAssertEqual(store.runs(for: s.id).map(\.id), ["r3", "r2", "r1"])
    }

    func testDeletingAScheduleTakesItsHistoryWithIt() {
        let s = schedule("nightly")
        store.save(s)
        store.record(ScheduleRun(id: "r1", trigger: .now, status: .skipped, startedAt: Date()), for: s.id)
        store.delete(s.id)
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(store.runs(for: s.id), [])
    }
}
