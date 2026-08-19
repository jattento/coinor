import Foundation

/// A schedule expressed the way a person describes it, rather than as cron.
///
/// The editor works in these terms and cron stays the storage format, so the
/// scheduling contract (and everything launchd is handed) is unchanged. Any
/// expression Conan Code cannot describe in friendly terms round-trips through
/// `.custom`, so a hand-written schedule is never silently rewritten.
enum AutomationRecurrence: Equatable, Sendable {
    /// Every N minutes, on the hour boundary: `*/N * * * *`.
    case everyMinutes(Int)
    /// Every hour at a given minute: `M * * * *`.
    case hourly(minute: Int)
    /// Every day at a given time: `M H * * *`.
    case daily(hour: Int, minute: Int)
    /// On chosen weekdays at a given time: `M H * * d,d`. Weekdays are cron's
    /// 0-6, Sunday first.
    case weekly(weekdays: Set<Int>, hour: Int, minute: Int)
    /// On a day of the month at a given time: `M H D * *`.
    case monthly(day: Int, hour: Int, minute: Int)
    /// Anything else, kept verbatim.
    case custom(String)

    /// The intervals offered for `everyMinutes`, chosen so each divides an
    /// hour evenly and the schedule stays aligned across hours.
    static let minuteIntervals = [5, 10, 15, 20, 30]

    // MARK: - To cron

    var cronExpression: String {
        switch self {
        case let .everyMinutes(interval):
            return "*/\(interval) * * * *"
        case let .hourly(minute):
            return "\(minute) * * * *"
        case let .daily(hour, minute):
            return "\(minute) \(hour) * * *"
        case let .weekly(weekdays, hour, minute):
            let days = weekdays.sorted().map(String.init).joined(separator: ",")
            return "\(minute) \(hour) * * \(days.isEmpty ? "*" : days)"
        case let .monthly(day, hour, minute):
            return "\(minute) \(hour) \(day) * *"
        case let .custom(expression):
            return expression
        }
    }

    // MARK: - From cron

    /// Recognises the shapes the editor can present. Anything else becomes
    /// `.custom`, which keeps the original text intact.
    static func parse(_ expression: String) -> AutomationRecurrence {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard fields.count == 5 else { return .custom(expression) }

        let (minute, hour, day, month, weekday) =
            (fields[0], fields[1], fields[2], fields[3], fields[4])

        // Only unrestricted months are describable in friendly terms.
        guard month == "*" else { return .custom(expression) }

        // Every N minutes.
        if minute.hasPrefix("*/"), hour == "*", day == "*", weekday == "*",
           let interval = Int(minute.dropFirst(2)),
           minuteIntervals.contains(interval) {
            return .everyMinutes(interval)
        }

        guard let minuteValue = Int(minute), (0...59).contains(minuteValue) else {
            return .custom(expression)
        }

        // Hourly at a fixed minute.
        if hour == "*", day == "*", weekday == "*" {
            return .hourly(minute: minuteValue)
        }

        guard let hourValue = Int(hour), (0...23).contains(hourValue) else {
            return .custom(expression)
        }

        // Daily.
        if day == "*", weekday == "*" {
            return .daily(hour: hourValue, minute: minuteValue)
        }

        // Weekly on an explicit list of days.
        if day == "*", weekday != "*" {
            let days = weekday.split(separator: ",").map(String.init)
            var values: Set<Int> = []
            for token in days {
                guard let value = Int(token), (0...7).contains(value) else {
                    return .custom(expression)
                }
                values.insert(value == 7 ? 0 : value)
            }
            guard !values.isEmpty else { return .custom(expression) }
            return .weekly(weekdays: values, hour: hourValue, minute: minuteValue)
        }

        // Monthly on a fixed day.
        if weekday == "*", let dayValue = Int(day), (1...31).contains(dayValue) {
            return .monthly(day: dayValue, hour: hourValue, minute: minuteValue)
        }

        return .custom(expression)
    }

    // MARK: - Display

    /// Which editor mode this recurrence belongs to.
    var kind: Kind {
        switch self {
        case .everyMinutes: .everyMinutes
        case .hourly: .hourly
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .custom: .custom
        }
    }

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case everyMinutes
        case hourly
        case daily
        case weekly
        case monthly
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyMinutes: "Every few minutes"
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .custom: "Custom (cron)"
            }
        }
    }

    /// A default for each mode, used when the user switches modes.
    static func `default`(for kind: Kind, from current: AutomationRecurrence) -> AutomationRecurrence {
        // Carry the time across mode switches so changing "Daily" to "Weekly"
        // does not silently reset the hour the user already picked.
        let (hour, minute) = current.timeOfDay ?? (9, 0)
        switch kind {
        case .everyMinutes: return .everyMinutes(15)
        case .hourly: return .hourly(minute: minute)
        case .daily: return .daily(hour: hour, minute: minute)
        case .weekly: return .weekly(weekdays: [1, 2, 3, 4, 5], hour: hour, minute: minute)
        case .monthly: return .monthly(day: 1, hour: hour, minute: minute)
        case .custom: return .custom(current.cronExpression)
        }
    }

    var timeOfDay: (hour: Int, minute: Int)? {
        switch self {
        case let .daily(hour, minute): (hour, minute)
        case let .weekly(_, hour, minute): (hour, minute)
        case let .monthly(_, hour, minute): (hour, minute)
        case let .hourly(minute): (9, minute)
        case .everyMinutes, .custom: nil
        }
    }

    /// Weekday names in cron order, Sunday first.
    static let weekdayNames = [
        "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
    ]

    /// A one-line description of when this runs, for the editor and the list.
    var summary: String {
        switch self {
        case let .everyMinutes(interval):
            return "Every \(interval) minutes"
        case let .hourly(minute):
            return "Every hour at :\(String(format: "%02d", minute))"
        case let .daily(hour, minute):
            return "Every day at \(Self.time(hour, minute))"
        case let .weekly(weekdays, hour, minute):
            let sorted = weekdays.sorted()
            let names: String
            if sorted == [1, 2, 3, 4, 5] {
                names = "every weekday"
            } else if sorted == [0, 6] {
                names = "on weekends"
            } else if sorted.count == 7 {
                names = "every day"
            } else {
                names = "on " + sorted
                    .map { Self.weekdayNames[$0] }
                    .joined(separator: ", ")
            }
            return "\(names.prefix(1).uppercased())\(names.dropFirst()) at \(Self.time(hour, minute))"
        case let .monthly(day, hour, minute):
            return "Monthly on day \(day) at \(Self.time(hour, minute))"
        case let .custom(expression):
            return expression
        }
    }

    private static func time(_ hour: Int, _ minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
