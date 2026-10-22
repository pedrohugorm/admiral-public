import Foundation

/// A cron schedule: five fields — minute, hour, day of month, month, day of week — or one of
/// `@hourly`, `@daily` (`@midnight`), `@weekly`, `@monthly`, `@yearly` (`@annually`).
///
/// Fields take `*`, a number, a range `a-b`, a step `*/n`, `a-b/n` or `a/n`, and comma lists;
/// months and weekdays also take names (`JAN`, `MON`), and weekday 7 is Sunday like 0. When
/// both day fields are restricted (neither starts with `*`), a day matches on either one, as in
/// standard cron. Times are read in the calendar's time zone, the Mac's own by default.
public struct CronExpression: Equatable, Sendable {
    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The five fields, shortcuts expanded.
    public let fields: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    /// 0 = Sunday.
    let weekdays: Set<Int>
    let dayRestricted: Bool
    let weekdayRestricted: Bool

    static let shortcuts = [
        "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
    ]
    static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                             "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    static let weekdayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
    /// The summary is English whatever the Mac's locale, like the rest of Admiral's text.
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var expanded = trimmed
        if trimmed.hasPrefix("@") {
            guard let shortcut = Self.shortcuts[trimmed.lowercased()] else {
                throw ParseError(description: "unknown shortcut '\(trimmed)' — use @hourly, @daily, "
                    + "@weekly, @monthly or @yearly")
            }
            expanded = shortcut
        }
        let parts = expanded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else {
            throw ParseError(description: "a cron needs five fields (minute hour day-of-month month "
                + "day-of-week), got \(parts.count)")
        }
        fields = parts.joined(separator: " ")
        minutes = try Self.field(parts[0], "minute", 0...59)
        hours = try Self.field(parts[1], "hour", 0...23)
        days = try Self.field(parts[2], "day of month", 1...31)
        months = try Self.field(parts[3], "month", 1...12, names: Self.monthNames)
        weekdays = Set(try Self.field(parts[4], "day of week", 0...7, names: Self.weekdayNames).map { $0 % 7 })
        dayRestricted = !parts[2].hasPrefix("*")
        weekdayRestricted = !parts[4].hasPrefix("*")
    }

    /// The first time after `date` the cron fires, or nil when it never does (`0 0 30 2 *`).
    ///
    /// Walks day by day, building each candidate from wall-clock fields. A time skipped by a
    /// spring-forward jump comes back from the calendar moved past the jump, so it still runs
    /// that day, once; a time repeated by a fall-back comes back as its first occurrence, so
    /// it runs once too.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        let times = hours.sorted().flatMap { h in minutes.sorted().map { (h, $0) } }
        // Eight years covers a Feb 29 that must also fall on a given weekday.
        for offset in 0...(366 * 8) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = c.year, let month = c.month, let dom = c.day, let weekday = c.weekday,
                  months.contains(month), matches(day: dom, weekday: weekday - 1) else { continue }
            var best: Date?
            var bestHour = 0
            for (hour, minute) in times {
                // A moved (spring-forward) candidate lands at most an hour later on the wall
                // clock, so nothing past that can beat the best found so far.
                if best != nil, hour > bestHour + 1 { break }
                guard let candidate = calendar.date(from: DateComponents(
                    year: year, month: month, day: dom, hour: hour, minute: minute)),
                      candidate > date, best.map({ candidate < $0 }) ?? true else { continue }
                best = candidate
                bestHour = hour
            }
            if let best { return best }
        }
        return nil
    }

    /// The schedule in words, for the common shapes; anything else reads as the cron itself.
    public var summary: String {
        let parts = fields.split(separator: " ").map(String.init)
        let everyDay = !dayRestricted && !weekdayRestricted && months.count == 12
        let time = minutes.count == 1 && hours.count == 1
            ? "\(hours.first!):" + String(format: "%02d", minutes.first!) : nil
        if everyDay, parts[1] == "*" {
            if parts[0] == "*" { return "Every minute" }
            if parts[0].hasPrefix("*/"), let n = Int(parts[0].dropFirst(2)) { return "Every \(n) minutes" }
            if minutes == [0] { return "Every hour" }
        }
        guard let time else { return "Cron \(fields)" }
        if everyDay { return "Every day at \(time)" }
        if !dayRestricted, months.count == 12 {
            if weekdays == Set(1...5) { return "Weekdays at \(time)" }
            if weekdays.count == 1, let wd = weekdays.first { return "\(Self.dayNames[wd])s at \(time)" }
        }
        if !weekdayRestricted, months.count == 12, days.count == 1 {
            return "Day \(days.first!) of every month at \(time)"
        }
        return "Cron \(fields)"
    }

    func matches(day: Int, weekday: Int) -> Bool {
        dayRestricted && weekdayRestricted
            ? days.contains(day) || weekdays.contains(weekday)
            : days.contains(day) && weekdays.contains(weekday)
    }

    static func field(_ text: String, _ name: String, _ range: ClosedRange<Int>,
                      names: [String: Int] = [:]) throws -> Set<Int> {
        func value<S: StringProtocol>(_ raw: S) throws -> Int {
            guard let v = Int(raw) ?? names[raw.lowercased()] else {
                throw ParseError(description: "\(name): '\(raw)' is not a number" + (names.isEmpty ? "" : " or a name"))
            }
            guard range.contains(v) else {
                throw ParseError(description: "\(name) \(v) is out of range \(range.lowerBound)–\(range.upperBound)")
            }
            return v
        }
        var values = Set<Int>()
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = item.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2, !pieces[0].isEmpty else {
                throw ParseError(description: "\(name): can't read '\(item)'")
            }
            var step = 1
            if pieces.count == 2 {
                guard let s = Int(pieces[1]), s > 0 else {
                    throw ParseError(description: "\(name): the step in '\(item)' must be a positive number")
                }
                step = s
            }
            let base = pieces[0]
            let lower: Int, upper: Int
            if base == "*" {
                (lower, upper) = (range.lowerBound, range.upperBound)
            } else if let dash = base.firstIndex(of: "-") {
                (lower, upper) = (try value(base[..<dash]), try value(base[base.index(after: dash)...]))
                guard lower <= upper else { throw ParseError(description: "\(name): '\(base)' runs backwards") }
            } else {
                lower = try value(base)
                upper = pieces.count == 2 ? range.upperBound : lower
            }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values
    }
}
