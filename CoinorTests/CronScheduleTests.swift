import Foundation
import Testing

@testable import Coinor

// MARK: - Parsing

@Test
func parsesAsteriskFields() throws {
    let schedule = try CronSchedule.parse("* * * * *")
    #expect(schedule.minute.matches(0))
    #expect(schedule.minute.matches(59))
    #expect(schedule.hour.matches(23))
    #expect(schedule.dayOfMonth.matches(1))
    #expect(schedule.dayOfMonth.matches(31))
    #expect(schedule.month.matches(12))
    #expect(schedule.dayOfWeek.matches(6))
}

@Test
func parsesBareValuesAndLists() throws {
    let schedule = try CronSchedule.parse("5,10 2 * * 1,3")
    #expect(schedule.minute.matches(5))
    #expect(schedule.minute.matches(10))
    #expect(!schedule.minute.matches(11))
    #expect(schedule.hour.matches(2))
    #expect(!schedule.hour.matches(3))
    #expect(schedule.dayOfWeek.matches(1))
    #expect(schedule.dayOfWeek.matches(3))
    #expect(!schedule.dayOfWeek.matches(5))
}

@Test
func parsesRangesWithAndWithoutStep() throws {
    let schedule = try CronSchedule.parse("15-30 9-17 * * *")
    #expect(schedule.minute.matches(15))
    #expect(schedule.minute.matches(30))
    #expect(!schedule.minute.matches(31))
    #expect(schedule.hour.matches(9))
    #expect(schedule.hour.matches(17))

    let stepped = try CronSchedule.parse("*/15 * * * *")
    #expect(stepped.minute.matches(0))
    #expect(stepped.minute.matches(15))
    #expect(stepped.minute.matches(45))
    #expect(!stepped.minute.matches(10))
}

@Test
func parsesMonthAndWeekdayNames() throws {
    let schedule = try CronSchedule.parse("0 9 * JAN MON-FRI")
    #expect(schedule.month.matches(1))
    #expect(!schedule.month.matches(2))
    #expect(schedule.dayOfWeek.matches(1)) // Mon
    #expect(schedule.dayOfWeek.matches(5)) // Fri
    #expect(!schedule.dayOfWeek.matches(6)) // Sat
}

@Test
func treatsDayOfWeekSevenAsSunday() throws {
    let calendar = calendar()
    let schedule = try CronSchedule.parse("0 0 * * 7")
    #expect(schedule.dayOfWeek.matches(7))
    // 2026-01-04 is a Sunday; 2026-01-05 is a Monday.
    #expect(schedule.matches(
        fixedDate(2026, 1, 4, 0, 0, calendar: calendar),
        calendar: calendar
    ))
    #expect(!schedule.matches(
        fixedDate(2026, 1, 5, 0, 0, calendar: calendar),
        calendar: calendar
    ))
}

@Test
func parsesNamedRanges() throws {
    // Weekday names as range bounds.
    let weekdays = try CronSchedule.parse("0 9 * * MON-FRI")
    for day in 1...5 {
        #expect(weekdays.dayOfWeek.matches(day))
    }
    #expect(!weekdays.dayOfWeek.matches(0)) // Sunday
    #expect(!weekdays.dayOfWeek.matches(6)) // Saturday

    // Month names as range bounds.
    let quarter = try CronSchedule.parse("0 0 1 JAN-MAR *")
    #expect(quarter.month.matches(1))
    #expect(quarter.month.matches(3))
    #expect(!quarter.month.matches(4))
}

@Test
func rejectsInvertedRange() {
    #expect(throws: CronSchedule.ParseError.invalidExpression("30-10")) {
        _ = try CronSchedule.parse("30-10 * * * *")
    }
}

@Test
func rejectsWrongFieldCount() {
    #expect(throws: CronSchedule.ParseError.wrongFieldCount) {
        _ = try CronSchedule.parse("* * * *")
    }
    #expect(throws: CronSchedule.ParseError.wrongFieldCount) {
        _ = try CronSchedule.parse("* * * * * *")
    }
}

@Test
func rejectsOutOfRangeValues() {
    #expect(throws: CronSchedule.ParseError.outOfRange("60")) {
        _ = try CronSchedule.parse("60 * * * *")
    }
    #expect(throws: CronSchedule.ParseError.outOfRange("24")) {
        _ = try CronSchedule.parse("* 24 * * *")
    }
    #expect(throws: CronSchedule.ParseError.outOfRange("32")) {
        _ = try CronSchedule.parse("* * 32 * *")
    }
}

@Test
func rejectsGarbage() {
    #expect(throws: CronSchedule.ParseError.invalidExpression("abc")) {
        _ = try CronSchedule.parse("abc * * * *")
    }
}

// MARK: - Next fire

@Test
func nextFireEveryMinute() throws {
    let calendar = calendar()
    let schedule = try CronSchedule.parse("* * * * *")
    let base = fixedDate(2026, 1, 1, 12, 30, calendar: calendar)
    let next = try #require(schedule.nextFire(after: base, calendar: calendar))
    #expect(next == fixedDate(2026, 1, 1, 12, 31, calendar: calendar))
}

@Test
func nextFireAtSpecifiedMinute() throws {
    let calendar = calendar()
    let schedule = try CronSchedule.parse("0 * * * *")
    let base = fixedDate(2026, 1, 1, 12, 30, calendar: calendar)
    let next = try #require(schedule.nextFire(after: base, calendar: calendar))
    #expect(next == fixedDate(2026, 1, 1, 13, 0, calendar: calendar))
}

@Test
func nextFireRollsIntoNextDay() throws {
    let calendar = calendar()
    let schedule = try CronSchedule.parse("0 2 * * *")
    let base = fixedDate(2026, 1, 1, 23, 59, calendar: calendar)
    let next = try #require(schedule.nextFire(after: base, calendar: calendar))
    #expect(next == fixedDate(2026, 1, 2, 2, 0, calendar: calendar))
}

@Test
func nextFireOnWeekday() throws {
    let calendar = calendar()
    // 2026-01-03 is a Saturday; Mon-Fri at 9:00 next fires Monday 2026-01-05.
    let schedule = try CronSchedule.parse("0 9 * * 1-5")
    let base = fixedDate(2026, 1, 3, 12, 0, calendar: calendar)
    let next = try #require(schedule.nextFire(after: base, calendar: calendar))
    #expect(calendar.component(.weekday, from: next) == 2) // Monday
    #expect(next == fixedDate(2026, 1, 5, 9, 0, calendar: calendar))
}

// Helper: a fixed Gregorian calendar with a stable timezone.
private func calendar() -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
}

private func fixedDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}
