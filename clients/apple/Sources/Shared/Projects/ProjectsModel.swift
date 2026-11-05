import Foundation

// Projects: every piece of work is a task under a project. This file is the
// arithmetic the pages share; nothing in it draws.

/// Where the Projects shortcut is looking. The home is the empty path; a
/// board is a project or My tasks; a card opens over its board.
enum ProjectsRoute: Hashable {
    case thread(String)
    case project(String)
    /// A task's card, over the board it was opened from.
    case task(String)
    case mine
    /// A board's comments: a panel beside the board on the Mac, a
    /// sheet on the iPhone.
    case projectComments(String)

    /// A card opens over a board.
    var isCard: Bool {
        switch self {
        case .task: true
        default: false
        }
    }

    /// A panel opens beside its board.
    var isPanel: Bool {
        if case .projectComments = self { return true }
        return false
    }

    /// A board, as opposed to something opened beside one.
    var isBoard: Bool { !isCard && !isPanel }

    /// What takes the right-hand panel slot: a card, or a board's comments.
    var isInPanel: Bool { isCard || isPanel }
}

/// The path arithmetic behind the right panel: one slot beside the board,
/// which a card or a board's comments fill and the next one replaces.
enum ProjectsRouting {
    /// Opening a card or the comments swaps whatever holds the panel; opening
    /// a board closes the panel and goes on to it.
    static func opening(_ route: ProjectsRoute, on path: [ProjectsRoute]) -> [ProjectsRoute] {
        var next = path
        while next.last?.isInPanel == true { next.removeLast() }
        next.append(route)
        return next
    }

    /// Closing the panel lands on the board under it — the one it was
    /// opened from, or `under` when it came straight from the room or a
    /// fixture and the path holds no board.
    static func closingPanel(_ path: [ProjectsRoute], under: ProjectsRoute?) -> [ProjectsRoute] {
        var next = path
        while next.last?.isInPanel == true { next.removeLast() }
        if next.last(where: \.isBoard) == nil, let under { next.append(under) }
        return next
    }

    /// What holds the panel, when anything does.
    static func panel(_ path: [ProjectsRoute]) -> ProjectsRoute? {
        guard let last = path.last, last.isInPanel else { return nil }
        return last
    }

    /// The id the board highlights while its card is open: a task's id.
    static func openCardID(_ path: [ProjectsRoute]) -> String? {
        if case .task(let id) = path.last { return id }
        return nil
    }
}

enum ProjectsModel {
    static let categories = PlanningModel.categories
    static let week: TimeInterval = 7 * 86_400
    /// A board's lists, left to right, by the status each one holds.
    static let statusOrder = ["open", "in_progress", "blocked", "done"]

    static func statusTitle(_ status: String) -> String {
        switch status {
        case "in_progress": "In progress"
        case "blocked": "Blocked"
        case "done": "Done"
        default: "To do"
        }
    }

    // MARK: - Cards

    /// The `HQ-<n>` a card's foot and dialog show; nil on an
    /// older hub, which numbers nothing — the card then shows no ref at all.
    static func cardRef(_ task: TeamTask?) -> String? {
        task?.ref
    }

    /// A card's comments, oldest first: the feed reads down
    /// like a conversation, to the composer under the latest. The hub sends
    /// them in this order; the sort keeps it whatever arrives.
    static func feed(_ comments: [HQComment]) -> [HQComment] {
        comments.enumerated()
            .sorted { lhs, rhs in
                let left = ISO8601.parse(lhs.element.createdAt)
                let right = ISO8601.parse(rhs.element.createdAt)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    // MARK: - Repeat

    /// How a task repeats, as the Repeat menu names it.
    static func repeatOption(_ task: TeamTask) -> TaskRepeat {
        TaskRepeat(rawValue: task.recurrence?.freq ?? TaskRepeat.never.rawValue) ?? .never
    }

    /// The card's Dates field: "Repeats weekly", or nil when it does not.
    static func repeatText(_ option: TaskRepeat) -> String? {
        switch option {
        case .never: nil
        case .daily: "Repeats daily"
        case .weekdays: "Repeats on weekdays"
        case .weekly: "Repeats weekly"
        }
    }

    /// Only the live head of a series takes a new schedule: a finished one,
    /// or one whose next occurrence already exists, is history.
    static func canChangeRepeat(_ task: TeamTask) -> Bool {
        task.isOpen && task.nextTaskId == nil
    }

    /// The rule a Repeat pick writes, in the series' own timezone when it
    /// has one — a new schedule takes the device's.
    static func recurrence(
        _ option: TaskRepeat, for task: TeamTask, deviceTimeZone: String = TimeZone.current.identifier
    ) -> TaskRecurrence? {
        option.rule(timezone: task.recurrence?.timezone ?? deviceTimeZone)
    }

    // MARK: - Projects

    static func tasks(of project: Project, in tasks: [TeamTask]) -> [TeamTask] {
        tasks.filter { $0.associatedProjectIds.contains(project.id) }
    }

    /// The list a task sits in; a status no list names reads as To do.
    static func list(of task: TeamTask) -> String {
        statusOrder.contains(task.status) ? task.status : "open"
    }

    // MARK: - Mine

    /// Every open task a person owns, in every project and in none, whatever
    /// the project's planning state. Only an archived project hides its rows:
    /// My tasks once took Now alone and hid most of a person's own work.
    static func mine(_ tasks: [TeamTask], projects: [Project], owner: String) -> [TeamTask] {
        let archived = Set(projects.filter { $0.archivedAt != nil }.map(\.id))
        return tasks.filter { task in
            task.ownerPersonId == owner && task.isOpen
                && (task.associatedProjectIds.isEmpty || !task.associatedProjectIds.allSatisfy(archived.contains))
        }
    }

    /// The Projects shortcut's badge: what is on My tasks right now.
    static func myOpenCount(tasks: [TeamTask], projects: [Project], owner: String) -> Int {
        mine(tasks, projects: projects, owner: owner).count
    }

    // MARK: - Drops

    /// The lists a dragged card may land in. A task goes to a status list, a
    /// board to a category; "No category" takes nothing.
    static func canDrop(into list: String, kind: BoardDragKind) -> Bool {
        switch kind {
        case .task: statusOrder.contains(list)
        case .project: categories.contains(list)
        }
    }

    /// What a task card dropped at `index` of the list `status` asks of the
    /// hub: a new status when it changed lists, then the neighbour it lands
    /// against when the list keeps a hand order. `cards` is that list as
    /// drawn, with or without the dragged card; `index` counts the others.
    /// Nil when the drop changes nothing, or the list takes no task.
    static func taskDrop(_ task: TeamTask, into status: String, at index: Int, cards: [TeamTask]) -> TaskDrop? {
        guard canDrop(into: status, kind: .task) else { return nil }
        let others = cards.filter { $0.id != task.id }
        let slot = min(max(index, 0), others.count)
        let isMovingList = list(of: task) != status
        // Done reads newest first, so nobody's hand orders it.
        var anchor: TaskAnchor?
        if status != "done", !others.isEmpty {
            anchor =
                slot < others.count
                ? TaskAnchor(id: others[slot].id, isAfter: false)
                : TaskAnchor(id: others[others.count - 1].id, isAfter: true)
        }
        if !isMovingList {
            guard let anchor, cards.firstIndex(where: { $0.id == task.id }) != slot else { return nil }
            return TaskDrop(status: nil, anchor: anchor)
        }
        return TaskDrop(status: status, anchor: anchor)
    }

    /// The status PATCHes that move a task from `from` to `to`. The hub
    /// keeps a done task done unless it is reopened (`status: open`), so
    /// Done → In progress or Blocked reopens it first; one write otherwise.
    static func statusWrites(from: String, to: String) -> [String] {
        guard from != to else { return [] }
        return from == "done" && to != "open" ? ["open", to] : [to]
    }

    /// The same drop said the menu's way: "Move To ▸ In progress" puts the
    /// card at the foot of that list.
    static func taskMove(_ task: TeamTask, to status: String, cards: [TeamTask]) -> TaskDrop? {
        taskDrop(task, into: status, at: cards.count, cards: cards)
    }

    /// The task list as it stands once the drop lands: the new status (and
    /// touch, so Done shows it first), then the row beside its anchor —
    /// what the hub will answer, drawn before it does.
    static func applying(_ drop: TaskDrop, to taskId: String, in tasks: [TeamTask], now: Date = Date()) -> [TeamTask] {
        var next = tasks
        guard let from = next.firstIndex(where: { $0.id == taskId }) else { return tasks }
        if let status = drop.status { next[from] = next[from].moved(to: status, at: now) }
        guard let anchor = drop.anchor else { return next }
        let moving = next.remove(at: from)
        guard let at = next.firstIndex(where: { $0.id == anchor.id }) else {
            next.insert(moving, at: from)
            return next
        }
        next.insert(moving, at: anchor.isAfter ? at + 1 : at)
        return next
    }
}

/// What a dragged card is: a task on a board, or a board on the home.
enum BoardDragKind: Hashable, Sendable {
    case task
    case project
}

/// The row a dropped task lands against, and on which side.
struct TaskAnchor: Equatable, Sendable {
    let id: String
    let isAfter: Bool
}

/// A dropped task, as hub calls: the status PATCH (when it changed lists),
/// then `POST /v1/tasks/:id/order` (when the list is hand-ordered).
struct TaskDrop: Equatable, Sendable {
    let status: String?
    let anchor: TaskAnchor?
}

extension TeamTask {
    /// This task in another list: its status, touched now, resolved only
    /// while it is done.
    func moved(to status: String, at date: Date = Date()) -> TeamTask {
        let stamp = ISO8601DateFormatter().string(from: date)
        let isDone = status == "done"
        return TeamTask(
            recurrence: recurrence, nextTaskId: nextTaskId, id: id, number: number, title: title, body: body,
            status: status, ownerPersonId: ownerPersonId, ownerName: ownerName, dueAt: dueAt,
            originConversationId: originConversationId, createdByPersonId: createdByPersonId, createdAt: createdAt,
            resolvedByPersonId: isDone ? (resolvedByPersonId ?? ownerPersonId) : nil,
            resolvedAt: isDone ? (resolvedAt ?? stamp) : nil, projectId: projectId, projectIds: projectIds, touchedAt: stamp,
            commentCount: commentCount)
    }
}
