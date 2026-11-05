import Foundation

enum PlanningError: LocalizedError {
  case serverUpdateRequired
  var errorDescription: String? {
    "Planning needs a server update. Your changes have not been saved."
  }
}

/// What is left of the old planning board once Projects took its place: the
/// three categories a project sits in, and what counts as finished today.
/// The board's own arithmetic lives in `ProjectsModel`.
enum PlanningModel {
  static let categories = ["Product", "Operations", "Marketing"]

  static func isCompletedToday(_ task: TeamTask, now: Date, calendar: Calendar = .current) -> Bool {
    guard !task.isOpen, let resolved = task.resolvedAt else { return false }
    return calendar.isDate(ISO8601.parse(resolved), inSameDayAs: now)
  }
}
