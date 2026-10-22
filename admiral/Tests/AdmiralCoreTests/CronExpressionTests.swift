import XCTest
@testable import AdmiralCore

/// Five-field cron (minute hour day-of-month month day-of-week) and the @-shortcuts, read in
/// the Mac's local time.
final class CronExpressionTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func next(_ cron: String, after: Date) throws -> Date? {
        try CronExpression(cron).next(after: after, calendar: calendar)
    }

    func testEveryMinuteIsTheNextWholeMinute() throws {
        XCTAssertEqual(try next("* * * * *", after: date(2026, 10, 2, 10, 0, 30)), date(2026, 10, 2, 10, 1))
        XCTAssertEqual(try next("* * * * *", after: date(2026, 10, 2, 10, 1)), date(2026, 10, 2, 10, 2))
    }

    func testSteps() throws {
        XCTAssertEqual(try next("*/15 * * * *", after: date(2026, 10, 2, 10, 7)), date(2026, 10, 2, 10, 15))
        XCTAssertEqual(try next("10-40/10 * * * *", after: date(2026, 10, 2, 10, 41)), date(2026, 10, 2, 11, 10))
    }

    func testDailyMovesToTomorrowOnceTodaysTimeHasPassed() throws {
        XCTAssertEqual(try next("30 9 * * *", after: date(2026, 10, 2, 9, 30)), date(2026, 10, 3, 9, 30))
        XCTAssertEqual(try next("30 9 * * *", after: date(2026, 10, 2, 9, 29)), date(2026, 10, 2, 9, 30))
    }

    func testWeekdaysSkipTheWeekend() throws {
        // 2026-10-02 is a Friday.
        XCTAssertEqual(try next("0 9 * * 1-5", after: date(2026, 10, 2, 10)), date(2026, 10, 5, 9))
    }

    func testADayMissingFromAMonthIsSkipped() throws {
        XCTAssertEqual(try next("0 0 31 * *", after: date(2026, 9, 1)), date(2026, 10, 31))
        XCTAssertEqual(try next("0 0 29 2 *", after: date(2026, 3, 1)), date(2028, 2, 29))
    }

    /// With both restricted, a day matches on either (standard cron).
    func testDayOfMonthOrWeekday() throws {
        // The 13th, or any Friday: after Thu 2026-10-08 comes Fri 10-09, then Tue 10-13.
        XCTAssertEqual(try next("0 0 13 * 5", after: date(2026, 10, 8)), date(2026, 10, 9))
        XCTAssertEqual(try next("0 0 13 * 5", after: date(2026, 10, 9)), date(2026, 10, 13))
    }

    func testSundayIsZeroOrSevenAndNamesWork() throws {
        XCTAssertEqual(try next("0 0 * * 7", after: date(2026, 10, 2)), try next("0 0 * * 0", after: date(2026, 10, 2)))
        XCTAssertEqual(try next("0 0 * * SUN", after: date(2026, 10, 2)), date(2026, 10, 4))
        XCTAssertEqual(try next("0 0 1 jan *", after: date(2026, 10, 2)), date(2027, 1, 1))
    }

    func testShortcuts() throws {
        let after = date(2026, 10, 2, 10, 20)
        XCTAssertEqual(try next("@hourly", after: after), date(2026, 10, 2, 11))
        XCTAssertEqual(try next("@daily", after: after), date(2026, 10, 3))
        XCTAssertEqual(try next("@weekly", after: after), date(2026, 10, 4))
        XCTAssertEqual(try next("@monthly", after: after), date(2026, 11, 1))
        XCTAssertEqual(try next("@yearly", after: after), date(2027, 1, 1))
    }

    /// 2026-03-08 02:00 PST jumps to 03:00 PDT: 02:30 does not exist that day, so the run
    /// lands right after the jump, once.
    func testATimeSkippedBySpringForwardRunsAfterTheJump() throws {
        let fire = try XCTUnwrap(try next("30 2 * * *", after: date(2026, 3, 7, 12)))
        XCTAssertEqual(calendar.component(.day, from: fire), 8)
        XCTAssertEqual(calendar.component(.hour, from: fire), 3)
        XCTAssertEqual(try next("30 2 * * *", after: fire), date(2026, 3, 9, 2, 30))
    }

    /// 2026-11-01 02:00 PDT falls back to 01:00 PST: 01:30 happens twice, the run once.
    func testATimeRepeatedByFallBackRunsOnce() throws {
        let first = try XCTUnwrap(try next("30 1 * * *", after: date(2026, 10, 31, 12)))
        XCTAssertEqual(calendar.component(.day, from: first), 1)
        XCTAssertEqual(try next("30 1 * * *", after: first), date(2026, 11, 2, 1, 30))
    }

    func testACronThatNeverFiresHasNoNextTime() throws {
        XCTAssertNil(try next("0 0 30 2 *", after: date(2026, 10, 2)))
    }

    func testBadCronsAreRefusedWithTheReason() {
        for (cron, reason) in [("* * * *", "five fields"), ("60 * * * *", "minute"), ("* 24 * * *", "hour"),
                               ("* * 0 * *", "day of month"), ("* * * 13 *", "month"), ("* * * * 8", "day of week"),
                               ("*/0 * * * *", "step"), ("* * * FOO *", "month"), ("@sometimes", "@")] {
            XCTAssertThrowsError(try CronExpression(cron), cron) { error in
                XCTAssertTrue(String(describing: error).contains(reason), "\(cron): \(error)")
            }
        }
    }

    func testPlainEnglish() throws {
        XCTAssertEqual(try CronExpression("* * * * *").summary, "Every minute")
        XCTAssertEqual(try CronExpression("*/5 * * * *").summary, "Every 5 minutes")
        XCTAssertEqual(try CronExpression("0 * * * *").summary, "Every hour")
        XCTAssertEqual(try CronExpression("@daily").summary, "Every day at 0:00")
        XCTAssertEqual(try CronExpression("30 9 * * *").summary, "Every day at 9:30")
        XCTAssertEqual(try CronExpression("0 9 * * 1-5").summary, "Weekdays at 9:00")
        XCTAssertEqual(try CronExpression("15 8 * * 1").summary, "Mondays at 8:15")
        XCTAssertEqual(try CronExpression("0 0 1 * *").summary, "Day 1 of every month at 0:00")
        XCTAssertEqual(try CronExpression("5 4 3 2 *").summary, "Cron 5 4 3 2 *")
    }
}
