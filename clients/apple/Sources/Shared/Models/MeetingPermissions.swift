import Foundation

extension Meeting {
    /// Who may cancel a meeting, skip an occurrence or end its series: the
    /// person who made it, or an admin. The phone's swipe actions use this;
    /// the Mac's menu in `Views/Calls/MeetingsView.swift` states the same rule
    /// inline (`canCancel`).
    func canBeCanceled(by person: Person?) -> Bool {
        guard let person else { return false }
        return createdByPersonId == person.id || person.isAdmin
    }
}
