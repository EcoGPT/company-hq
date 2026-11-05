import SwiftUI

enum TaskScheduleError: LocalizedError {
    case serverUpdateRequired

    var errorDescription: String? {
        "The HQ server needs an update before repeat schedules can be saved."
    }
}

struct TaskRecurrence: Codable, Hashable, Sendable {
    let freq: String
    let timezone: String

    var label: String { TaskRepeat(rawValue: freq)?.label ?? "Repeats" }
}

enum TaskRepeat: String, CaseIterable, Identifiable {
    case never, daily, weekdays, weekly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: "Doesn’t repeat"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        }
    }

    func rule(timezone: String = TimeZone.current.identifier) -> TaskRecurrence? {
        self == .never ? nil : TaskRecurrence(freq: rawValue, timezone: timezone)
    }
}
