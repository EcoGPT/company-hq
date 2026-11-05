#if DEBUG && (os(macOS) || targetEnvironment(simulator))
    import Foundation

    /// The `projects` scenario: invented projects, tasks and
    /// comments for a small made-up team, so every Projects screen can be
    /// opened and captured without a server. `HQ_UI_ROUTE` picks the screen
    /// (see `route`).
    ///
    /// The viewer is Ada (`ada`, the fixture's own id) and Bo keeps the `bo`
    /// id, so the rest of the fixture's rooms still resolve.
    struct HQProjectsFixture {
        static let people: [Person] = [
            Person(id: "ada", name: "Ada", kind: "person", isAdmin: true, avatarId: nil, removedAt: nil),
            Person(id: "bo", name: "Bo", kind: "person", isAdmin: true, avatarId: nil, removedAt: nil),
            Person(id: "scout", name: "Scout", kind: "bot", isAdmin: false, avatarId: nil, removedAt: nil),
            Person(id: "cy", name: "Cy", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil),
            Person(id: "dee", name: "Dee", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil),
            Person(id: "eli", name: "Eli", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil),
            Person(id: "fay", name: "Fay", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil),
            Person(id: "gus", name: "Gus", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil),
        ]

        private static func id(of name: String) -> String {
            people.first { $0.name == name }?.id ?? "scout"
        }

        private static func minutesAgo(_ minutes: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
        }

        private static let created = "2026-09-01T15:00:00Z"

        // MARK: - Projects

        /// One project: id, name, category, lead, stage, open, total.
        private struct Row {
            let id: String
            let name: String
            let category: String?
            let lead: String
            let stage: String
            let open: Int
            let total: Int

            init(_ id: String, _ name: String, _ category: String?, _ lead: String, _ stage: String,
                 _ open: Int, _ total: Int) {
                (self.id, self.name, self.category, self.lead) = (id, name, category, lead)
                (self.stage, self.open, self.total) = (stage, open, total)
            }
        }

        private static let rows: [Row] = [
            Row("site", "Website refresh", "Product", "Ada", "Now", 7, 8),
            Row("mobile", "Mobile app polish", "Product", "Bo", "Next", 6, 8),
            Row("search", "Search and filters", "Product", "Cy", "Next", 4, 5),
            Row("onboard", "Member onboarding", "Product", "Dee", "Now", 3, 6),
            Row("api", "Public API", "Product", "Eli", "Backlog", 3, 3),
            Row("events", "Workshop series", "Operations", "Fay", "Next", 5, 7),
            Row("venue", "Venue and supplies", "Operations", "Gus", "Next", 3, 4),
            Row("dues", "Dues and receipts", "Operations", "Ada", "Next", 4, 4),
            Row("handbook", "Member handbook", "Operations", "Dee", "Backlog", 2, 2),
            Row("news", "Monthly newsletter", "Marketing", "Bo", "Now", 4, 6),
            Row("social", "Social calendar", "Marketing", "Cy", "Next", 3, 3),
            Row("press", "Local press", "Marketing", "Fay", "Backlog", 2, 2),
            Row("photos", "Photo archive", nil, "Eli", "Next", 4, 4),
        ]

        private static let ideas: [(String, [String])] = [
            ("Product", ["Dark mode", "Offline reading", "Member map", "Calendar export"]),
            ("Marketing", ["Referral cards", "Open house day", "Partner shops"]),
        ]

        static var projects: [Project] {
            var list = rows.enumerated().map { index, row in
                var project = Project(
                    id: row.id, name: row.name, body: nil, ownerPersonId: id(of: row.lead), ownerName: row.lead,
                    status: "active", openTasks: row.open, createdAt: created, closedAt: nil)
                project.totalTasks = row.total
                project.planningCategory = row.category
                project.planningState = row.stage
                project.planningOrder = Double(index)
                project.kind = "work"
                project.commentCount = comments(forProject: row.id).count
                return project
            }
            for (category, names) in ideas {
                for (index, name) in names.enumerated() {
                    var idea = Project(
                        id: "idea-\(category.lowercased())-\(index)", name: name, body: nil,
                        ownerPersonId: "bo", ownerName: "Bo", status: "active", openTasks: 0,
                        createdAt: created, closedAt: nil)
                    idea.totalTasks = 0
                    idea.planningCategory = category
                    idea.planningState = "Backlog"
                    idea.kind = "work"
                    list.append(idea)
                }
            }
            // Two objectives. The server never sends these on `/v1/projects`;
            // they are here so the screens that must hide them are exercised.
            for (id, name, lead) in [("obj-open", "Open the new clubhouse", "Bo"), ("obj-grow", "Double the membership", "Ada")] {
                var objective = Project(
                    id: id, name: name, body: nil, ownerPersonId: Self.id(of: lead), ownerName: lead,
                    status: "active", openTasks: 4, createdAt: created, closedAt: nil)
                objective.totalTasks = 4
                objective.kind = "objective"
                list.append(objective)
            }
            return list
        }

        // MARK: - Tasks (numbered from 101 in this order)

        private struct Seed {
            let status: String
            let title: String
            var comments = 0
        }

        private static func seed(
            _ status: String, _ title: String, comments: Int = 0
        ) -> Seed {
            Seed(status: status, title: title, comments: comments)
        }

        private static let groups: [(project: String, owner: String, rows: [Seed])] = [
            ("site", "Ada", [
                seed("in_progress", "Draft the new landing page copy"),
                seed("in_progress", "Swap the hero photo for the spring one"),
                seed("in_progress", "Check every page at phone width"),
                seed("in_progress", "Add the workshop calendar to the home page"),
                seed("blocked", "Wait for the logo files from the printer"),
                seed("open", "Write alt text for the gallery"),
                seed("open", "Make the footer links larger", comments: 4),
                seed("open", "Move the donate button into the header", comments: 2),
                seed("open", "Retire the old events page"),
                seed("open", "Add a sitemap"),
                seed("done", "Pick the new colour palette"),
                seed("done", "Collect photos from members"),
                seed("done", "Choose a typeface"),
            ]),
            ("mobile", "Bo", [
                seed("in_progress", "Fix the keyboard covering the reply box"),
                seed("in_progress", "Tidy the settings screen", comments: 2),
                seed("in_progress", "Make attachments open faster"),
                seed("blocked", "Test on the oldest supported phone"),
                seed("open", "Show typing dots in group rooms"),
                seed("open", "Support larger text everywhere"),
                seed("done", "Add pull to refresh"),
                seed("done", "Round the avatar corners"),
            ]),
            ("events", "Fay", [
                seed("in_progress", "Book the pottery teacher for March"),
                seed("open", "Print the workshop flyers"),
                seed("open", "Send the sign-up form to members"),
                seed("open", "Buy clay and glaze"),
                seed("open", "Plan the open studio evening"),
                seed("done", "Pick dates for the spring series"),
                seed("done", "Confirm the room booking"),
            ]),
            ("news", "Bo", [
                seed("open", "Write the opening letter"),
                seed("open", "Collect member spotlights"),
                seed("open", "Proofread the draft"),
                seed("open", "Schedule the send for Friday"),
                seed("done", "Choose the March theme"),
                seed("done", "Update the mailing list"),
            ]),
            ("onboard", "Dee", [
                seed("in_progress", "Write the welcome message"),
                seed("open", "Make a short tour of the app"),
                seed("open", "Pair new members with a buddy"),
                seed("done", "List the first-week questions"),
                seed("done", "Draft the checklist"),
                seed("done", "Review the checklist with Bo"),
            ]),
            ("dues", "Ada", [
                seed("in_progress", "Reconcile February receipts"),
                seed("open", "Send reminder notes to late members"),
                seed("open", "Move receipts to the shared folder"),
                seed("open", "Write down how refunds work"),
            ]),
            ("search", "Cy", [
                seed("open", "Search messages by sender"),
                seed("open", "Remember the last filter"),
                seed("open", "Highlight matches in results"),
                seed("open", "Add a recent searches list"),
                seed("done", "Pick the result layout"),
            ]),
        ]

        /// Hand-set owners inside a few projects; the rest keep their lead.
        private static let ownerOverrides: [String: [Int: String]] = [
            "site": [1: "Bo", 8: "Cy", 4: "Gus", 11: "Dee", 9: "Scout"],
            "events": [2: "Gus", 4: "Scout"],
        ]

        /// Ages in minutes, cycled in task order.
        private static let ageMinutes: [Double] = [1_440, 125, 4_380, 665, 1_450, 5_820, 365, 2_940]

        /// Task 141, the receipts reconcile, comes round every week; it and
        /// task 107 carry due dates, so the card's Dates field has both.
        private static let repeating: [Int: TaskRecurrence] = [
            141: TaskRecurrence(freq: "weekly", timezone: "Europe/London")
        ]
        private static let due: [Int: String] = [141: "2026-09-29T16:00:00Z", 107: "2026-09-30T16:00:00Z"]

        static var tasks: [TeamTask] {
            var number = 101
            var tasks: [TeamTask] = []
            for group in groups {
                for (index, row) in group.rows.enumerated() {
                    let ownerName = ownerOverrides[group.project]?[index] ?? group.owner
                    let age = ageMinutes[(number + 1 + index) % ageMinutes.count]
                    let isDone = row.status == "done"
                    tasks.append(
                        TeamTask(
                            recurrence: repeating[number], id: "task-\(number)", number: number, title: row.title,
                            body: number == 107
                                ? "Make the links at the foot of every page easy to hit with a thumb. "
                                    + "Done when each link has a tap area of at least 44 points." : nil,
                            status: row.status, ownerPersonId: id(of: ownerName), ownerName: ownerName,
                            dueAt: due[number], originConversationId: nil, createdByPersonId: id(of: group.owner),
                            createdAt: minutesAgo(age + 2_880), resolvedByPersonId: isDone ? id(of: ownerName) : nil,
                            resolvedAt: isDone ? minutesAgo(age) : nil, projectId: group.project,
                            touchedAt: minutesAgo(age), commentCount: row.comments))
                    number += 1
                }
            }
            return tasks
        }

        // MARK: - Comments

        private static func comment(
            _ id: String, _ author: String, _ body: String, minutesAgo minutes: Double, via: String? = nil
        ) -> HQComment {
            HQComment(
                id: id, authorName: author, authorPersonId: Self.id(of: author), body: body,
                createdAt: minutesAgo(minutes), via: via)
        }

        /// A task's activity: a few written out, and none for the rest.
        static func comments(forTask taskId: String) -> [HQComment] {
            switch taskId {
            case "task-107":
                return [
                    comment("c107-1", "Scout", "Ada filed this", minutesAgo: 4_300),
                    comment(
                        "c107-2", "Ada",
                        "Measured the footer on a phone: the links are 28 points tall. "
                            + "Raising them to 44 and spacing them out.", minutesAgo: 560, via: "mcp"),
                    comment("c107-3", "Scout", "Started on the footer fix", minutesAgo: 530),
                    comment(
                        "c107-4", "Bo", "Looks good on my phone. Check it at the largest text size too.",
                        minutesAgo: 320),
                ]
            case "task-108":
                return [
                    comment("c108-1", "Ada", "Moved the button; the header now wraps on small screens.", minutesAgo: 2_880),
                    comment("c108-2", "Cy", "Can we keep it visible while scrolling?", minutesAgo: 1_400),
                ]
            case "task-115":
                return [
                    comment("c115-1", "Bo", "The settings screen has too many rows. Group them by purpose.", minutesAgo: 5_700),
                    comment("c115-2", "Dee", "Agreed. I would put notifications and sounds together.", minutesAgo: 5_600),
                ]
            default:
                return []
            }
        }

        /// A board's own comments: the website board has two, the later
        /// written by a session (via Claude).
        static func comments(forProject projectId: String) -> [HQComment] {
            guard projectId == "site" else { return [] }
            return [
                comment(
                    "p-site-1", "Bo",
                    "This board is the website lane until the spring launch. "
                        + "Anything that changes a public page goes here first.",
                    minutesAgo: 4_200),
                comment(
                    "p-site-2", "Ada",
                    "Palette and typeface are in; the gallery text is next. The logo files are with the printer.",
                    minutesAgo: 2_600, via: "mcp"),
            ]
        }

        // MARK: - Route

        /// `HQ_UI_ROUTE`: `projects` (or unset) for the home, `project:<id>`
        /// (`project:site`), `project-comments:site` (the board's comments open
        /// beside it), `task:<number>` (the card open over its board) and `mine`.
        static var route: ProjectsRoute? {
            let value = ProcessInfo.processInfo.environment["HQ_UI_ROUTE"] ?? "projects"
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "thread": return .thread(argument)
            case "project": return .project(argument)
            case "project-comments": return .projectComments(argument)
            case "mine": return .mine
            case "task":
                guard let number = Int(argument), let task = tasks.first(where: { $0.number == number }) else { return nil }
                return .task(task.id)
            default: return nil
            }
        }
    }
#endif
