import XCTest
@testable import LaunchCore

final class CronScheduleTests: XCTestCase {
    func testWhitespaceNormalizationAndFullWildcardCompression() throws {
        let schedule = try CronSchedule("  *  *\t* * * \n")
        XCTAssertEqual(schedule.expression, "* * * * *")
        XCTAssertEqual(schedule.calendarIntervals, [[:]])
        XCTAssertEqual(schedule.summary, "Every minute")
    }

    func testQuarterHourExpansionDoesNotInventAnHourConstraint() throws {
        let schedule = try CronSchedule("*/15 * * * *")
        XCTAssertEqual(schedule.calendarIntervals, [["Minute": 0], ["Minute": 15], ["Minute": 30], ["Minute": 45]])
        XCTAssertEqual(schedule.summary, "Every 15 minutes")
    }

    func testListsRangesAndStepsProduceTheirCartesianCalendarSchedule() throws {
        let schedule = try CronSchedule("5,10-20/5 8-10 * 1,6 1-5")
        XCTAssertEqual(schedule.calendarIntervals.count, 120)
        XCTAssertEqual(Set(schedule.calendarIntervals.compactMap { $0["Minute"] }), [5, 10, 15, 20])
        XCTAssertEqual(Set(schedule.calendarIntervals.compactMap { $0["Hour"] }), [8, 9, 10])
        XCTAssertEqual(Set(schedule.calendarIntervals.compactMap { $0["Month"] }), [1, 6])
        XCTAssertEqual(Set(schedule.calendarIntervals.compactMap { $0["Weekday"] }), [1, 2, 3, 4, 5])
        XCTAssertTrue(schedule.calendarIntervals.allSatisfy { $0["Day"] == nil })
    }

    func testSundayZeroAndSevenAreDeduplicated() throws {
        let schedule = try CronSchedule("0 9 * * 0,7")
        XCTAssertEqual(schedule.calendarIntervals, [["Minute": 0, "Hour": 9, "Weekday": 0]])
        XCTAssertTrue(schedule.matches(try date(2026, 10, 4, 9), calendar: utc))
        XCTAssertFalse(schedule.matches(try date(2026, 10, 5, 9), calendar: utc))
    }

    func testRestrictedDayFieldsUseOrRatherThanIntersection() throws {
        let schedule = try CronSchedule("30 4 1,15 * 5")
        XCTAssertEqual(schedule.calendarIntervals.count, 3)
        XCTAssertTrue(schedule.matches(try date(2026, 10, 1, 4, 30), calendar: utc))
        XCTAssertTrue(schedule.matches(try date(2026, 10, 15, 4, 30), calendar: utc))
        XCTAssertTrue(schedule.matches(try date(2026, 10, 2, 4, 30), calendar: utc))
        XCTAssertFalse(schedule.matches(try date(2026, 10, 3, 4, 30), calendar: utc))
        XCTAssertTrue(schedule.calendarIntervals.allSatisfy { $0["Day"] == nil || $0["Weekday"] == nil })
    }

    func testWildcardDayUsesTheOtherDayConstraint() throws {
        let friday = try CronSchedule("30 4 * * 5")
        XCTAssertEqual(friday.calendarIntervals, [["Minute": 30, "Hour": 4, "Weekday": 5]])
        let dates = try CronSchedule("30 4 1,15 * *")
        XCTAssertEqual(dates.calendarIntervals, [["Minute": 30, "Hour": 4, "Day": 1], ["Minute": 30, "Hour": 4, "Day": 15]])
    }

    func testExplicitFullDayRangeUnderOrMatchesEveryDate() throws {
        let schedule = try CronSchedule("0 9 1-31 * 1")
        XCTAssertEqual(schedule.calendarIntervals, [["Minute": 0, "Hour": 9]])
        XCTAssertTrue(schedule.matches(try date(2026, 10, 6, 9), calendar: utc))
        XCTAssertEqual(schedule.summary, "Daily at 09:00")
    }

    func testSteppedStarAndExplicitFullWeekdayRangeRemainAnIntersection() throws {
        let stepped = try CronSchedule("0 9 */2 * 0-7")
        XCTAssertEqual(stepped.calendarIntervals.count, 16)
        XCTAssertTrue(stepped.matches(try date(2026, 10, 3, 9), calendar: utc))
        XCTAssertFalse(stepped.matches(try date(2026, 10, 2, 9), calendar: utc))
        let explicit = try CronSchedule("0 9 1-31/2 * 0-7")
        XCTAssertEqual(explicit.calendarIntervals, [["Minute": 0, "Hour": 9]])
        XCTAssertTrue(explicit.matches(try date(2026, 10, 2, 9), calendar: utc))
    }

    func testUnrepresentableDayIntersectionsAreRejectedRatherThanWidened() {
        for expression in ["0 9 */2 * 1-5", "0 9 1 * */2", "0 9 */2 * */2"] {
            XCTAssertThrowsError(try CronSchedule(expression)) { error in
                XCTAssertTrue(error.localizedDescription.contains("cannot be represented exactly"))
            }
        }
    }

    func testInvalidSyntaxAndBoundsAreRejected() {
        let invalid = [
            "", "* * * *", "* * * * * *", "@daily", "60 * * * *", "* 24 * * *", "* * 0 * *",
            "* * * 13 *", "* * * * 8", "-1 * * * *", "1.5 * * * *", "0 23-2 * * *", "1,,2 * * * *",
            "*/0 * * * *", "*/-1 * * * *", "*/2/3 * * * *", "5/2 * * * *", "*/ * * * *",
            "0 9 * * MON", "0 9 ? * *", "999999999999999999999999999999999999 * * * *",
            "*/999999999999999999999999999999999999 * * * *"
        ]
        for expression in invalid { XCTAssertThrowsError(try CronSchedule(expression), expression) }
        XCTAssertThrowsError(try CronSchedule(String(repeating: "*", count: 513)))
    }

    func testLargeValidStepDoesNotOverflowOrLoop() throws {
        let schedule = try CronSchedule("*/\(Int.max) * * * *")
        XCTAssertEqual(schedule.calendarIntervals, [["Minute": 0]])
        XCTAssertEqual(schedule.summary, "Every hour at :00")
    }

    func testExpansionLimitIsInclusiveAndCheckedBeforeAllocatingAllEntries() throws {
        XCTAssertEqual(try CronSchedule("0-31 0-15 * 1-8 *").calendarIntervals.count, 4_096)
        XCTAssertThrowsError(try CronSchedule("0-32 0-15 * 1-8 *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("4,096"))
        }
        XCTAssertThrowsError(try CronSchedule("0-58 0-22 1-30 1-11 *"))
    }

    func testSummariesDoNotClaimUniformSpacingForUnevenCronSteps() throws {
        XCTAssertEqual(try CronSchedule("15 * * * *").summary, "Every hour at :15")
        XCTAssertEqual(try CronSchedule("0 9 * * *").summary, "Daily at 09:00")
        XCTAssertEqual(try CronSchedule("0 9 * * 1-5").summary, "Weekdays at 09:00")
        XCTAssertEqual(try CronSchedule("30 18 * * 7").summary, "Every Sunday at 18:30")
        XCTAssertEqual(try CronSchedule("*/17 * * * *").summary, "Cron: */17 * * * *")
    }

    func testTranslatedCalendarEntriesAgreeWithSourceCronAcrossDates() throws {
        let schedules = try ["*/15 * * * *", "30 4 1,15 * 5", "0 9 1-31 * 1", "0 9 */2 * 0-7",
                             "0,30 8-10/2 * 1,2,10 0,7", "* * * * *"].map(CronSchedule.init)
        for schedule in schedules {
            for month in [1, 2, 10] {
                for day in 1...28 {
                    for hour in [4, 8, 9, 10, 14] {
                        for minute in [0, 15, 30, 45] {
                            let instant = try date(2026, month, day, hour, minute)
                            XCTAssertEqual(schedule.matches(instant, calendar: utc), calendarMatches(schedule.calendarIntervals, instant),
                                "Translation changed \(schedule.expression) at \(month)/\(day) \(hour):\(minute)")
                        }
                    }
                }
            }
        }
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    private func calendarMatches(_ entries: [[String: Int]], _ date: Date) -> Bool {
        let parts = utc.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        return entries.contains { entry in
            let timeMatches = (entry["Minute"] == nil || entry["Minute"] == parts.minute)
                && (entry["Hour"] == nil || entry["Hour"] == parts.hour)
                && (entry["Month"] == nil || entry["Month"] == parts.month)
            let dayMatches: Bool
            if let day = entry["Day"], let weekday = entry["Weekday"] {
                dayMatches = day == parts.day || weekday == (parts.weekday ?? 0) - 1
            } else if let day = entry["Day"] { dayMatches = day == parts.day }
            else if let weekday = entry["Weekday"] { dayMatches = weekday == (parts.weekday ?? 0) - 1 }
            else { dayMatches = true }
            return timeMatches && dayMatches
        }
    }
}
