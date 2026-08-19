import Foundation
import Testing

@testable import Coinor

// MARK: - Friendly schedule -> cron

@Test
func recurrenceProducesTheExpectedCron() {
    #expect(AutomationRecurrence.everyMinutes(15).cronExpression == "*/15 * * * *")
    #expect(AutomationRecurrence.hourly(minute: 30).cronExpression == "30 * * * *")
    #expect(AutomationRecurrence.daily(hour: 9, minute: 0).cronExpression == "0 9 * * *")
    #expect(
        AutomationRecurrence.weekly(weekdays: [1, 3, 5], hour: 18, minute: 45)
            .cronExpression == "45 18 * * 1,3,5"
    )
    #expect(
        AutomationRecurrence.monthly(day: 1, hour: 8, minute: 0)
            .cronExpression == "0 8 1 * *"
    )
    #expect(AutomationRecurrence.custom("*/7 2 * * *").cronExpression == "*/7 2 * * *")
}

/// Everything the picker can emit must be a schedule launchd can actually be
/// given, otherwise the editor would let the user save something unschedulable.
@Test
func everyRecurrenceThePickerCanEmitCompilesForLaunchd() throws {
    var candidates: [AutomationRecurrence] = [
        .hourly(minute: 0),
        .hourly(minute: 55),
        .daily(hour: 0, minute: 0),
        .daily(hour: 23, minute: 59),
        .weekly(weekdays: [0, 1, 2, 3, 4, 5, 6], hour: 12, minute: 30),
        .weekly(weekdays: [1], hour: 6, minute: 15),
        .monthly(day: 1, hour: 9, minute: 0),
        .monthly(day: 28, hour: 22, minute: 45),
    ]
    candidates += AutomationRecurrence.minuteIntervals.map { .everyMinutes($0) }

    for candidate in candidates {
        let schedule = try CronSchedule.parse(candidate.cronExpression)
        let intervals = try CronLaunchdCompiler.intervals(for: schedule)
        #expect(!intervals.isEmpty, "\(candidate.cronExpression) produced no intervals")
    }
}

// MARK: - cron -> friendly schedule

@Test
func cronIsRecognisedAsTheMatchingRecurrence() {
    #expect(AutomationRecurrence.parse("*/15 * * * *") == .everyMinutes(15))
    #expect(AutomationRecurrence.parse("30 * * * *") == .hourly(minute: 30))
    #expect(AutomationRecurrence.parse("0 9 * * *") == .daily(hour: 9, minute: 0))
    #expect(
        AutomationRecurrence.parse("45 18 * * 1,3,5")
            == .weekly(weekdays: [1, 3, 5], hour: 18, minute: 45)
    )
    #expect(
        AutomationRecurrence.parse("0 8 1 * *")
            == .monthly(day: 1, hour: 8, minute: 0)
    )
}

@Test
func sundayAsSevenIsNormalisedWhenRecognised() {
    #expect(
        AutomationRecurrence.parse("0 9 * * 7")
            == .weekly(weekdays: [0], hour: 9, minute: 0)
    )
}

/// Anything the friendly modes cannot express must survive untouched, so a
/// hand-written schedule is never silently rewritten by opening the editor.
@Test
func unrecognisedCronFallsBackToCustomVerbatim() {
    for expression in [
        "0 9 * JAN *",       // restricted month
        "0 9-17 * * *",      // hour range
        "*/7 * * * *",       // interval the picker does not offer
        "0 9 1 * 1",         // both day-of-month and weekday
        "not a cron",
        "0 9 * *",           // too few fields
    ] {
        #expect(
            AutomationRecurrence.parse(expression) == .custom(expression),
            "\(expression) should round-trip as custom"
        )
        #expect(AutomationRecurrence.parse(expression).cronExpression == expression)
    }
}

/// Editing an automation must not change its schedule just by opening it.
@Test
func parsingAndRenderingRoundTrips() {
    for expression in [
        "*/15 * * * *",
        "30 * * * *",
        "0 9 * * *",
        "45 18 * * 1,3,5",
        "0 8 1 * *",
        "0 9-17 * * *",
    ] {
        let recurrence = AutomationRecurrence.parse(expression)
        #expect(
            recurrence.cronExpression == expression,
            "\(expression) did not round-trip"
        )
    }
}

// MARK: - Mode switching

@Test
func switchingModesKeepsTheChosenTime() {
    let daily = AutomationRecurrence.daily(hour: 18, minute: 30)
    let weekly = AutomationRecurrence.default(for: .weekly, from: daily)
    #expect(weekly.timeOfDay?.hour == 18)
    #expect(weekly.timeOfDay?.minute == 30)

    let monthly = AutomationRecurrence.default(for: .monthly, from: weekly)
    #expect(monthly.timeOfDay?.hour == 18)
    #expect(monthly.timeOfDay?.minute == 30)
}

@Test
func weeklyDefaultsToWeekdays() {
    let weekly = AutomationRecurrence.default(
        for: .weekly,
        from: .daily(hour: 9, minute: 0)
    )
    #expect(weekly == .weekly(weekdays: [1, 2, 3, 4, 5], hour: 9, minute: 0))
}

@Test
func switchingToCustomExposesTheCurrentExpression() {
    let daily = AutomationRecurrence.daily(hour: 7, minute: 15)
    let custom = AutomationRecurrence.default(for: .custom, from: daily)
    #expect(custom == .custom("15 7 * * *"))
}

@Test
func everyRecurrenceReportsItsOwnKind() {
    #expect(AutomationRecurrence.everyMinutes(5).kind == .everyMinutes)
    #expect(AutomationRecurrence.hourly(minute: 0).kind == .hourly)
    #expect(AutomationRecurrence.daily(hour: 9, minute: 0).kind == .daily)
    #expect(AutomationRecurrence.weekly(weekdays: [1], hour: 9, minute: 0).kind == .weekly)
    #expect(AutomationRecurrence.monthly(day: 1, hour: 9, minute: 0).kind == .monthly)
    #expect(AutomationRecurrence.custom("x").kind == .custom)
}

// MARK: - Human readable summary

@Test
func summaryDescribesTheScheduleInWords() {
    #expect(AutomationRecurrence.everyMinutes(15).summary == "Every 15 minutes")
    #expect(AutomationRecurrence.hourly(minute: 5).summary == "Every hour at :05")

    let weekdays = AutomationRecurrence
        .weekly(weekdays: [1, 2, 3, 4, 5], hour: 9, minute: 0).summary
    #expect(weekdays.hasPrefix("Every weekday at"))

    let weekend = AutomationRecurrence
        .weekly(weekdays: [0, 6], hour: 9, minute: 0).summary
    #expect(weekend.hasPrefix("On weekends at"))

    let picked = AutomationRecurrence
        .weekly(weekdays: [1, 3], hour: 9, minute: 0).summary
    #expect(picked.contains("Mon"))
    #expect(picked.contains("Wed"))

    #expect(
        AutomationRecurrence.monthly(day: 3, hour: 9, minute: 0)
            .summary.hasPrefix("Monthly on day 3 at")
    )
    // A custom expression is shown as itself rather than mis-described.
    #expect(AutomationRecurrence.custom("0 9-17 * * *").summary == "0 9-17 * * *")
}
