import Foundation

@testable import HQ

/// One card as the hub holds it, for the queued-write tests: every write
/// takes a beat (a round trip) and answers with the card as it now stands.
@MainActor final class ProjectsFakeHub {
    private(set) var task: TeamTask
    private(set) var sent: [String] = []

    init(_ task: TeamTask) { self.task = task }

    static func card(status: String = "open", projectIds: [String] = []) -> TeamTask {
        TeamTask(
            id: "t", title: "Card", status: status, ownerPersonId: "me", ownerName: "Me", createdByPersonId: "me",
            createdAt: "2026-10-01T12:00:00Z", projectId: "p", projectIds: projectIds)
    }

    func links(_ ids: [String]) async throws -> TeamTask {
        try await Task.sleep(for: .milliseconds(40))
        sent.append(ids.sorted().joined(separator: ","))
        task = Self.card(status: task.status, projectIds: ids.filter { $0 != "p" })
        return task
    }

    /// The hub's rule (`WHERE status != 'done'`): a done card is
    /// reopened only by `open`; in_progress or blocked on it is ignored.
    func status(_ status: String) async throws -> TeamTask {
        try await Task.sleep(for: .milliseconds(40))
        sent.append(status)
        if !(task.status == "done" && (status == "in_progress" || status == "blocked")) {
            task = task.moved(to: status)
        }
        return task
    }
}
