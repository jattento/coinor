import Foundation

/// Compiles a cron expression into launchd `StartCalendarInterval` entries.
///
/// launchd is macOS's native scheduler and is what actually fires an
/// automation: it starts a job at a calendar interval, and — unlike `cron` —
/// it runs a job that was missed while the machine was asleep or off, folding
/// several missed occurrences into a single run. That coalescing *is* Conan
/// Code's catch-up contract ("at most one run for a missed window"), so the
/// behaviour belongs to the OS rather than to a resident process.
///
/// `StartCalendarInterval` understands only fixed values per field (a missing
/// key means "every"), so ranges, lists and steps are expanded into the
/// cartesian product of the fields that are actually constrained. A wildcard
/// field is simply omitted, which is what keeps the common schedules small:
/// `0 9 * * *` is one entry, not 365.
enum CronLaunchdCompiler {
    /// One `StartCalendarInterval` dictionary. A `nil` field means "every",
    /// and is omitted from the emitted plist.
    struct Interval: Equatable, Sendable {
        var minute: Int?
        var hour: Int?
        var day: Int?
        var month: Int?
        var weekday: Int?

        /// The plist representation, omitting every wildcard field.
        var plistValue: [String: Int] {
            var value: [String: Int] = [:]
            if let minute { value["Minute"] = minute }
            if let hour { value["Hour"] = hour }
            if let day { value["Day"] = day }
            if let month { value["Month"] = month }
            if let weekday { value["Weekday"] = weekday }
            return value
        }
    }

    enum CompileError: Error, Equatable, CustomStringConvertible {
        /// The schedule is valid cron but expands to more calendar entries
        /// than launchd should reasonably be given.
        case tooManyIntervals(count: Int, limit: Int)

        var description: String {
            switch self {
            case let .tooManyIntervals(count, limit):
                return "this schedule expands to \(count) launchd entries "
                    + "(limit \(limit)); use a coarser schedule"
            }
        }
    }

    /// Upper bound on the expansion. A schedule this large is almost always a
    /// mistake, and launchd would be handed an unwieldy plist.
    static let intervalLimit = 750

    /// Compiles a parsed schedule into the entries launchd should fire on.
    static func intervals(for schedule: CronSchedule) throws -> [Interval] {
        // A field that matches every legal value is a wildcard: omitting it is
        // both smaller and exactly equivalent.
        let minutes = constrained(schedule.minute, fullRange: 0...59)
        let hours = constrained(schedule.hour, fullRange: 0...23)
        let days = constrained(schedule.dayOfMonth, fullRange: 1...31)
        let months = constrained(schedule.month, fullRange: 1...12)
        let weekdays = weekdayValues(schedule.dayOfWeek)

        let count = (minutes?.count ?? 1)
            * (hours?.count ?? 1)
            * (days?.count ?? 1)
            * (months?.count ?? 1)
            * (weekdays?.count ?? 1)
        guard count <= intervalLimit else {
            throw CompileError.tooManyIntervals(count: count, limit: intervalLimit)
        }

        var intervals: [Interval] = []
        for month in months ?? [nil] {
            for day in days ?? [nil] {
                for weekday in weekdays ?? [nil] {
                    for hour in hours ?? [nil] {
                        for minute in minutes ?? [nil] {
                            intervals.append(
                                Interval(
                                    minute: minute,
                                    hour: hour,
                                    day: day,
                                    month: month,
                                    weekday: weekday
                                )
                            )
                        }
                    }
                }
            }
        }
        return intervals
    }

    /// The sorted values of a constrained field, or `nil` when the field
    /// matches everything and should be omitted.
    private static func constrained(
        _ field: CronSchedule.Field,
        fullRange: ClosedRange<Int>
    ) -> [Int?]? {
        let full = Set(fullRange)
        let values = field.values.intersection(full)
        if values == full { return nil }
        return values.sorted().map { Optional($0) }
    }

    /// launchd's `Weekday` uses 0/7 for Sunday just like cron, so the values
    /// carry over; 7 is normalised to 0 to avoid emitting a duplicate Sunday.
    private static func weekdayValues(_ field: CronSchedule.Field) -> [Int?]? {
        var values = field.values
        if values.contains(7) {
            values.remove(7)
            values.insert(0)
        }
        let full = Set(0...6)
        let constrained = values.intersection(full)
        if constrained == full { return nil }
        return constrained.sorted().map { Optional($0) }
    }
}
