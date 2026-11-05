import Foundation

/// Every date a person reads in HQ, formatted by one rule so the Mac and the
/// phone never disagree about what "Yesterday" means or when a transcript
/// breaks. Messages' own conventions.
enum RelativeStamp {
    /// How long a thread has to go quiet before the transcript stamps the
    /// time over the gap. Half an hour, on both clients.
    static let quietGap: TimeInterval = 1800

    /// The day half of a transcript separator: "Today", "Yesterday", a
    /// weekday inside the week, then dates — with the year once it matters.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let daysBack = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if daysBack < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    /// The trailing stamp on a thread in the chat list: a time today, the
    /// word yesterday, a weekday inside the week, then a plain date — the
    /// shortest thing that still says when.
    static func list(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let daysBack = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if daysBack < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
