import Foundation

/// Recurring tasks are calendar dates in the schedule's saved timezone.
/// Reading their midnight instant in another zone can move them a day back.
struct TaskDueDate {
    let date: Date
    let now: Date
    let calendar: Calendar

    init(date: Date, timezone: String?, now: Date = Date(), deviceCalendar: Calendar = .current) {
        self.date = date
        self.now = now
        var calendar = deviceCalendar
        if let timezone, let zone = TimeZone(identifier: timezone) {
            calendar.timeZone = zone
        }
        self.calendar = calendar
    }

    var isToday: Bool { calendar.isDate(date, inSameDayAs: now) }
    var isOverdue: Bool { date < calendar.startOfDay(for: now) }
    var label: String {
        date.formatted(Date.FormatStyle(
            date: .abbreviated, time: .omitted,
            calendar: calendar, timeZone: calendar.timeZone
        ))
    }
}
