import Foundation

/// A parsed cron schedule.
///
/// Matches the classic five-field `cron(5)` layout with minute, hour,
/// day-of-month, month, and day-of-week fields. Fields accept `*`, `*/step`,
/// `a-b`, `a-b/step`, and comma-separated lists of those. Day-of-week 0 and 7
/// both mean Sunday.
struct CronSchedule: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        let values: Set<Int>
        let step: Int
        let hasStep: Bool

        func matches(_ value: Int) -> Bool {
            values.contains(value)
        }
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case wrongFieldCount
        case invalidExpression(String)
        case outOfRange(String)

        var description: String {
            switch self {
            case .wrongFieldCount:
                return "a cron schedule must have exactly 5 fields"
            case let .invalidExpression(expression):
                return "invalid cron expression '\(expression)'"
            case let .outOfRange(field):
                return "cron value out of range in field '\(field)'"
            }
        }
    }

    let minute: Field
    let hour: Field
    let dayOfMonth: Field
    let month: Field
    let dayOfWeek: Field

    let raw: String

    static func parse(_ expression: String) throws -> CronSchedule {
        let whitespace = expression.split(whereSeparator: {
            $0 == " " || $0 == "\t"
        })
        guard whitespace.count == 5 else {
            throw ParseError.wrongFieldCount
        }
        let parts = whitespace.map(String.init)
        return CronSchedule(
            minute: try parseField(parts[0], range: 0...59, allowNames: false),
            hour: try parseField(parts[1], range: 0...23, allowNames: false),
            dayOfMonth: try parseField(parts[2], range: 1...31, allowNames: false),
            month: try parseField(parts[3], range: 1...12, allowNames: true),
            dayOfWeek: try parseField(parts[4], range: 0...7, allowNames: true),
            raw: expression
        )
    }

    private static let monthNames: [String: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
        "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
    ]
    private static let weekNames: [String: Int] = [
        "SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6,
    ]

    private static func expandToken(
        _ token: String,
        range: ClosedRange<Int>,
        names: [String: Int]
    ) throws -> (values: Set<Int>, step: Int) {
        // `*` and `*/step`
        if token == "*" {
            return (Set(range), 1)
        }
        if token.hasPrefix("*/") {
            guard let step = Int(token.dropFirst(2)), step > 0 else {
                throw ParseError.invalidExpression(token)
            }
            let values = Set(stride(from: range.lowerBound, through: range.upperBound, by: step))
            return (values, step)
        }

        // name
        if let name = names[token.uppercased()] {
            return ([name], 1)
        }

        // range, range/step, or bare value
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else {
            throw ParseError.invalidExpression(token)
        }
        let base = String(parts[0])
        let step: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed > 0 else {
                throw ParseError.invalidExpression(token)
            }
            step = parsed
        } else {
            step = 1
        }

        if let value = number(base, names: names) {
            guard range.contains(value) else {
                throw ParseError.outOfRange(token)
            }
            return ([value], step)
        }

        // A range, whose bounds may themselves be names (`MON-FRI`,
        // `JAN-MAR`) as well as numbers (`1-5`).
        let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
        if bounds.count == 2,
           let lower = number(String(bounds[0]), names: names),
           let upper = number(String(bounds[1]), names: names) {
            guard range.contains(lower), range.contains(upper) else {
                throw ParseError.outOfRange(token)
            }
            guard lower <= upper else {
                throw ParseError.invalidExpression(token)
            }
            var values: Set<Int> = []
            for value in stride(from: lower, through: upper, by: step) {
                values.insert(value)
            }
            return (values, step)
        }

        throw ParseError.invalidExpression(token)
    }

    /// Resolves one bound, accepting either a number or a three-letter name.
    private static func number(_ token: String, names: [String: Int]) -> Int? {
        Int(token) ?? names[token.uppercased()]
    }

    private static func parseField(
        _ expression: String,
        range: ClosedRange<Int>,
        allowNames: Bool
    ) throws -> Field {
        let names: [String: Int]
        if range == 1...12 {
            names = allowNames ? monthNames : [:]
        } else if range == 0...7 {
            names = allowNames ? weekNames : [:]
        } else {
            names = [:]
        }
        var values: Set<Int> = []
        var step = 1
        var hasStep = false
        for rawToken in expression.split(separator: ",") {
            let token = String(rawToken)
            let expanded = try expandToken(token, range: range, names: names)
            values.formUnion(expanded.values)
            if expanded.step != 1 {
                hasStep = true
                step = expanded.step
            }
        }
        return Field(values: values, step: step, hasStep: hasStep)
    }

    /// The next fire time strictly after `date`, or `nil` if none can be
    /// computed (no possible combination within a reasonable horizon).
    ///
    /// A field whose value always uses the same step honours that step so the
    /// search never revisits a missed slot; combined step semantics across
    /// fields still rely on the bounded calendar scan below.
    func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        // Scan minute by minute for up to five years; a broken schedule
        // (e.g. Feb 30) resolves to nil instead of spinning forever.
        let horizon = calendar.date(byAdding: .year, value: 5, to: date) ?? date
        var cursor = calendar.date(byAdding: .minute, value: 1, to: date) ?? date
        var guardCount = 0
        let maxIterations = 5 * 366 * 24 * 60 + 1
        while cursor <= horizon, guardCount < maxIterations {
            guardCount += 1
            if matches(cursor, calendar: calendar) {
                return cursor
            }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: cursor) else {
                return nil
            }
            cursor = next
        }
        return nil
    }

    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday],
            from: date
        )
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday else {
            return false
        }
        let normalizedWeekday = weekday - 1 // .current: Sunday == 1 -> 0
        let dayOfMonthMatches = dayOfMonth.matches(day)
        let dayOfWeekMatches = dayOfWeek.matches(normalizedWeekday)
            || (dayOfWeek.matches(7) && normalizedWeekday == 0)

        // Standard cron day-selection rule: when one day field is `*`, only
        // the other matters; when both are restricted, either may match.
        let dayOfMonthEvery = isEveryDayOfMonth
        let dayOfWeekEvery = isEveryDayOfWeek
        let dayMatches: Bool
        if dayOfMonthEvery && dayOfWeekEvery {
            dayMatches = true
        } else if dayOfMonthEvery {
            dayMatches = dayOfWeekMatches
        } else if dayOfWeekEvery {
            dayMatches = dayOfMonthMatches
        } else {
            dayMatches = dayOfMonthMatches || dayOfWeekMatches
        }

        return self.minute.matches(minute)
            && self.hour.matches(hour)
            && dayMatches
            && self.month.matches(month)
    }

    /// Whether the day-of-month field matches every possible day.
    private var isEveryDayOfMonth: Bool {
        dayOfMonth.values.count == 31
    }

    /// Whether the day-of-week field matches every possible weekday,
    /// recognising that `7` is an alias for Sunday (`0`).
    private var isEveryDayOfWeek: Bool {
        (0...6).allSatisfy { dayOfWeek.matches($0) }
    }
}
