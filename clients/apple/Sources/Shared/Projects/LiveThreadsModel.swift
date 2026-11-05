import Foundation

/// The Live list's arithmetic: which agent sessions show, how each
/// is named, who it is grouped under, what folds and what overlaps. Pure
/// Foundation so the rules run in unit tests with no app and no clock but
/// the `now` handed in. Nothing here draws.
///
/// Two windows: the app asks the hub for a day (`windowMinutes`),
/// and "agents" are the ones active in the last three hours (`liveMinutes`).
/// Everything older than three hours (the read is the last 24), and every ended
/// session, folds per person into
/// "+N earlier": nothing the hub sent is dropped.
struct LiveThreadsModel {
    /// What the app asks the hub for: a day, the hub's maximum.
    static let windowMinutes = 1440
    /// Sessions with activity inside this window are the person's live agents.
    static let liveMinutes = 180
    /// Most sessions one person lists before the rest fold into "+N more".
    static let perPersonCap = 8
    /// Names longer than this are cut with an ellipsis (the full text rides
    /// in help and accessibility).
    static let nameLimit = 40

    // MARK: Age

    /// A static mark's three looks: filled under 10 minutes, a ring under 60,
    /// a dashed dimmer ring after that.
    enum Age: Equatable {
        case fresh, recent, stale

        static func bucket(_ seconds: TimeInterval) -> Age {
            seconds < 600 ? .fresh : (seconds < 3600 ? .recent : .stale)
        }
    }

    /// "now", "4m", "2h 13m", "3h".
    static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Whether a read moves the clock the ages read: when it changed what is shown, or
    /// when the clock is a minute old. A quiet read then redraws nothing, and a page coming back
    /// after the minute tick stopped with it shows today's ages at the first read.
    static func shouldMoveClock(changed: Bool, clock: Date, at date: Date = Date()) -> Bool {
        changed || date.timeIntervalSince(clock) >= 60
    }

    // MARK: Rows

    /// Where a row's name came from; anything but `.title` is drawn quieter.
    enum NameSource: Equatable { case title, intent, task, branch, none }

    enum TaskLabel: Equatable {
        /// The first linked task's reference.
        case task(String)
        case none
    }

    struct Row: Identifiable, Equatable {
        let id: String
        /// Cut to `nameLimit`.
        let name: String
        let fullName: String
        let nameSource: NameSource
        let ownerId: String
        let ownerName: String
        let provider: String
        let label: TaskLabel
        let activity: Date
        let age: Age
        let ageText: String
        /// Other people on the same task.
        let alsoNames: [String]
        /// The name is "Untitled" (no title, intent, task or branch): folds
        /// under "no name or task".
        let isUnnamed: Bool
        /// Its tasks, in the server's order.
        let tasks: [CodingThread.TaskReference]
        /// Every project its tasks link to.
        let projects: [CodingThread.ProjectReference]

        var isFallbackName: Bool { nameSource != .title }

        /// "Codex" for a session that is not Claude's, else nothing: the
        /// canvas tags it on the pill.
        var providerText: String? { provider == "claude" || provider.isEmpty ? nil : provider.capitalized }

        var labelText: String? {
            switch label {
            case .task(let ref): ref
            case .none: nil
            }
        }

        /// "Also Ada", "Also Ada, Bo", "Also Ada, Bo +1".
        var alsoText: String? {
            guard !alsoNames.isEmpty else { return nil }
            let shown = alsoNames.prefix(2).joined(separator: ", ")
            let more = alsoNames.count > 2 ? " +\(alsoNames.count - 2)" : ""
            return "Also \(shown)\(more)"
        }

        /// "<name>, <owner>, <age>, <task>" for VoiceOver.
        var accessibilityText: String {
            var parts = [fullName, ownerName, ageText == "now" ? "active now" : "\(ageText) ago"]
            if let labelText { parts.append(labelText) }
            if let alsoText { parts.append(alsoText) }
            return parts.joined(separator: ", ")
        }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        let name: String
        /// Their agents active in the last three hours, listed or folded;
        /// while a search filters, the rows that match.
        let agentCount: Int
        /// The most recent first, folded ones left out.
        let named: [Row]
        /// Named "Untitled".
        let unnamed: [Row]
        /// Older than three hours, or ended: "+N earlier".
        let earlier: [Row]
        /// Their newest activity: a live agent's, else an earlier one's.
        let latest: Date

        var hasLive: Bool { !named.isEmpty || !unnamed.isEmpty }
    }

    /// A person with nothing live: the canvas's bottom row.
    struct Idle: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// What a group draws, top to bottom.
    enum Item: Identifiable, Equatable {
        case row(Row)
        /// "+N more": the sessions past the cap.
        case more(key: String, count: Int)
        /// "+N more with no name or task".
        case folded(key: String, count: Int)
        /// "+N earlier": older than three hours, or ended.
        case earlier(key: String, count: Int)

        var id: String {
            switch self {
            case .row(let row): "row:" + row.id
            case .more(let key, _), .folded(let key, _), .earlier(let key, _): key
            }
        }
    }

    static func moreKey(_ personId: String) -> String { "more:" + personId }
    static func foldedKey(_ personId: String) -> String { "folded:" + personId }
    static func earlierKey(_ personId: String) -> String { "earlier:" + personId }

    // MARK: Build

    let groups: [Group]
    /// People with no agent in the last three hours, by name; empty while
    /// searching.
    let idle: [Idle]
    /// Agents active in the last three hours, shown or folded, across everyone.
    let total: Int
    let isSearching: Bool
    /// Everyone known, by id: the `roster` handed in plus every owner the read names (the
    /// group owners when nothing is searched), never anyone removed. Filled whether or not a
    /// search is on, unlike `groups` and `idle`, so the canvas can fix sides over it and a
    /// keystroke moves no one.
    let roster: [Idle]

    /// - Parameters:
    ///   - threads: what the hub sent: up to a day of sessions, ended ones included.
    ///   - isRemoved: whether an owner has left the company.
    ///   - roster: the people who could have agents (not removed), so the
    ///     canvas can show who has none.
    init(
        threads: [CodingThread], now: Date, search: String, isRemoved: (String) -> Bool,
        roster: [Idle] = []
    ) {
        let liveCutoff = now.addingTimeInterval(-Double(Self.liveMinutes) * 60)
        let dayCutoff = now.addingTimeInterval(-Double(Self.windowMinutes) * 60)
        // Recency comes from last_activity_at; presence `state` is unreliable,
        // and an ended session still has its day: it folds, it is not dropped.
        let kept = threads.filter { $0.activityDate >= dayCutoff && !isRemoved($0.ownerPersonId) }
        func isLive(_ thread: CodingThread) -> Bool { thread.state != "ended" && thread.activityDate >= liveCutoff }
        let live = kept.filter(isLive)

        // Who works on each task, for the "Also" chips.
        var ownersByTask: [String: [String: String]] = [:]
        for thread in live {
            for task in thread.tasks {
                ownersByTask[task.id, default: [:]][thread.ownerPersonId] = thread.ownerName
            }
        }

        let query = search.trimmingCharacters(in: .whitespaces)
        isSearching = !query.isEmpty
        var liveByOwner: [String: [Row]] = [:]
        var earlierByOwner: [String: [Row]] = [:]
        var ownerNames: [String: String] = [:]
        var counts: [String: Int] = [:]
        for thread in kept {
            let row = Self.row(for: thread, now: now, ownersByTask: ownersByTask)
            let isLiveRow = isLive(thread)
            if isLiveRow { counts[thread.ownerPersonId, default: 0] += 1 }
            ownerNames[thread.ownerPersonId] = thread.ownerName
            if !query.isEmpty, !Self.matches(thread, row: row, query: query) { continue }
            if isLiveRow {
                liveByOwner[thread.ownerPersonId, default: []].append(row)
            } else {
                earlierByOwner[thread.ownerPersonId, default: []].append(row)
            }
        }

        func newer(_ a: Row, _ b: Row) -> Bool {
            a.activity == b.activity ? a.id < b.id : a.activity > b.activity
        }
        let owners = Set(liveByOwner.keys).union(earlierByOwner.keys)
        let built: [Group] = owners.map { owner in
            let sorted = (liveByOwner[owner] ?? []).sorted(by: newer)
            let earlier = (earlierByOwner[owner] ?? []).sorted(by: newer)
            return Group(
                id: owner, name: ownerNames[owner] ?? "",
                agentCount: !query.isEmpty ? sorted.count : (counts[owner] ?? sorted.count),
                named: sorted.filter { !$0.isUnnamed }, unnamed: sorted.filter(\.isUnnamed), earlier: earlier,
                latest: sorted.first?.activity ?? earlier.first?.activity ?? .distantPast)
        }
        groups = built.sorted {
            if $0.hasLive != $1.hasLive { return $0.hasLive }
            return $0.latest == $1.latest ? $0.name < $1.name : $0.latest > $1.latest
        }
        total = groups.reduce(0) { $0 + $1.named.count + $1.unnamed.count }

        var everyone: [String: String] = [:]
        for person in roster where !isRemoved(person.id) { everyone[person.id] = person.name }
        // Every owner of a kept thread, whether the search matched their rows or not.
        for (id, name) in ownerNames { everyone[id] = name }
        self.roster = everyone.map { Idle(id: $0.key, name: $0.value) }.sorted { $0.id < $1.id }

        if query.isEmpty {
            let busy = Set(groups.filter(\.hasLive).map(\.id))
            var known: [String: String] = [:]
            for person in roster { known[person.id] = person.name }
            for group in groups where !busy.contains(group.id) { known[group.id] = group.name }
            idle = known.filter { !busy.contains($0.key) }
                .map { Idle(id: $0.key, name: $0.value) }
                .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        } else {
            idle = []
        }
    }

    /// A group's lines. Searching lists every match; otherwise the cap and
    /// the folds apply until their key is in `expanded`.
    func items(_ group: Group, expanded: Set<String>) -> [Item] {
        var items: [Item] = []
        let moreKey = Self.moreKey(group.id), foldedKey = Self.foldedKey(group.id), earlierKey = Self.earlierKey(group.id)
        let showAll = isSearching || expanded.contains(moreKey)
        let shown = showAll ? group.named : Array(group.named.prefix(Self.perPersonCap))
        items += shown.map(Item.row)
        if shown.count < group.named.count {
            items.append(.more(key: moreKey, count: group.named.count - shown.count))
        }
        if !group.unnamed.isEmpty {
            if isSearching || expanded.contains(foldedKey) {
                items += group.unnamed.map(Item.row)
            } else {
                items.append(.folded(key: foldedKey, count: group.unnamed.count))
            }
        }
        if !group.earlier.isEmpty {
            if isSearching || expanded.contains(earlierKey) {
                items += group.earlier.map(Item.row)
            } else {
                items.append(.earlier(key: earlierKey, count: group.earlier.count))
            }
        }
        return items
    }

    // MARK: Pieces

    static func row(
        for thread: CodingThread, now: Date, ownersByTask: [String: [String: String]]
    ) -> Row {
        let (full, source) = name(for: thread)

        let label: TaskLabel = if let first = thread.tasks.first { .task(first.ref) } else { .none }

        let others = Set(thread.tasks.flatMap { task in
            (ownersByTask[task.id] ?? [:]).filter { $0.key != thread.ownerPersonId }.map(\.value)
        })
        let seconds = now.timeIntervalSince(thread.activityDate)
        return Row(
            id: thread.sessionId, name: shortened(full), fullName: full, nameSource: source,
            ownerId: thread.ownerPersonId, ownerName: thread.ownerName, provider: thread.provider, label: label,
            activity: thread.activityDate, age: Age.bucket(seconds), ageText: ageText(seconds),
            alsoNames: others.sorted(), isUnnamed: source == .none, tasks: thread.tasks, projects: thread.projects)
    }

    /// A session's name and where it came from: title -> intent -> first
    /// task's title -> git branch -> "Untitled". Never the repo or cwd folder:
    /// for most people it is a random worktree name. The Live list and the
    /// thread detail both use this, so they never disagree.
    static func name(for thread: CodingThread) -> (full: String, source: NameSource) {
        let title = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let intent = thread.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = thread.gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return (title, .title) }
        if !intent.isEmpty { return (intent, .intent) }
        if let first = thread.tasks.first(where: { !$0.title.isEmpty }) { return (first.title, .task) }
        if !branch.isEmpty { return (branch, .branch) }
        return ("Untitled", .none)
    }

    /// The detail's heading: the stored session's own title when it has one,
    /// else the Live list's name.
    static func headerName(for thread: CodingThread, sessionTitle: String?) -> String {
        let stored = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? name(for: thread).full : stored
    }

    /// "Last activity 4m ago", "Active now": the Live list's age text, spelled out.
    static func activityLine(for thread: CodingThread, now: Date) -> String {
        let text = ageText(now.timeIntervalSince(thread.activityDate))
        return text == "now" ? "Active now" : "Last activity \(text) ago"
    }

    // MARK: Paging

    /// One page of `/v1/agent-sessions/active`, as the walk sees it.
    typealias PageLoader = (_ cursor: String?) async throws -> (sessions: [CodingThread], next: String?)

    /// What a walk gathered, and the error that cut it short, if any.
    struct Walk {
        var threads: [CodingThread] = []
        var failure: Error?
    }

    /// Follows `next` until it is null or repeats (the hub orders pages by
    /// session id, not recency, so one page is an arbitrary slice). A page
    /// that throws ends the walk and keeps what the earlier pages gave.
    static func walk(pages load: PageLoader) async -> Walk {
        var result = Walk()
        var seen = Set<String>()
        var cursor: String?
        repeat {
            do {
                let page = try await load(cursor)
                result.threads += page.sessions
                cursor = page.next
            } catch {
                result.failure = error
                break
            }
            if let next = cursor, !seen.insert(next).inserted { break }
        } while cursor != nil
        return result
    }

    /// What the store shows after a walk: a walk that failed never replaces a
    /// list already held (a failed later page would otherwise shrink 93 to 50
    /// for one poll). With nothing held yet it shows what the walk got.
    struct Resolution {
        let threads: [CodingThread]
        let hasLoaded: Bool
        let failed: Bool
    }

    static func resolve(_ walk: Walk, held: [CodingThread], hasLoaded: Bool) -> Resolution {
        if walk.failure == nil { return Resolution(threads: walk.threads, hasLoaded: true, failed: false) }
        if hasLoaded { return Resolution(threads: held, hasLoaded: true, failed: true) }
        return Resolution(threads: walk.threads, hasLoaded: !walk.threads.isEmpty, failed: true)
    }

    static func shortened(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > nameLimit ? String(flat.prefix(nameLimit - 1)) + "…" : flat
    }

    static func matches(_ thread: CodingThread, row: Row, query: String) -> Bool {
        ([row.fullName, thread.intent, thread.ownerName, thread.provider, thread.gitBranch ?? ""]
            + thread.tasks.map(\.title) + thread.tasks.map(\.ref) + thread.projects.map(\.name))
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
