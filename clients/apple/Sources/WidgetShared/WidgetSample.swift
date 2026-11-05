import Foundation

extension WidgetSummary {
    /// What the widget gallery shows before a Mac has signed in, and what the tests decode: an invented
    /// person and invented tasks, in the shape the server sends (counts for every task owed, at most five
    /// cards of each status).
    static let sampleJSON: String = {
        func task(
            _ number: Int, _ title: String, _ status: String, project: String?, comments: Int = 0,
            due: String? = nil, touched: String
        ) -> String {
            let text: (String?) -> String = { $0.map { "\"\($0)\"" } ?? "null" }
            return """
                {"id": "t\(number)", "number": \(number), "ref": "HQ-\(number)", "title": "\(title)", \
                "status": "\(status)", "project_name": \(text(project)), "comment_count": \(comments), \
                "due_at": \(text(due)), "touched_at": "\(touched)"}
                """
        }
        let release = task(
            44, "Plan the autumn release", "open", project: "Release", comments: 1,
            due: "2026-10-11T00:00:00.000Z", touched: "2026-09-28T09:30:00.000Z")
        let tasks = [
            task(41, "Draft the onboarding guide", "in_progress", project: "Docs site", comments: 2, touched: "2026-09-28T14:10:00.000Z"),
            task(36, "Fix the upload progress bar", "in_progress", project: "Mobile", comments: 5, touched: "2026-09-28T11:45:00.000Z"),
            task(38, "Review Bo's calendar import", "in_progress", project: "Calendar", touched: "2026-09-27T16:20:00.000Z"),
            task(
                33, "Renew the staging certificate", "blocked", project: "Infrastructure", comments: 3,
                due: "2026-10-02T00:00:00.000Z", touched: "2026-09-26T08:00:00.000Z"),
            release,
            task(
                30, "Write the backup runbook", "open", project: "Infrastructure",
                due: "2026-10-20T00:00:00.000Z", touched: "2026-09-25T13:00:00.000Z"),
            task(45, "Triage new bug reports", "open", project: nil, touched: "2026-09-28T13:55:00.000Z"),
            task(29, "Update the invite email wording", "open", project: "Docs site", touched: "2026-09-24T10:15:00.000Z"),
            task(27, "Add keyboard shortcuts to the board", "open", project: "Mobile", comments: 4, touched: "2026-09-22T17:40:00.000Z"),
        ]
        return """
            {"version": 1, "generated_at": "2026-09-28T15:00:00.000Z",
             "me": {"id": "ada", "name": "Ada", "avatar_id": null},
             "work": {"in_progress": 3, "blocked": 1, "open": 6, "done_week": 4,
                      "next_due": \(release),
                      "tasks": [\(tasks.joined(separator: ", "))]}}
            """
    }()

    static let sample: WidgetSummary? = try? decode(Data(sampleJSON.utf8))
}
