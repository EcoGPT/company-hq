#if DEBUG && (os(macOS) || targetEnvironment(simulator))
import Foundation

enum HQCodingThreadsFixture {
    /// One fixture session: when it last did anything (minutes before the
    /// read, so the Live list always reads as fresh), what it is called and
    /// which tasks it is filed under.
    struct Row {
        let id: String, owner: String, minutesAgo: Double
        var title: String?, intent = "", branch: String?, state = "idle"
        var tasks: [Int] = []
        init(_ id: String, _ owner: String, _ minutesAgo: Double, title: String? = nil, intent: String = "",
             branch: String? = nil, state: String = "idle", tasks: [Int] = []) {
            self.id = id; self.owner = owner; self.minutesAgo = minutesAgo; self.title = title
            self.intent = intent; self.branch = branch; self.state = state; self.tasks = tasks
        }
    }

    /// `HQ_UI_OPEN_TRANSCRIPTS=off` plays a server that does not open other
    /// people's sessions: another person's thread has no `session`.
    static var opensTranscripts: Bool { ProcessInfo.processInfo.environment["HQ_UI_OPEN_TRANSCRIPTS"] != "off" }

    /// Five people over a day, 37 sessions: Ada has 12 in the last three
    /// hours (and one ended, two older today), about 40% have no title, a few
    /// have neither title nor intent, several have no task, Ada, Bo and Cy share tasks, Cy has an ended session,
    /// and Eli has nothing in the last three hours. Fay and Gus (Projects
    /// fixture) have no sessions at all.
    static let people: [(name: String, id: String, rows: [Row])] = [
        ("Ada", "ada", [
            .init("thread-one", "ada", 1, title: "Make the footer links larger", tasks: [0]),
            .init("t-02", "ada", 3, title: "Fix the broken link checker", tasks: [1]),
            .init("t-03", "ada", 6, intent: "Review Cy's search pull request"),
            .init("t-04", "ada", 9, title: "Move receipts to paged reads", tasks: [2]),
            .init("t-05", "ada", 14, tasks: [3]),
            .init("t-06", "ada", 22, title: "Photos for the welcome tour"),
            .init("t-07", "ada", 35, title: "Tune the reminder wording", tasks: [4]),
            .init("t-08", "ada", 48, branch: "ada/live-list", tasks: []),
            .init("t-09", "ada", 62),
            .init("t-10", "ada", 75, title: "Notes for the spring launch"),
            .init("t-11", "ada", 95, title: "Staging checklist"),
            .init("t-12", "ada", 130, title: "Investigate why the importer drops the second page of members when a file is resumed"),
            .init("t-13", "ada", 20, title: "Finished spike", state: "ended"),
            .init("t-14", "ada", 280, title: "Search speed"),
            .init("t-15", "ada", 540, title: "Sign-in strategy for shared tablets"),
        ]),
        ("Bo", "bo", [
            .init("thread-two", "bo", 2, title: "Build reusable newsletter templates", tasks: [0]),
            .init("b-02", "bo", 11, title: "Mailing list cleanup", tasks: [5]),
            .init("b-03", "bo", 40),
            .init("b-04", "bo", 125, title: "Draft for the spring letter", tasks: []),
            .init("b-05", "bo", 150, intent: "Answer member questions"),
            .init("b-06", "bo", 330, title: "Share card polish"),
        ]),
        ("Cy", "cy", [
            .init("c-01", "cy", 4, title: "Flyer copy pass", tasks: [1]),
            .init("c-02", "cy", 8, intent: "Check the sign-up follow-ups"),
            .init("c-03", "cy", 7, title: "Pager for the importer"),
            .init("c-04", "cy", 27, branch: "cy/flyer-fix", tasks: []),
            .init("c-05", "cy", 70, title: "Event approvals"),
            .init("c-06", "cy", 160, title: "Weekly numbers write-up"),
            .init("c-07", "cy", 250, title: "Member survey"),
            .init("c-08", "cy", 600),
            .init("c-09", "cy", 40, title: "Archive", state: "ended"),
        ]),
        ("Dee", "dee", [
            .init("d-01", "dee", 5, title: "Welcome flow polish", tasks: [3]),
            .init("d-02", "dee", 33, tasks: []),
            .init("d-03", "dee", 90, title: "Retention chart review"),
            .init("d-04", "dee", 170),
            .init("d-05", "dee", 800, title: "Dues page copy"),
        ]),
        ("Eli", "eli", [
            .init("e-01", "eli", 200, title: "Release notes for the phone app"),
            .init("e-02", "eli", 330),
            .init("e-03", "eli", 480, intent: "Sort incoming questions"),
        ]),
    ]

    /// `HQ_UI_LIVE_BULK=1` adds nine more people and 36 sessions on top of
    /// `people`, so the Live canvas shows 63 agents: it is what the canvas has
    /// to draw without a cap, and what its zoom and pan are for.
    static var bulkRows: [Row] {
        guard ProcessInfo.processInfo.environment["HQ_UI_LIVE_BULK"] == "1" else { return [] }
        let owners = ["Hal", "Ivy", "Jo", "Kit", "Lea", "Max", "Ned", "Oli", "Pia"]
        let titles = ["Review the retry policy", "Tidy the settings screen", "Chase the flaky upload test", "Draft release notes",
                      "Profile the feed query", "Port the reminder card", "Clean up stale branches", "Write the migration plan"]
        var rows: [Row] = []
        for (index, owner) in owners.enumerated() {
            for n in 0..<(3 + index % 3) {
                let serial = index * 5 + n
                rows.append(.init(
                    "bulk-\(owner.lowercased())-\(n)", owner, Double(1 + (serial * 7) % 170),
                    title: serial % 6 == 5 ? nil : titles[serial % titles.count]))
            }
        }
        return rows
    }

    /// The row as the server sends it, `last_activity_at` measured from now.
    static func live(_ row: Row) -> [String: Any] {
        let name = people.first { $0.id == row.owner }?.name ?? row.owner.capitalized
        let work = HQProjectsFixture.tasks.filter { $0.projectId != nil }
        let tasks: [[String: Any]] = row.tasks.compactMap { index in
            work.indices.contains(index)
                ? ["id": work[index].id, "ref": work[index].ref ?? "HQ-\(900)", "title": work[index].title] : nil
        }
        // The projects its tasks sit on: the hubs the canvas draws.
        let linked = Set(row.tasks.compactMap { index -> String? in
            work.indices.contains(index) ? work[index].projectId : nil
        })
        let projects: [[String: Any]] = HQProjectsFixture.projects.filter { linked.contains($0.id) }
            .map { ["id": $0.id, "name": $0.name] }
        var json: [String: Any] = [
            "session_id": row.id, "intent": row.intent.isEmpty ? (row.title ?? "") : row.intent, "state": row.state,
            "last_seen_at": 0, "last_activity_at": (Date().timeIntervalSince1970 - row.minutesAgo * 60) * 1000,
            "owner_person_id": row.owner, "owner_name": name, "provider": row.owner == "ada" ? "codex" : "claude",
            "repo": "wt-\(row.id)", "tasks": tasks,
            "projects": projects,
        ]
        json["title"] = row.title ?? ""
        if let branch = row.branch { json["git_branch"] = branch }
        return json
    }

    /// Sessions per page of `/v1/agent-sessions/active`; small so 31 rows take two.
    static let pageSize = 20

    /// The server's page: sessions active inside `since_minutes` (default 10),
    /// ordered by session id, `cursor` = the last id served. The order is the
    /// server's, not recency, so only following `next_cursor` shows everything.
    static func activePage(query: String?, rows: [Row]) -> [String: Any] {
        let items = URLComponents(string: "?" + (query ?? ""))?.queryItems ?? []
        let since = items.first { $0.name == "since_minutes" }?.value.flatMap(Double.init) ?? 10
        let cursor = items.first { $0.name == "cursor" }?.value
        let ordered = rows.filter { $0.minutesAgo <= since }.sorted { $0.id < $1.id }
        let rest = cursor.map { after in ordered.filter { $0.id > after } } ?? ordered
        let page = Array(rest.prefix(pageSize))
        let more = rest.count > page.count
        return ["sessions": page.map(live), "next_cursor": more ? (page.last?.id as Any) : NSNull()]
    }

    /// Another person's session, as `/by-id` sends it once the server opens them.
    static func peerSession(_ row: Row) -> [String: Any] {
        ["id": row.id, "provider": "claude", "source_id": "src-" + row.id, "title": row.title ?? "", "task_ids": [String](),
         "message_count": 4, "revision": 3, "tool_history": true, "updated_at": "2026-09-24T16:00:00Z"]
    }

    static func response(_ path: String, query: String? = nil, empty: Bool) -> [String: Any]? {
        guard path.hasPrefix("/v1/agent-sessions") else { return nil }
        let project = HQProjectsFixture.projects.first!
        let task = HQProjectsFixture.tasks.first { $0.projectId == project.id }!
        let own = live(.init("thread-one", "ada", 1, title: "Make the footer links larger", tasks: [0]))
        let peer = live(.init("thread-two", "bo", 2, title: "Build reusable newsletter templates", tasks: [0]))
        let sessions = people.flatMap { $0.rows } + bulkRows
        let session: [String: Any] = ["id": "thread-one", "provider": "codex", "source_id": "fixture-source", "title": "Make the footer links larger", "task_id": task.id, "task_ids": [task.id], "message_count": 4, "revision": 2, "tool_history": true, "updated_at": "2026-09-24T16:00:00Z"]
        if path == "/v1/agent-sessions/active" {
            return empty ? ["sessions": [], "next_cursor": NSNull()] : activePage(query: query, rows: sessions)
        }
        if path == "/v1/agent-sessions" { return ["sessions": empty ? [] : [session], "next_before": NSNull()] }
        if path.hasPrefix("/v1/agent-sessions/by-id/") {
            let id = String(path.dropFirst("/v1/agent-sessions/by-id/".count))
            let isOwn = id == "thread-one"
            if let row = sessions.first(where: { $0.id == id }), row.id != "thread-one", row.id != "thread-two" {
                return ["thread": live(row), "session": (opensTranscripts ? peerSession(row) : NSNull() as Any) as Any]
            }
            let peerRow = sessions.first { $0.id == "thread-two" }
            return [
                "thread": isOwn ? own : peer,
                "session": (isOwn ? session : (opensTranscripts ? peerSession(peerRow!) : NSNull() as Any)) as Any,
            ]
        }
        return nil
    }
}
#endif
