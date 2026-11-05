import XCTest

@testable import HQ

final class TaskDueDateTests: XCTestCase {
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    func testRecurringDateKeepsItsDayWhenViewedFromAnotherTimezone() {
        let due = TaskDueDate(
            date: date("2026-09-07T04:00:00Z"), timezone: "America/New_York",
            now: date("2026-09-07T18:00:00Z"), deviceCalendar: losAngeles
        )
        XCTAssertEqual(due.calendar.component(.day, from: due.date), 7)
        XCTAssertTrue(due.isToday)
        XCTAssertFalse(due.isOverdue)
        XCTAssertEqual(due.label, due.date.formatted(Date.FormatStyle(
            date: .abbreviated, time: .omitted,
            calendar: due.calendar, timeZone: TimeZone(identifier: "America/New_York")!
        )))
    }

    func testOverdueBeginsAtMidnightInTheSavedZoneAcrossDST() {
        let due = TaskDueDate(
            date: date("2026-03-08T05:00:00Z"), timezone: "America/New_York",
            now: date("2026-03-09T04:00:00Z"), deviceCalendar: losAngeles
        )
        XCTAssertTrue(due.isOverdue)
        XCTAssertFalse(due.isToday)
    }

    func testOneTimeTasksStillUseTheDeviceTimezone() {
        let due = TaskDueDate(
            date: date("2026-09-07T04:00:00Z"), timezone: nil,
            now: date("2026-09-07T18:00:00Z"), deviceCalendar: losAngeles
        )
        XCTAssertEqual(due.calendar.component(.day, from: due.date), 6)
        XCTAssertTrue(due.isOverdue)
        XCTAssertFalse(due.isToday)
    }
}
