#if os(macOS)
import AppKit
import Network
#endif
import CoreGraphics
import Foundation
import ImageIO
import Observation
import os
import UniformTypeIdentifiers

// Bootstrap and resync failures were swallowed as "transient" — true, but a
// Mac stuck behind a captive portal or a broken DNS produced no evidence at
// all. Same subsystem as the call and socket logs, one dump for everything.
private let storeLog = Logger(subsystem: HQIdentity.logSubsystem, category: "sync")

/// One conversation's loaded transcript, observed on its own. See the note on
/// `AppStore.messageSlots`.
@MainActor
@Observable
final class MessageSlot {
    var messages: [Message] = []
}

/// One conversation's row, mirrored from `AppStore.conversations` and
/// assigned only when that conversation changed.
@MainActor
@Observable
final class ConversationSlot {
    var value: Conversation?

    /// Seeded at creation: a slot made from a view body must not be a write to
    /// observed state.
    init(value: Conversation? = nil) {
        self.value = value
    }
}

/// One conversation's live read marks. A teammate's receipt moves a mark here
/// and nowhere else, so it wakes the "Read" line under the last outgoing
/// bubble and not the sidebar, the phone's list or the detail panel, none of
/// which draw a mark. The conversations array keeps the marks the hub last
/// restated; this slot holds the merged, current value.
@MainActor
@Observable
final class ReadMarkSlot {
    var marks: [ReadMark]

    init(marks: [ReadMark] = []) {
        self.marks = marks
    }
}

/// One conversation's unsent draft: its text and its staged attachments.
/// Separate properties, so a view reading only the attachments is not woken
/// by a keystroke.
@MainActor
@Observable
final class DraftSlot {
    var text = ""
    var attachments: [Attachment] = []
}

/// Key of the bounded preview memo: the same words under the same roster
/// always read the same.
private struct PlainTextKey: Hashable {
    let content: String
    let rosterVersion: Int
}

/// One run at a time, and at most one more queued behind it. A caller that
/// arrives while a run is going records its request (combined with any already
/// queued) and waits for the whole chain, so a burst of triggers — a reconnect,
/// a push, a call ending — is one pass and at most one catch-up, never a pile
/// of concurrent fan-outs.
@MainActor
final class CoalescedRunner<Request> {
    private var task: Task<Void, Never>?
    private var queued: Request?
    private let combine: (Request, Request) -> Request
    private let perform: @MainActor (Request) async -> Void

    init(
        combine: @escaping (Request, Request) -> Request,
        perform: @escaping @MainActor (Request) async -> Void
    ) {
        self.combine = combine
        self.perform = perform
    }

    var isRunning: Bool { task != nil }

    func run(_ request: Request) async {
        if let running = task {
            queued = queued.map { combine($0, request) } ?? request
            await running.value
            return
        }
        let chain = Task { @MainActor [self] in
            // A request that queued before this body first ran (the chain is
            // its own task, so another `run` can land in between) joins the
            // first pass instead of being cleared unseen.
            var next: Request? = queued.map { combine(request, $0) } ?? request
            queued = nil
            while let current = next {
                await perform(current)
                next = queued
                queued = nil
            }
            task = nil
        }
        task = chain
        await chain.value
    }
}

/// One in-flight run per key: a second caller for the same key waits for the
/// first instead of starting its own, and a later caller after it finished
/// starts a new one. The run is its own task, so a caller that is cancelled
/// (a view leaving) does not cancel the work another caller still wants.
@MainActor
final class SingleFlight<Key: Hashable> {
    private var tasks: [Key: Task<Void, Never>] = [:]

    func isRunning(_ key: Key) -> Bool { tasks[key] != nil }

    func run(_ key: Key, _ operation: @escaping @MainActor () async -> Void) async {
        if let running = tasks[key] {
            await running.value
            return
        }
        let flight = Task { @MainActor [self] in
            await operation()
            tasks[key] = nil
        }
        tasks[key] = flight
        await flight.value
    }
}

/// When the cache is written. A change starts a quiet window; further changes
/// restart it, up to a ceiling counted from the first unsaved change, so a
/// steady stream still reaches the disk and a crash loses seconds, not an
/// afternoon.
enum SaveSchedule {
    nonisolated static let debounce: TimeInterval = 5
    nonisolated static let maxWait: TimeInterval = 30

    /// How long to wait from `now` before writing, given when the oldest
    /// unsaved change was first requested.
    nonisolated static func delay(firstRequestedAt: Date, now: Date) -> TimeInterval {
        let waited = max(0, now.timeIntervalSince(firstRequestedAt))
        return min(debounce, max(0, maxWait - waited))
    }
}

// The one client-side owner of session, roster, conversations, messages,
// presence, and the socket. Views render it; the server stays the authority.
@MainActor
@Observable
final class AppStore {
    enum Phase {
        case enrolling
        case ready
    }

    private(set) var phase: Phase = .enrolling
    private(set) var session: StoredSession?
    private(set) var people: [String: Person] = [:] {
        didSet { peopleDidChange() }
    }
    private(set) var conversations: [Conversation] = [] {
        didSet { conversationsDidChange() }
    }
    // Per-conversation observation. `@Observable` tracks a
    // stored property as ONE key, so a dictionary of every chat's messages
    // meant a message, an agent step or a trim in any room re-rendered the
    // open transcript, and an array of every conversation meant a teammate's
    // read receipt did the same. Each chat's messages, row and draft live in
    // their own small observable slot instead; a view reads exactly the slot
    // it shows (`messages(in:)`, `conversation(_:)`, `draftText(for:)`) and is
    // woken only by writes to that one. The dictionaries holding the slots are
    // ignored by Observation, so creating a slot lazily from a view body is
    // not a write to observed state. Every write goes through one funnel
    // (`publishMessages`, `writeConversation`, `setDraftText`,
    // `setDraftAttachments`) and assigns only when the value differs.
    @ObservationIgnored private var messageSlots: [String: MessageSlot] = [:]
    @ObservationIgnored private var conversationSlots: [String: ConversationSlot] = [:]
    @ObservationIgnored private var draftSlots: [String: DraftSlot] = [:]
    @ObservationIgnored private var readMarkSlots: [String: ReadMarkSlot] = [:]
    /// `conversations`, readable without registering a dependency on it — a
    /// slot created from a view body seeds itself from here.
    @ObservationIgnored private var conversationsShadow: [Conversation] = []
    /// The last total handed to the OS, so an identical count is never sent
    /// again (an XPC call on the phone).
    @ObservationIgnored private var lastBadgeTotal: Int?
    /// What this device last reported about push (permission, token, error).
    private(set) var pushState = PushState()
    /// The report in flight, so reports land in order and sign-out's DELETE
    /// lands after them.
    @ObservationIgnored private var pushReportTask: Task<Void, Never>?
    /// Conversations holding an unsent draft (text or attachments). Assigned
    /// only when a draft flips between empty and non-empty, so the phone's
    /// list filters on this and a keystroke never reaches it.
    private(set) var draftConversationIDs: Set<String> = []
    /// Every name a bubble draws as a tag, sorted — stored, and assigned only
    /// when the roster's names actually change (see `peopleDidChange`).
    private(set) var mentionNames: [String] = []
    /// Bumped with `mentionNames`; keys the preview memo and lets a view say
    /// "the roster changed" without depending on `people`.
    private(set) var rosterVersion = 0
    @ObservationIgnored private var plainTextMemo: [PlainTextKey: String] = [:]
    private static let plainTextMemoLimit = 256
    private(set) var onlinePersonIds: Set<String> = []
    private(set) var typingByConversation: [String: [String: Date]] = [:]
    private(set) var botActivityByConversation: [String: BotActivity] = [:]

    /// The server-authored state line for a bot working a conversation —
    /// "Thinking", a tool label — shown until cleared or expired.
    struct BotActivity {
        let personId: String
        let label: String
        let expiresAt: Date
    }
    private(set) var calls: [Call] = []
    private(set) var meetings: [Meeting] = []
    private(set) var tasks: [TeamTask] = []
    private(set) var projects: [Project] = []
    /// Whether the hub opens every synced conversation to every member
    /// (`"open_transcripts": true` on the `/v1/projects` envelope). A thread whose
    /// detail comes back without `session` shows its metadata and a lock.
    private(set) var supportsOpenTranscripts = false
    /// The Agents page's state. Held here, not by the Tasks view, so leaving
    /// Tasks and coming back draws the page at once and re-reads behind it.
    /// New on sign-out.
    private(set) var liveThreads = LiveThreadsStore()
    /// Set once the hub has stated its capabilities (`applyProjects`): a
    /// cache that lands later never replaces them.
    @ObservationIgnored private var hubStatedCapabilities = false
    private(set) var activeCallId: String?
    private(set) var callError: String?
    /// The call ringing right now. One at a time: a second ring while
    /// one is up is dropped rather than stacking windows on someone who is
    /// already being asked a question.
    private(set) var incomingCall: IncomingCall?
    let callEngine = CallEngine()
    private let ringer = Ringer()
    private var ringTimeout: Task<Void, Never>?
    /// The app's own window opener, handed over by the main window at
    /// launch. Answering a ring happens inside a floating AppKit panel,
    /// which sits outside the scene graph — `@Environment(\.openWindow)`
    /// there has no scene to talk to, and the meeting stage would never
    /// appear.
    var openWindowAction: ((String) -> Void)?
    // Leaving a thread drops its loaded history back to the cold-start
    // window: the transcript is an eager VStack, so every loaded row is a
    // laid-out row, and what stays loaded must stay bounded.
    var destination: Destination = .none {
        didSet {
            if case .conversation(let previous) = oldValue {
                // Deferred a turn: this didSet fires inside the SwiftUI
                // update that is swapping the destination, and the departed
                // transcript's row closures are still enumerating the array
                // the trim would shrink — an index race that traps (Array
                // out of range under ForEachChild.updateValue). One turn
                // later nothing is showing the thread and the trim is safe;
                // it re-checks the selection itself.
                Task { @MainActor in self.trimLoadedHistory(of: previous) }
            }
        }
    }

    /// Where typing should land when no conversation is on screen: the last
    /// one the user was in, falling back to the top of the sidebar.
    private(set) var lastConversationId: String?
    /// Text typed while the composer wasn't on screen; the composer drains it
    /// into the draft the moment it appears, so no keystroke is lost.
    var pendingComposerText: String?
    /// Unsent text, keyed by conversation. It lives here rather than in the
    /// composer because the composer sits OUTSIDE the transcript's
    /// `.id(conversationId)` and so never remounts on a thread switch —
    /// view-local text would follow the user from one chat into the next.
    ///
    /// Stored per conversation in `draftSlots`; this dictionary is a plain
    /// read-and-write view of them for callers outside the views. Reading it
    /// from a view body is a trap: the getter touches every EXISTING slot, so
    /// the view would be woken by those drafts and never by a slot created
    /// later. A view reads `draftText(for:)`, which depends on one
    /// conversation's draft and nothing else.
    var textDrafts: [String: String] {
        get { draftSlots.compactMapValues { $0.text.isEmpty ? nil : $0.text } }
        set {
            for id in Set(draftSlots.keys).union(newValue.keys) {
                setDraftText(newValue[id] ?? "", for: id)
            }
        }
    }
    /// The trailing details panel. Lives here so the toolbar title, the
    /// panel toggle, and the sidebar snap all agree on one truth.
    var isDetailPanelOpen = false
    var enrollmentError: String?
    /// False when the device bearer could not reach the Keychain — the app
    /// works for this run and forgets everything on quit. Surfaced rather
    /// than swallowed: it is the difference between "HQ logged me out again"
    /// and a build that is missing its keychain entitlement.
    private(set) var isSessionPersisted = true
    var sessionPersistenceProblem: String? {
        isSessionPersisted ? nil : Keychain.lastFailure
    }
    /// The message the composer is replying to, iMessage-style.
    var replyTarget: Message?
    /// Follow-on UI for the message menu, one target per dialog.
    var tapbackDetailsTarget: Message?
    /// The message whose reply thread is pulled out over the transcript.
    var threadTarget: Message?
    var forwardTarget: Message?
    var deleteTarget: Message?
    /// The message waiting on a custom tapback from the system emoji palette.
    var emojiTapbackTarget: Message?
    /// "Show Times" — every message's time shown beside its row.
    var isShowingMessageTimes = false
    var searchQuery = ""
    private(set) var searchResults: [Message] = []
    struct MessageJump: Equatable {
        let conversationId: String
        let messageId: String
    }
    var messageJump: MessageJump?
    /// Keyed by conversation: the main window and the in-call chat panel can
    /// both be staging attachments at once, and each send claims only its own.
    /// (Stored in `draftSlots`; read through `drafts(in:)`.)
    private(set) var uploadingCounts: [String: Int] = [:]
    private(set) var attachmentErrors: [String: String] = [:]
    private(set) var isLoadingOlder = false
    private(set) var exhaustedHistory: Set<String> = []

    /// What the detail pane is showing. The pinned circles are destinations
    /// like any conversation, not modes layered on top of one.
    enum Destination: Hashable {
        case none
        case conversation(String)
        case meetings
        case tasks
        case files
        case settings
    }

    #if os(macOS)
    /// Settings' open page and its cards' last hub answers, kept across visits.
    let settings = SettingsModel()
    #endif
    /// Where the Projects shortcut (`.tasks`) is looking: empty is the home
    /// grid. Kept here rather than in the page so a task link and a fixture
    /// route can open a page directly.
    var projectsPath: [ProjectsRoute] = []

    /// Opens Projects, at its home or straight onto one page.
    func openProjects(_ route: ProjectsRoute? = nil) {
        projectsPath = route.map { [$0] } ?? []
        destination = .tasks
    }

    /// A coding thread's `hq://thread/<id>`, or a task's https link.
    func openLink(_ url: URL) {
        if let number = TaskLink.number(from: url) {
            pendingTaskNumber = number
            openProjects()
            openPendingTask()
            if pendingTaskNumber != nil { Task { await loadTasks() } }
        } else if let id = CodingThreadLink.id(from: url) {
            openProjects(.thread(id))
        }
    }

    /// A task link opened before the board held its task: its card opens
    /// when the task arrives.
    private var pendingTaskNumber: Int?

    private func openPendingTask() {
        guard let number = pendingTaskNumber, let task = tasks.first(where: { $0.number == number }) else { return }
        pendingTaskNumber = nil
        openProjects(.task(task.id))
    }

    /// The Projects shortcut's badge: every open task I own, in any project.
    var myOpenTaskCount: Int {
        ProjectsModel.myOpenCount(tasks: tasks, projects: projects, owner: me?.id ?? "")
    }

    var selectedConversationId: String? {
        get {
            if case .conversation(let id) = destination { return id }
            return nil
        }
        set { destination = newValue.map { .conversation($0) } ?? .none }
    }

    var activeCall: Call? {
        guard let activeCallId else { return nil }
        return calls.first { $0.id == activeCallId }
    }

    var liveCalls: [Call] { calls.filter(\.isLive) }

    /// Every meeting room with people in it right now — the standing company
    /// room and any live named meetings.
    var liveMeetings: [Call] { liveCalls.filter { $0.kind == "meeting" } }

    /// The chat list: the team's feeds, the assistant DM, then every thread
    /// that has actually been spoken in. An empty thread
    /// shows only while it is the one on screen, so a recorded meeting or an
    /// abandoned compose never lingers as a groupchat. Every other standing
    /// room stays invisible machinery.
    var visibleConversations: [Conversation] {
        // Pure recency, nothing pinned: the server already orders by last
        // activity, so keep that order. Feeds and the assistant DM stay listed
        // before their first message; any other never-spoken thread shows only
        // while selected.
        conversations.filter { conversation in
            // A DM with someone removed leaves the list but stays
            // reachable by id: it shows while it is the one on screen, and
            // returns on restore because this reads `people` live.
            let isRemovedDM = Self.isRemovedPartnerDM(conversation, meId: me?.id, people: people)
            if isRemovedDM && conversation.id != selectedConversationId { return false }
            return conversation.lastMessage != nil || conversation.id == selectedConversationId
                || isFeedRoom(conversation) || isAssistantDM(conversation)
        }
    }

    /// Pinned rows in pin order. A DM with a removed partner drops out unless
    /// it is the open conversation; the pin itself is kept, so a restore
    /// brings the row back.
    func pinnedConversations(ids: [String]) -> [Conversation] {
        ids.compactMap { id in
            conversations.first { conversation in
                conversation.id == id && isListable(conversation)
            }
        }
    }

    /// False for a removed partner's DM unless it is the one on screen.
    func isListable(_ conversation: Conversation) -> Bool {
        conversation.id == selectedConversationId
            || !Self.isRemovedPartnerDM(conversation, meId: me?.id, people: people)
    }

    /// A DM whose other side has been removed. Groups are never this:
    /// they keep showing, minus the removed member.
    static func isRemovedPartnerDM(
        _ conversation: Conversation, meId: String?, people: [String: Person]
    ) -> Bool {
        guard conversation.kind == "dm" else { return false }
        return conversation.memberIds.contains { $0 != meId && people[$0]?.isRemoved == true }
    }

    /// People from the most recent conversations first, then the rest of the
    /// roster — the new-message sheet's order. Removed people never appear.
    static func recommendedRecipients(
        conversations: [Conversation], people: [String: Person], meId: String?
    ) -> [Person] {
        var seen = Set<String>()
        var ordered: [Person] = []
        for conversation in conversations {
            for id in conversation.memberIds where id != meId && !seen.contains(id) {
                guard let person = people[id], person.kind == "person", !person.isRemoved else { continue }
                seen.insert(id)
                ordered.append(person)
            }
        }
        let rest = roster(from: Array(people.values)).filter { $0.id != meId && !seen.contains($0.id) }
        return ordered + rest
    }

    /// A new task's owner: the project's lead while they are still here,
    /// otherwise me.
    static func defaultOwner(lead: String?, meId: String?, people: [String: Person]) -> String? {
        if let lead, people[lead]?.isRemoved != true { return lead }
        return meId
    }

    func defaultOwner(lead: String?) -> String? {
        Self.defaultOwner(lead: lead, meId: me?.id, people: people)
    }

    /// A conversation fetched outside the sync stream, folded in so
    /// ChatView can find it by id.
    func adopt(conversation: Conversation) {
        upsert(conversation: conversation)
    }

    /// Meeting recaps and task completions land here.
    func isUpdatesRoom(_ conversation: Conversation) -> Bool {
        conversation.roomSlug == "updates"
    }

    func isFeedRoom(_ conversation: Conversation) -> Bool {
        isUpdatesRoom(conversation)
    }

    /// The DM whose whole other side is the assistant.
    func isAssistantDM(_ conversation: Conversation) -> Bool {
        guard conversation.kind == "dm" else { return false }
        let others = conversation.memberIds.filter { $0 != me?.id }
        guard !others.isEmpty else { return false }
        return others.allSatisfy { people[$0].map(isAssistant) ?? false }
    }

    /// Everyone currently in any live meeting — the Meetings circle's badge.
    var liveMeetingHeadcount: Int {
        liveMeetings.reduce(0) { $0 + $1.presentParticipants.count }
    }

    /// Created/scheduled meetings whose room isn't live — live ones show as
    /// active calls instead.
    var upcomingMeetings: [Meeting] {
        meetings.filter { meeting in !liveCalls.contains { $0.meetingId == meeting.id } }
    }

    /// Everyone sees every meeting; the ones you are actually in come first.
    /// The hub's ordering is preserved inside each half.
    var sortedUpcomingMeetings: [Meeting] {
        let mine = upcomingMeetings.filter { isInvited(to: $0) }
        return mine + upcomingMeetings.filter { !isInvited(to: $0) }
    }

    func isInvited(to meeting: Meeting) -> Bool {
        guard let me else { return false }
        // A meeting from a hub that predates invites has an empty list and
        // belongs to everyone, exactly as it did before.
        return meeting.inviteePersonIds.isEmpty || meeting.inviteePersonIds.contains(me.id)
    }

    func liveCall(inConversation conversationId: String) -> Call? {
        liveCalls.first { $0.conversationId == conversationId }
    }

    func liveCall(forMeeting meetingId: String) -> Call? {
        liveCalls.first { $0.meetingId == meetingId }
    }

    private var socket: EventSocket?
    /// When this device last told each conversation it was typing.
    @ObservationIgnored private var typingSentAt: [String: Date] = [:]
    private var lastSeenMessageId: String?
    private var pendingClientIds: Set<String> = []
    private(set) var failedOutgoingMessages: [String: Message] = [:]
    private(set) var latestOutgoingMessageIDs: [String: String] = [:]
    private(set) var historyLoadErrors: [String: String] = [:]
    private var heartbeat: Timer?
    private var didOpenInitialChat = false
    private var saveTask: Task<Void, Never>?

    // MARK: Network, sync and persistence state

    // None of this is drawn by a view, so none of it is observed.

    /// The newest message id this device has told the hub it read, per
    /// conversation — or heard the hub restate as read (the echo of any of my
    /// devices). It is what lets `markVisibleRead` skip a POST the hub already
    /// has. Session-only on purpose: a stale cache must never decide that a
    /// chat someone marked unread is still read.
    @ObservationIgnored private var lastPostedRead: [String: String] = [:]
    /// Unknown conversations being fetched, so a replay that names one in many
    /// messages asks for it once.
    @ObservationIgnored private var fetchingConversationIDs: Set<String> = []
    /// The cursor the last `sync` frame went out with. A partial replay asks
    /// for the next page only if the cursor actually moved.
    @ObservationIgnored private var lastSyncSince: String?
    /// When the app last left the foreground (on the Mac: went to sleep): the
    /// socket check reads it (what the socket last heard is the socket's own
    /// `lastReceivedAt`, which a pong moves too).
    @ObservationIgnored private var lastBackgroundedAt: Date?
    #if os(macOS)
    /// The Mac's network path, watched so a socket stranded by a Wi-Fi or VPN
    /// change is probed at once, and the interfaces it last reported.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    // swiftlint:disable:next discouraged_optional_collection
    @ObservationIgnored private var lastPathInterfaces: Set<String>?
    #endif
    /// The first unsaved change since the last write; the ceiling on how long
    /// a steady stream may keep postponing a save.
    @ObservationIgnored private var firstUnsavedAt: Date?
    @ObservationIgnored private var saveSequence: UInt64 = 0
    /// False until the launch cache has been applied: a flush before then
    /// would write an empty store over the file it is still waiting to read.
    @ObservationIgnored private var hasHydrated = false
    /// The launch cache decode, started in `init` on a background task. It
    /// fills `cacheBox` as its last step, so `start()` can take the result
    /// synchronously when it is already there (the usual case: the scene's
    /// `.task` runs well after `init`) and await `cacheLoad` only when not.
    @ObservationIgnored private var cacheLoad: Task<StateSnapshot?, Never>?
    @ObservationIgnored private var cacheBox: OneShotBox<StateSnapshot?>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private let messageLoads = SingleFlight<String>()
    @ObservationIgnored private(set) var tailLoadedAt: [Tail: Date] = [:]
    /// Tail loads queued or running: a pass inside another's spread does
    /// not queue them again, since `tailLoadedAt` moves only once one lands.
    @ObservationIgnored private var tailLoadsPending: Set<Tail> = []
    /// Full refreshes failed in a row; a full success clears it.
    @ObservationIgnored private var refreshFailures = 0
    /// The projects re-read (`reloadProjects`): which frame owns the wait, when
    /// the oldest frame not yet served arrived, and the order of the requests.
    @ObservationIgnored private var projectsReloadGeneration = 0
    @ObservationIgnored private var projectsFirstUnservedAt: Date?
    @ObservationIgnored private var projectsRequestsStarted = 0
    @ObservationIgnored private var projectsRequestApplied = 0

    /// The loads `refresh()` starts after the core ones, each re-run only when
    /// its last success is old enough.
    enum Tail: CaseIterable {
        case tasks
    }

    /// How stale the tail loads may be before a reconnect repeats them.
    nonisolated static let tailMinimumAge: TimeInterval = 60

    nonisolated static func isTailStale(
        lastLoadedAt: Date?, now: Date, minimumAge: TimeInterval = tailMinimumAge
    ) -> Bool {
        guard let lastLoadedAt else { return true }
        return now.timeIntervalSince(lastLoadedAt) >= minimumAge
    }

    private func noteTailLoaded(_ tail: Tail) {
        tailLoadedAt[tail] = Date()
    }

    /// What a `refresh()` covers. `.push` is the short one: the roster,
    /// conversations, calls and the sync cursor, nothing the user is not
    /// about to look at.
    enum RefreshScope: Int {
        case push, full

        static func wider(_ lhs: Self, _ rhs: Self) -> Self {
            lhs.rawValue >= rhs.rawValue ? lhs : rhs
        }
    }

    @ObservationIgnored private lazy var refreshRunner = CoalescedRunner<RefreshScope>(
        combine: { RefreshScope.wider($0, $1) },
        perform: { [weak self] scope in await self?.performRefresh(scope) }
    )

    // MARK: - Per-conversation observation

    /// A conversation's loaded messages, oldest first. A view calling this
    /// depends on THIS conversation's messages only: a message, an agent step
    /// or a trim in any other chat does not wake it.
    func messages(in conversationId: String) -> [Message] {
        messageSlot(for: conversationId).messages
    }

    /// One conversation's row. Depends on this conversation only — a read
    /// receipt, a bump or a rename elsewhere does not wake the reader.
    func conversation(_ conversationId: String) -> Conversation? {
        conversationSlot(for: conversationId).value
    }

    /// Every loaded message by conversation, for persistence and tests. Not a
    /// view API: the getter reads every EXISTING slot, so a view that used it
    /// would be woken by those chats and miss any chat whose slot is created
    /// later — it would update for some conversations and not others. Views
    /// use `messages(in:)`.
    private(set) var messagesByConversation: [String: [Message]] {
        get { messageSlots.compactMapValues { $0.messages.isEmpty ? nil : $0.messages } }
        set {
            for id in Set(messageSlots.keys).union(newValue.keys) {
                publishMessages(newValue[id] ?? [], in: id)
            }
        }
    }

    /// The loaded messages without creating a slot or registering anything:
    /// for the store's own logic, which runs outside any view body.
    private func loadedMessages(_ conversationId: String) -> [Message] {
        messageSlots[conversationId]?.messages ?? []
    }

    private func messageSlot(for conversationId: String) -> MessageSlot {
        if let slot = messageSlots[conversationId] { return slot }
        let slot = MessageSlot()
        messageSlots[conversationId] = slot
        return slot
    }

    /// THE write path for a conversation's messages — merge, replace, move,
    /// trim, send, sync and sign-out all land here. It assigns only when the
    /// array differs (an identical write used to wake every reader and cost a
    /// full transcript pass), and runs `beforePublish` right before a real
    /// change so a caller that must snapshot the viewport does so only when
    /// rows are actually about to change under it. Returns whether it wrote.
    @discardableResult
    private func publishMessages(
        _ messages: [Message], in conversationId: String, beforePublish: () -> Void = {}
    ) -> Bool {
        let slot = messageSlot(for: conversationId)
        guard slot.messages != messages else { return false }
        beforePublish()
        slot.messages = messages
        return true
    }

    private func conversationSlot(for conversationId: String) -> ConversationSlot {
        if let slot = conversationSlots[conversationId] { return slot }
        // Seeded from the shadow: reading `conversations` here, from a view
        // body, would subscribe that view to the whole list.
        let slot = ConversationSlot(value: conversationsShadow.first { $0.id == conversationId })
        conversationSlots[conversationId] = slot
        return slot
    }

    /// Runs after every write to `conversations`: refreshes the shadow, pushes
    /// each changed row into its slot (only the slots that exist — the chats a
    /// view has asked about), and recounts the badge. It does not touch the
    /// read marks: a hub restatement says so itself (`applyRestatedReadMarks`,
    /// from the writers that take the hub's rows), and a row rebuilt locally
    /// carries the live marks in (`currentReadMarks`).
    private func conversationsDidChange() {
        conversationsShadow = conversations
        if !conversationSlots.isEmpty {
            let current = Dictionary(conversationsShadow.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for (id, slot) in conversationSlots {
                let row = current[id]
                if slot.value != row { slot.value = row }
            }
        }
        updateDockBadge()
    }

    /// Two mark lists say the same thing whatever their order.
    nonisolated static func areSameMarks(_ lhs: [ReadMark], _ rhs: [ReadMark]) -> Bool {
        lhs.count == rhs.count && Set(lhs) == Set(rhs)
    }

    /// One conversation's current read marks: the hub's last restatement with
    /// every receipt since folded in. Depends on THIS conversation's marks only.
    func readMarks(in conversationId: String) -> [ReadMark] {
        readMarkSlot(for: conversationId).marks
    }

    private func readMarkSlot(for conversationId: String) -> ReadMarkSlot {
        if let slot = readMarkSlots[conversationId] { return slot }
        let slot = ReadMarkSlot(
            marks: conversationsShadow.first { $0.id == conversationId }?.readMarks ?? []
        )
        readMarkSlots[conversationId] = slot
        return slot
    }

    /// The marks without creating a slot or registering anything.
    private func currentReadMarks(_ conversationId: String) -> [ReadMark] {
        if let slot = readMarkSlots[conversationId] { return slot.marks }
        return conversationsShadow.first { $0.id == conversationId }?.readMarks ?? []
    }

    /// A conversation this device holds a row (or live marks) for.
    private func isKnownConversation(_ conversationId: String) -> Bool {
        readMarkSlots[conversationId] != nil || conversationsShadow.contains { $0.id == conversationId }
    }

    /// The hub restated a conversation with these marks and nothing else new:
    /// they land in the slot, and the array is left alone.
    private func applyRestatedReadMarks(_ marks: [ReadMark], for conversationId: String) {
        guard isKnownConversation(conversationId),
              !Self.areSameMarks(currentReadMarks(conversationId), marks)
        else { return }
        readMarkSlot(for: conversationId).marks = marks
    }

    /// Replaces one row in place. Assigns only when it differs.
    private func writeConversation(at index: Int, _ updated: Conversation) {
        guard conversations[index] != updated else { return }
        conversations[index] = updated
    }

    private func draftSlot(for conversationId: String) -> DraftSlot {
        if let slot = draftSlots[conversationId] { return slot }
        let slot = DraftSlot()
        draftSlots[conversationId] = slot
        return slot
    }

    /// The unsent text for one conversation. Depends on that conversation's
    /// draft only: a keystroke in another chat does not wake the reader.
    func draftText(for conversationId: String) -> String {
        draftSlot(for: conversationId).text
    }

    func setDraftText(_ text: String, for conversationId: String) {
        let slot = draftSlot(for: conversationId)
        guard slot.text != text else { return }
        slot.text = text
        refreshDraftMembership(conversationId, slot)
    }

    private func setDraftAttachments(_ attachments: [Attachment], for conversationId: String) {
        let slot = draftSlot(for: conversationId)
        guard slot.attachments != attachments else { return }
        slot.attachments = attachments
        refreshDraftMembership(conversationId, slot)
    }

    /// `draftConversationIDs` changes only when a draft flips between empty
    /// and non-empty, so the phone's list filter never hears a keystroke.
    private func refreshDraftMembership(_ conversationId: String, _ slot: DraftSlot) {
        let hasDraft = !slot.attachments.isEmpty
            || slot.text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard hasDraft != draftConversationIDs.contains(conversationId) else { return }
        if hasDraft {
            draftConversationIDs.insert(conversationId)
        } else {
            draftConversationIDs.remove(conversationId)
        }
    }

    /// The roster changed. `mentionNames` and `rosterVersion` move only when
    /// the NAMES did (an avatar change leaves them alone), so the bubbles,
    /// quotes and previews that read them keep what they rendered.
    private func peopleDidChange() {
        let names = people.values.map(\.name).sorted()
        guard names != mentionNames else { return }
        mentionNames = names
        rosterVersion &+= 1
        plainTextMemo.removeAll()
    }

    // MARK: - Snapshot cache

    /// A change worth keeping. The write waits for quiet (`SaveSchedule`): a
    /// burst of live traffic, an agent's every step and a teammate's every
    /// read used to re-encode the whole cache each time activity paused for a
    /// second. A steady stream is still written within the ceiling.
    private func scheduleSave() {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled { return }
        #endif
        let now = Date()
        let first = firstUnsavedAt ?? now
        firstUnsavedAt = first
        let delay = SaveSchedule.delay(firstRequestedAt: first, now: now)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            persistSnapshot()
        }
    }

    private var shouldPersistSession: Bool {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if loadedSimulatorFixture || HQSimulatorFixture.isEnabled { return false }
        #endif
        return true
    }

    /// Builds the snapshot on the main actor and hands the encode and the
    /// write to a background task. The terminate and background flushes call
    /// this directly: they skip the wait, not the write. An unchanged snapshot
    /// is dropped by the writer (`StateCacheWriter`).
    private func persistSnapshot() {
        guard shouldPersistSession, session != nil, hasHydrated else { return }
        firstUnsavedAt = nil
        var trimmed: [String: [Message]] = [:]
        for (id, messages) in messagesByConversation {
            trimmed[id] = messages.suffix(StateCache.messagesKept)
                .filter { !$0.id.hasPrefix("pending-") }
        }
        // The rows carry the marks the hub last restated; the live ones are in
        // the mark slots. A cold start's "Read" line reads the merged value.
        let persistedConversations = conversations.map { conversation -> Conversation in
            guard let slot = readMarkSlots[conversation.id],
                  !Self.areSameMarks(slot.marks, conversation.readMarks)
            else { return conversation }
            return conversation.replacingReadMarks(slot.marks)
        }
        let snapshot = StateSnapshot(
            schemaVersion: StateCache.schemaVersion,
            people: people,
            conversations: persistedConversations,
            messagesByConversation: trimmed,
            lastSeenMessageId: lastSeenMessageId,
            agentSessions: liveThreads.hasLoaded ? liveThreads.threads : nil
        )
        saveSequence &+= 1
        let sequence = saveSequence
        Task.detached(priority: .utility) { StateCache.save(snapshot, sequence: sequence) }
    }

    var client: HQClient? {
        session.map { HQClient(bearer: $0.bearer) }
    }

    var me: Person? { session?.person }

    /// True once `start()` ran. The scene's `.task` is the usual caller, but
    /// a CallKit answer in a UI-less background launch boots the store
    /// itself — whichever comes second must be a no-op, or the app ends up
    /// with two sockets.
    private var didStart = false
    #if DEBUG && (os(macOS) || targetEnvironment(simulator))
    // Async fixture work can finish after a test restores its environment.
    // That session must never become eligible for persistent writes or cleanup.
    @ObservationIgnored private var loadedSimulatorFixture = false
    #endif

    init() {
        // Reading and decoding the cache is the slow part of launch; it starts
        // here, off the main actor, so it overlaps the first frame. Not under
        // XCTest or a UI fixture, which never read the real file (and so have
        // no cache to apply: `start()` hydrates with nothing).
        if Self.shouldPreloadCache {
            let box = OneShotBox<StateSnapshot?>()
            cacheBox = box
            cacheLoad = Task.detached(priority: .userInitiated) {
                let snapshot = StateCache.load()
                box.fill(snapshot)
                return snapshot
            }
        }
    }

    private static var shouldPreloadCache: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled { return false }
        #endif
        return true
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled {
            loadSimulatorFixture()
            return
        }
        #endif
        NotificationManager.shared.start()
        NotificationManager.shared.onOpenConversation = { [weak self] id in
            self?.openConversation(id)
        }
        NotificationManager.shared.onPushState = { [weak self] state in
            self?.reportPush(state)
        }
        NotificationManager.shared.shouldSuppressBanner = { [weak self] id in
            self?.isReadingThread(id) ?? false
        }
        NotificationManager.shared.shouldSuppressCallBanner = { [weak self] callId in
            guard let self else { return false }
            #if !os(macOS)
            // A ring CallKit owns needs no banner behind it.
            if CallKitCoordinator.shared.isRinging(callId) { return true }
            #endif
            return incomingCall?.call.id == callId || activeCallId == callId
        }
        guard let stored = Keychain.load() else { return }
        // The session is synchronous: a CallKit answer boots the store with no
        // UI and calls straight into the client.
        session = stored
        // Before the cache: a signed-in person is never shown the enrollment
        // form, and the CallKit headless boot has its session and phase now.
        phase = .ready
        NotificationCenter.default.addObserver(
            forName: Platform.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistSnapshot() }
        }
        #if !os(macOS)
        // iOS is never promised a termination callback — a suspended app is
        // killed without one. Backgrounding is the last moment that is
        // guaranteed, so that is where the phone flushes its cache.
        NotificationCenter.default.addObserver(
            forName: Platform.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastBackgroundedAt = Date()
                self?.persistSnapshot()
            }
        }
        #endif
        #if os(macOS)
        observeWakeAndNetwork()
        observeMainWindowClose()
        #endif
        // Coming back to HQ makes the visible thread read. It also rechecks
        // notification permission, which can change in System Settings while
        // the app runs.
        NotificationCenter.default.addObserver(
            forName: Platform.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The OS badge may have been refused while permission was
                // unanswered or switched off since; the next count is sent
                // again rather than skipped as unchanged.
                self.lastBadgeTotal = nil
                #if !os(macOS)
                self.revalidateSocketOnActivation()
                #endif
                if let conversationId = self.selectedConversationId {
                    self.markVisibleRead(conversationId)
                }
                await NotificationManager.shared.refresh()
                if self.hasHydrated { self.updateDockBadge() }
            }
        }
        #if os(macOS)
        // So does the main window coming back while HQ is already in front
        // ("Show Update" with the window closed, a Dock click): no activation
        // fires, and a read made before the window was up found none.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("hq-main") == true,
                      let conversationId = self.selectedConversationId
                else { return }
                self.markVisibleRead(conversationId)
            }
        }
        #endif
        hydrateFromLaunchCache()
    }

    /// How long `start()` may wait on the main thread for a cache decode that
    /// is still running. The decode began in `init`, so this is a margin for
    /// the rare launch that reaches `start()` first, not a cost of the usual
    /// one.
    static let launchCacheWait: TimeInterval = 0.05

    /// The part of launch that needs the cached state. `phase` is already
    /// `.ready` (set in `start()`, so a signed-in launch never shows the
    /// enrollment form), and the session is set: a CallKit answer in a
    /// UI-less boot can call straight into the client.
    ///
    /// Usually the decode has finished, and the cache, the first chat and the
    /// socket all land in this same turn, as they did when the decode was
    /// synchronous. If it has not finished within a short bounded wait, the
    /// list is empty for a moment and the cache is applied when it lands. The
    /// socket waits for it too, or the refresh it triggers would be
    /// overwritten with older cached rows (`performRefresh` joins this task).
    private func hydrateFromLaunchCache() {
        guard let cacheBox, let cacheLoad else {
            hydrate(with: nil)
            return
        }
        switch cacheBox.poll(waitingUpTo: Self.launchCacheWait) {
        case .landed(let cached):
            hydrate(with: cached)
        case .pending:
            startupTask = Task { [self] in
                let cached = await cacheLoad.value
                // Signed out (or in again) while the decode ran: the cache
                // belongs to the session that was.
                guard !Task.isCancelled, session != nil else { return }
                hydrate(with: cached)
            }
        }
    }

    private func hydrate(with cached: StateSnapshot?) {
        if let cached {
            // Usually nothing is loaded yet and the cache fills everything. On
            // the rare late decode, a notification tap or a badge read may
            // have landed fresher rows first: the cache fills only what is
            // still missing and never replaces them with older ones.
            if people.isEmpty { people = cached.people }
            let tookCachedRows = conversations.isEmpty
            if tookCachedRows { conversations = cached.conversations }
            var messages = cached.messagesByConversation
            messages.merge(messagesByConversation) { _, live in live }
            messagesByConversation = messages
            if lastSeenMessageId == nil { lastSeenMessageId = cached.lastSeenMessageId }
            if let threads = cached.agentSessions { liveThreads.seed(threads) }
            // A view that asked for a chat's marks before the cache landed
            // seeded its slot from the empty list. Only when the cache's rows
            // were taken: rows a fresher read landed first carry fresher marks.
            if tookCachedRows, !readMarkSlots.isEmpty {
                for row in cached.conversations { applyRestatedReadMarks(row.readMarks, for: row.id) }
            }
        }
        hasHydrated = true
        openMostRecentChat()
        connect()
    }

    /// A launch lands in the most recent chat — human, bot, whichever thread
    /// spoke last: from the cache instantly when there is one, otherwise as
    /// soon as the first roster arrives. Recency order, not the pinned
    /// sidebar order — Updates opens on launch only when it spoke last.
    private func openMostRecentChat() {
        guard !didOpenInitialChat, destination == .none else { return }
        let listed = visibleConversations
        let mostRecent = conversations.first { conversation in
            conversation.lastMessage != nil && listed.contains(conversation)
        } ?? listed.first
        guard let mostRecent else { return }
        didOpenInitialChat = true
        openConversation(mostRecent.id)
    }

    /// Signs in to `server` (what the Server field holds) with an access key. The server
    /// is remembered once the hub accepts the key; until then a refusal puts the
    /// previous one back.
    func enroll(server: String, key: String, personName: String) async {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled {
            enrollmentError = "That access key isn't valid."
            return
        }
        #endif
        enrollmentError = nil
        let normalized: String
        switch HQConfig.normalizedServer(server) {
        case .success(let value): normalized = value
        case .failure(let problem):
            enrollmentError = problem.message
            return
        }
        let previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
        do {
            let response = try await HQClient.enroll(
                key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                personName: personName.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceName: Platform.deviceName
            )
            let stored = StoredSession(
                bearer: response.bearer, deviceId: response.deviceId, person: response.person
            )
            // A session that cannot be stored is a session that ends at the
            // next launch. Say so now, while the person is still here, rather
            // than presenting the access-key screen again tomorrow as if
            // nothing happened.
            Keychain.save(stored)
            isSessionPersisted = Keychain.isPersisted
            session = stored
            phase = .ready
            // A fresh sign-in has no cache to wait for.
            hasHydrated = true
            connect()
            // A push state settled before enrollment had no bearer to ride.
            reportPush(NotificationManager.shared.state)
        } catch {
            HQConfig.savedServer = previousServer
            enrollmentError = error.localizedDescription
        }
    }

    #if DEBUG
    // Debug builds sign with a development profile, so their tokens are
    // sandbox tokens; the server picks the APNs host per token from this.
    // A Release build signed with a development profile mislabels itself.
    static let apnsEnvironment = "development"
    #else
    static let apnsEnvironment = "production"
    #endif

    /// Tells the server this device's push standing. Best effort: a server
    /// without push answers 404, which changes nothing else. A build with no
    /// team never reports. Reports run one after another, and sign-out's
    /// DELETE waits for the last one, so a late report cannot re-attach a
    /// token after sign-out.
    func reportPush(_ state: PushState) {
        let authorizationChanged = pushState.authorization != state.authorization
        pushState = state
        if authorizationChanged {
            // A badge count set while permission was unanswered (or off) was
            // dropped by the OS; the same total would be skipped as "already
            // sent", leaving the icon blank until the count moved.
            lastBadgeTotal = nil
            // Before the launch cache is applied the list is empty and the
            // total would be a false zero; applying the cache counts anyway.
            if hasHydrated { updateDockBadge() }
        }
        guard PushState.isBuilt, let client else { return }
        let previous = pushReportTask
        pushReportTask = Task {
            await previous?.value
            try? await client.reportPush(
                status: state.wire, token: state.token, voipToken: state.voipToken,
                environment: Self.apnsEnvironment
            )
        }
    }

    func signOut() {
        #if os(macOS)
        settings.reset()
        // Stops the session-sync helper; Pause (if the person chose it) is kept.
        SessionSyncAgent.disable()
        // The desktop widgets' key ends on the server and their shelf is emptied.
        WidgetSync.shared.stop()
        #endif
        // Best effort: a signed-out device must stop hearing the team's pushes
        // even though its device row survives for revocation bookkeeping. If
        // this never arrives (offline), the server must still stop pushing to
        // a revoked device; see docs/push.md.
        let pendingReport = pushReportTask
        pushReportTask = nil
        if PushState.isBuilt, shouldPersistSession, let client {
            Task {
                await pendingReport?.value
                try? await client.unregisterPushToken()
            }
        }
        stopHeartbeat()
        Task { await callEngine.leave() }
        socket?.stop()
        socket = nil
        saveTask?.cancel()
        firstUnsavedAt = nil
        startupTask?.cancel()
        // A sleeping reload finds its generation gone; one in flight is
        // dropped by the device check when it lands.
        projectsReloadGeneration &+= 1
        projectsFirstUnservedAt = nil
        liveThreads = LiveThreadsStore()
        for slot in readMarkSlots.values where !slot.marks.isEmpty { slot.marks = [] }
        fetchingConversationIDs = []
        lastPostedRead = [:]
        forgetRefreshState()
        lastSeenMessageId = nil
        lastSyncSince = nil
        if shouldPersistSession {
            saveSequence &+= 1
            StateCache.clear(atSequence: saveSequence)
            NotificationManager.shared.resetReadCursors()
            Keychain.clear()
        }
        // Whatever an earlier request left in the shared HTTP cache leaves
        // with the person who signed out.
        URLCache.shared.removeAllCachedResponses()
        didOpenInitialChat = false
        session = nil
        phase = .enrolling
        people = [:]
        conversations = []
        messagesByConversation = [:]
        textDrafts = [:]
        failedOutgoingMessages = [:]
        latestOutgoingMessageIDs = [:]
        historyLoadErrors = [:]
        pendingClientIds = []
        for id in Array(draftSlots.keys) { setDraftAttachments([], for: id) }
        replyTarget = nil
        onlinePersonIds = []
        calls = []
        meetings = []
        activeCallId = nil
        destination = .none
        isDetailPanelOpen = false
    }

    // MARK: - Loading

    private func connect() {
        guard let session else { return }
        socket = EventSocket(
            bearer: session.bearer,
            onConnect: { [weak self] in
                guard let self else { return }
                socketDidConnect(isLive: socket?.isLive == true) { self.socket?.send($0) }
                #if os(macOS)
                if let session = self.session { WidgetSync.shared.start(bearer: session.bearer, personId: session.person.id, deviceId: session.deviceId) }
                #endif
            },
            onFrame: { [weak self] frame in
                self?.handle(frame)
            }
        )
        socket?.connect()
    }

    /// The socket opened (`isLive`), or a failure streak spent its one
    /// refresh with the socket still down. Internal so the store's tests can
    /// drive it with their own `send`.
    func socketDidConnect(isLive: Bool, send: ([String: Any]) -> Void) {
        // The seat may be inside its socket-loss grace: vouch for it
        // first, before the refresh round trips.
        if let callId = activeCallId {
            send(["type": "call_heartbeat", "call_id": callId])
        }
        // Catch up now, from the cursor as it stood when the socket dropped:
        // the hub broadcasts to this socket from `hello` on, and a live frame
        // landing during the refresh's round trips would move the cursor past
        // everything missed. The refresh still sends its own sync, which
        // seeds a device with no cursor; the two replays dedupe by id.
        if isLive, lastSeenMessageId != nil {
            send(syncFrame())
        }
        Task { await self.refresh() }
        guard isLive else { return }
        // The replay carries new rows only: an edit, an unsend, a tapback or
        // a step of an assistant's work row made while the socket was down reaches no
        // one. The open chat and the call's chat re-read their newest page;
        // a page that changed nothing publishes nothing.
        let open = selectedConversationId
        let callRoom = activeCall?.conversationId
        for id in [open, callRoom == open ? nil : callRoom].compactMap({ $0 }) {
            Task { await self.loadMessages(id) }
        }
    }

    /// Re-reads what the socket may have missed. One at a time: a reconnect, a
    /// push, a call ending and a pull-to-refresh that land together are one
    /// pass and at most one catch-up (`CoalescedRunner`). The people,
    /// conversations and calls are read every time; the tail (tasks and
    /// projects) only when its last success is a minute old, so a flapping
    /// connection stops repeating requests per attempt.
    func refresh() async {
        await refresh(scope: .full)
    }

    func refresh(scope: RefreshScope) async {
        await refreshRunner.run(scope)
    }

    private func performRefresh(_ scope: RefreshScope) async {
        // A launch still applying its cache must finish first: this pass's
        // answer would otherwise be overwritten by older cached rows.
        if let startupTask { await startupTask.value }
        guard let client, let deviceId = session?.deviceId else { return }
        do {
            async let peopleTask = client.people()
            async let conversationsTask = client.conversations()
            async let callsTask = client.calls()
            let (peopleList, conversationList, snapshot) = try await (peopleTask, conversationsTask, callsTask)
            // Signed out (or switched) while the round trips were out: their
            // answers belong to nobody now.
            guard session?.deviceId == deviceId else { return }
            // Only a full pass also reads the tails, so only it settles what
            // a failed full pass's retry still owes.
            if scope == .full { refreshFailures = 0 }
            // Each is assigned only when the hub's answer differs: a reconnect,
            // a push and a pull-to-refresh all re-read an unchanged roster, and
            // an assignment notifies every reader whether or not it changed.
            assignIfChanged(\.people, Dictionary(uniqueKeysWithValues: peopleList.map { ($0.id, $0) }))
            // `me` reads the enrollment session, which no event refreshes when
            // the hub changes this person without a write of their own (a
            // schema step granting `can_hire`, say). The list is the hub's
            // word, so a changed self row lands in the session too.
            if let session, let fresh = people[session.person.id], fresh != session.person {
                notePersonUpdated(fresh)
            }
            applyFreshConversations(conversationList)
            // A device with no cursor (a first launch, a signed-in-again
            // phone, a cache that failed to decode) would ask the hub to
            // replay its history from the very start, 500 messages a page.
            // The list just read already says where "now" is.
            if lastSeenMessageId == nil, let newest = conversationList.compactMap({ $0.lastMessage?.id }).max() {
                lastSeenMessageId = newest
            }
            clearNotificationsRead(in: conversationList)
            await applyFreshCalls(snapshot)
            openMostRecentChat()
            scheduleSave()
            // The roster and the rows were all assigned
            // above, and the badge counts across them: one recount, deduped.
            updateDockBadge()
            // Catch up anything missed while disconnected.
            socket?.send(syncFrame())
            if scope == .full { startStaleTailLoads() }
        } catch let error as APIError {
            // A revoked bearer forces re-enrollment; anything else is transient.
            storeLog.warning("refresh failed: api error \(error.code, privacy: .public)")
            if error.code == "unauthorized" {
                signOut()
            } else {
                scheduleRefreshRetry(after: scope, deviceId: deviceId)
            }
        } catch {
            // Transient network failure: retried like a transient API error.
            storeLog.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
            scheduleRefreshRetry(after: scope, deviceId: deviceId)
        }
    }

    /// How long after the Nth full refresh failed in a row the next is tried:
    /// twice, then it waits for the next reconnect, push or call ending.
    nonisolated static func refreshRetryDelay(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case 1: return 5
        case 2: return 30
        default: return nil
        }
    }

    /// While the socket stays up nothing else re-reads the list, the calls or
    /// the badges, so one transient error after a reconnect left them stale
    /// until the next drop. A `.push` refresh is never retried.
    private func scheduleRefreshRetry(after scope: RefreshScope, deviceId: String) {
        guard scope == .full else { return }
        refreshFailures += 1
        guard let delay = Self.refreshRetryDelay(afterFailures: refreshFailures) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.didRunRefreshRetry(deviceId: deviceId)
        }
    }

    /// A scheduled retry, once its wait is over. Says whether it refreshed.
    /// A full refresh that succeeded meanwhile (the socket came back)
    /// already did its work: after a hub deploy every device would otherwise
    /// repeat the whole refresh at the same moment. Internal so the store's
    /// tests can run one without the wait.
    @discardableResult
    func didRunRefreshRetry(deviceId: String) async -> Bool {
        guard session?.deviceId == deviceId, refreshFailures > 0 else { return false }
        await refresh(scope: .full)
        return true
    }

    /// Sign-out: the next session's first full refresh owes nothing to this
    /// one's loads or failures. Internal so the store's tests can run it
    /// without signOut, which also clears the shared widget shelf.
    func forgetRefreshState() {
        tailLoadedAt = [:]
        tailLoadsPending = []
        refreshFailures = 0
    }

    /// Banners for what this person has already read, on any device.
    private func clearNotificationsRead(in conversationList: [Conversation]) {
        guard let personId = me?.id else { return }
        let cursors = Dictionary(conversationList.compactMap { conversation in
            conversation.readMarks.first(where: { $0.personId == personId }).map {
                (conversation.id, $0.lastReadMessageId)
            }
        }, uniquingKeysWith: { _, last in last })
        NotificationManager.shared.clearMessageNotifications(readThrough: cursors)
    }

    private func applyFreshCalls(_ snapshot: HQClient.CallsSnapshot) async {
        assignIfChanged(\.calls, snapshot.calls)
        assignIfChanged(\.meetings, snapshot.meetings)
        // A call that ended while the socket was down never sends its
        // call_ended frame. Left unreconciled, the dead call held
        // activeCallId forever — an empty stage, a stale "In a call"
        // banner, and every new call blocked until relaunch.
        if let staleId = activeCallId, calls.first(where: { $0.id == staleId })?.isLive != true {
            if calls.contains(where: { $0.id == staleId }) {
                endCall(staleId)
            } else {
                Task { await self.leaveCall() }
            }
        }
        if let ring = snapshot.ringing.first { startRinging(ring) }
        // `calls` was replaced wholesale, which is exactly the path that
        // does NOT go through upsert(call:) and so never re-subscribed.
        // Anyone who re-seated while this socket was down is in the new
        // roster under a new media session, and until the engine is told,
        // their tile stays frozen and their audio silent — for as long as
        // the roster then happens not to change. A server deploy that drops
        // every socket at once costs the meeting minutes exactly here.
        if activeCallId != nil { await syncCallMedia() }
    }

    /// The loads behind the badges that nothing else keeps current. Each is
    /// started only when its own last success is old; a page that loaded it
    /// meanwhile counts, so opening Tasks then reconnecting reads it once.
    /// Says which it started; internal so the store's tests can call it.
    @discardableResult
    func startStaleTailLoads() -> [Tail] {
        let now = Date()
        var started: [Tail] = []
        func isStale(_ tail: Tail) -> Bool { Self.isTailStale(lastLoadedAt: tailLoadedAt[tail], now: now) }
        // A hub deploy drops every device at once, and they all reconnect
        // in the same second: the heavy reads are spread over a few seconds
        // rather than landing on the hub together.
        let delay = Self.tailStartDelay(random: Double.random(in: 0...1))
        func start(_ tail: Tail, _ load: @escaping @MainActor () async -> Void) {
            guard isStale(tail), tailLoadsPending.insert(tail).inserted else { return }
            started.append(tail)
            Task {
                try? await Task.sleep(for: .seconds(delay))
                await load()
                // Landed or failed: a failure is stale again for the next pass.
                tailLoadsPending.remove(tail)
            }
        }
        // Tasks otherwise load only when the Tasks page opens, leaving
        // the pinned circle's badge blank on a cold start, and a page opened
        // while the hub was away would otherwise keep its empty answer after
        // it came back.
        start(.tasks) { await self.loadTasks() }
        return started
    }

    /// The longest a reconnect's tail loads wait to start.
    nonisolated static let tailStartSpread: TimeInterval = 8

    /// `random` in 0...1 maps onto 0...`tailStartSpread` seconds.
    nonisolated static func tailStartDelay(random: Double) -> TimeInterval {
        min(max(random, 0), 1) * tailStartSpread
    }

    /// Takes the hub's conversation list. When it differs from what is held
    /// only in the read marks (every receipt since the last read of the list
    /// does that), the array is left alone — the marks go to their own slots,
    /// so the sidebar and the phone's list are not rebuilt for a mark none of
    /// them draws.
    private func applyFreshConversations(_ list: [Conversation]) {
        if !Self.areSameExceptReadMarks(conversations, list) {
            assignIfChanged(\.conversations, list)
        }
        // The hub's list is the authority on the marks, whatever else it
        // changed: a mark that moved backward (someone marked a chat unread)
        // must not stay at a receipt's later value.
        for row in list { applyRestatedReadMarks(row.readMarks, for: row.id) }
    }

    /// The home-screen badge only: what a background read-sync push needs.
    /// The unread counts come from the server's list; nothing else is read.
    func refreshBadgeOnly() async {
        guard let client, let deviceId = session?.deviceId,
              let list = try? await client.conversations(),
              session?.deviceId == deviceId
        else { return }
        applyFreshConversations(list)
        updateDockBadge()
    }

    /// An iOS remote notification woke the app. A read-sync push (another
    /// device read a thread) reads only
    /// the conversation list: the socket's `read` frame moves the read marks
    /// but not the unread counts, and the server's list is where they come
    /// from, in the foreground (the dot and count on screen) and the
    /// background (the home-screen badge) alike. Any other push refreshes
    /// conversations, the roster, calls and the sync cursor, not the tail
    /// loads, which would spend the push's few seconds on pages nobody is
    /// looking at.
    func handleRemotePush(isReadSync: Bool) async {
        if isReadSync {
            await refreshBadgeOnly()
        } else {
            await refresh(scope: .push)
        }
    }

    nonisolated static func areSameExceptReadMarks(_ lhs: [Conversation], _ rhs: [Conversation]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.isSameExceptReadMarks($1) }
    }

    /// Whether the socket has delivered a frame since it last connected. A
    /// point-in-time read: it changes without any observation.
    var isSocketLive: Bool { socket?.isLive == true }

    /// Assigns a property only when the new value differs. Under the
    /// `@Observable` macro of Swift 6.2 and later (every Xcode 26), a plain
    /// set of an equal `Equatable` value already wakes no reader, so for a
    /// whole value this guard only spares the store write. A subscript or
    /// in-place write (`dict[key] = value`, `list[i] = x`, `value?.field = y`)
    /// goes through `_modify` and wakes every reader even when it changes
    /// nothing; those need their own check at the call site.
    private func assignIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func syncFrame() -> [String: Any] {
        var frame: [String: Any] = ["type": "sync"]
        if let lastSeenMessageId { frame["since_message_id"] = lastSeenMessageId }
        lastSyncSince = lastSeenMessageId
        return frame
    }

    /// The phone's socket dies silently while the app is suspended, and the
    /// Mac's across a sleep or a network change, and nothing says so until a
    /// receive fails or the 75-second silence check fires — a stale chat for
    /// a minute after unlocking or opening the lid. On activation or wake: a
    /// socket that is not live is left alone while it is mid-handshake or
    /// waiting out its own backoff (it reconnects by itself, and replacing it
    /// starts the backoff over at attempt 0 — every app switch during an
    /// outage would hit the hub) and replaced only when its handshake has hung
    /// (`EventSocketForegroundPolicy`); one that is live but was away more than
    /// ten seconds (or, `force`, whose network changed) is asked to sync,
    /// which the hub always answers (`sync_complete`), and replaced if nothing
    /// at all (a frame or a pong) comes back within the probe window.
    /// Replacing means a fresh `EventSocket`; the old one is stopped, so its
    /// scheduled retry does nothing.
    private func revalidateSocketOnActivation(force: Bool = false) {
        guard session != nil, hasHydrated else { return }
        guard let current = socket else {
            replaceSocket()
            return
        }
        guard current.isLive else {
            if EventSocketForegroundPolicy.shouldReplaceSocketThatIsNotLive(
                attemptStartedAt: current.attemptStartedAt, isWaitingToRetry: current.isWaitingToRetry,
                now: Date()
            ) {
                replaceSocket()
            }
            return
        }
        guard EventSocketForegroundPolicy.shouldProbeLiveSocket(
            awaySince: lastBackgroundedAt, now: Date(), force: force
        ) else { return }
        lastBackgroundedAt = nil
        let probeStart = Date()
        current.send(syncFrame())
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(EventSocketForegroundPolicy.probeWindow))
            if self.socket === current, current.lastReceivedAt < probeStart {
                storeLog.warning("socket silent after foreground sync probe; reconnecting")
                self.replaceSocket()
            }
        }
    }

    private func replaceSocket() {
        socket?.stop()
        socket = nil
        connect()
    }

    #if os(macOS)
    /// The Mac's two moments a socket goes half-open without a word: a sleep
    /// (probed on wake by the phone's ten-second rule) and a network path
    /// that came back on other interfaces (probed at once). Both run the
    /// check above, so a socket mid-handshake or in its own backoff is left
    /// alone, and a second probe finds the socket already replaced.
    private func observeWakeAndNetwork() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastBackgroundedAt = Date() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidateSocketOnActivation() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = Set(path.availableInterfaces.map(\.name))
            let isSatisfied = path.status == .satisfied
            MainActor.assumeIsolated { self?.notePath(interfaces: interfaces, isSatisfied: isSatisfied) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// The first report only records where the Mac is; a later satisfied one
    /// on a different set of interfaces probes the socket.
    private func notePath(interfaces: Set<String>, isSatisfied: Bool) {
        defer { lastPathInterfaces = interfaces }
        guard isSatisfied, let last = lastPathInterfaces, last != interfaces else { return }
        revalidateSocketOnActivation(force: true)
    }
    #endif

    /// Arrow-key navigation over the sidebar's order, driven from the
    /// composer: up is the previous row, down the next, ends stop.
    func selectAdjacentConversation(_ offset: Int, pinnedIDs: [String] = []) {
        let pinned = pinnedConversations(ids: pinnedIDs)
        let visible = pinned + visibleConversations.filter { !pinnedIDs.contains($0.id) }
        guard !visible.isEmpty else { return }
        guard let currentIndex = visible.firstIndex(where: { $0.id == selectedConversationId })
        else {
            openConversation(visible[0].id)
            return
        }
        let next = currentIndex + offset
        guard visible.indices.contains(next) else { return }
        openConversation(visible[next].id)
    }

    func openConversation(_ id: String) {
        selectedConversationId = id
        lastConversationId = id
        markVisibleRead(id)
        Task { await loadMessages(id) }
    }

    /// Opening a chat asks for its newest page from several places at once (the
    /// store's own open, and on the phone the transcript's `.task`): one
    /// request is made per conversation, and a second caller waits for it
    /// instead of fetching, merging and publishing the same page again. A
    /// caller that arrives after it finished starts a fresh read.
    func loadMessages(_ conversationId: String) async {
        await messageLoads.run(conversationId) { [self] in
            await readNewestMessages(of: conversationId)
        }
    }

    private func readNewestMessages(of conversationId: String) async {
        guard let client else { return }
        guard let loaded = try? await client.messages(conversationId: conversationId, before: nil) else { return }
        // A short first page IS the whole history. Without this, a thread
        // shorter than the viewport never scrolls, the scroll-triggered pager
        // never runs, and the history spinner at the top spins forever.
        if loaded.count < 50 { exhaustedHistory.insert(conversationId) }
        merge(messages: loaded, into: conversationId)
        markVisibleRead(conversationId)
    }

    // MARK: - Sending

    // The conversation is the caller's, never the sidebar selection: the
    // in-call chat panel sends into the meeting room while the main window
    // has something else selected.
    func send(_ content: String, in conversationId: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = drafts(in: conversationId)
        guard client != nil, let me else { return }
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let clientMsgId = UUID().uuidString.lowercased()
        let reply = replyTarget?.conversationId == conversationId ? replyTarget : nil
        pendingClientIds.insert(clientMsgId)
        setDraftAttachments([], for: conversationId)
        attachmentErrors[conversationId] = nil
        setDraftText("", for: conversationId)
        // Recipients drop the indicator when the message lands, so the next
        // keystroke announces again rather than waiting out the interval.
        typingSentAt[conversationId] = nil
        if reply != nil { replyTarget = nil }
        // Optimistic row: a temp id sorting after everything current.
        let optimistic = Message(
            id: "pending-\(clientMsgId)",
            conversationId: conversationId,
            senderPersonId: me.id,
            senderName: me.name,
            content: text,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            replyTo: reply.map {
                ReplyStub(id: $0.id, content: $0.previewText, senderName: $0.senderName)
            },
            attachments: attachments
        )
        publishMessages(loadedMessages(conversationId) + [optimistic], in: conversationId)
        latestOutgoingMessageIDs[conversationId] = optimistic.id
        deliver(optimistic, clientMsgId: clientMsgId)
    }

    func retrySend(_ message: Message) {
        guard failedOutgoingMessages[message.id] != nil else { return }
        let clientMsgId = String(message.id.dropFirst("pending-".count))
        guard !pendingClientIds.contains(clientMsgId), client != nil else { return }
        failedOutgoingMessages[message.id] = nil
        pendingClientIds.insert(clientMsgId)
        deliver(message, clientMsgId: clientMsgId)
    }

    private func deliver(_ outgoing: Message, clientMsgId: String) {
        guard let client, let deviceId = session?.deviceId else { return }
        Task {
            do {
                let message = try await client.send(
                    conversationId: outgoing.conversationId, clientMsgId: clientMsgId,
                    content: outgoing.content, replyToMessageId: outgoing.replyTo?.id,
                    attachmentIds: outgoing.attachments.map(\.id)
                )
                guard session?.deviceId == deviceId else { return }
                replacePending(clientMsgId: clientMsgId, with: message)
            } catch {
                guard session?.deviceId == deviceId else { return }
                if pendingClientIds.remove(clientMsgId) == nil {
                    // An echo of mine already stood for this send. When the
                    // error may hide a stored message (its reply was lost or
                    // the hub failed after storing it), that echo was it.
                    // Otherwise the hub refused it or never got it, and the
                    // echo was another send of mine with the same words: the
                    // row comes back, marked "Not sent".
                    guard !Self.isSendPossiblyStored(after: error) else { return }
                    merge(messages: [outgoing], into: outgoing.conversationId)
                }
                failedOutgoingMessages[outgoing.id] = outgoing
            }
        }
    }

    /// Whether a send that threw may still have been stored by the hub: its
    /// reply timed out or the connection dropped mid-answer, the reply came
    /// back unreadable, or the hub failed after storing it (it broadcasts the
    /// echo before it answers, so a 5xx can follow a stored message). A 4xx
    /// refusal or a request that never left stored nothing.
    nonisolated static func isSendPossiblyStored(after error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost].contains(error.code)
        }
        if let error = error as? APIError { return error.status >= 500 }
        return error is DecodingError
    }

    /// Typing broadcasts are a courtesy, not a keystroke log: the hub shows one
    /// for five seconds, so a frame every few seconds says the same thing as
    /// one per character. Throttled here so every composer shares the rule.
    func sendTyping(in conversationId: String) {
        let now = Date()
        guard Self.shouldSendTyping(lastSentAt: typingSentAt[conversationId], now: now) else { return }
        typingSentAt[conversationId] = now
        socket?.send(["type": "typing", "conversation_id": conversationId])
    }

    /// Shorter than the hub's five-second expiry, so steady typing never flickers.
    nonisolated static let typingInterval: TimeInterval = 3

    nonisolated static func shouldSendTyping(lastSentAt: Date?, now: Date) -> Bool {
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= typingInterval
    }

    func startDM(with personId: String) async {
        guard let client else { return }
        guard let conversation = try? await client.createDM(personId: personId) else { return }
        upsert(conversation: conversation)
        openConversation(conversation.id)
    }

    func createGroup(title: String?, personIds: [String]) async {
        guard let client else { return }
        guard let conversation = try? await client.createGroup(title: title, personIds: personIds) else { return }
        upsert(conversation: conversation)
        openConversation(conversation.id)
    }

    // MARK: - Message actions

    func react(to message: Message, emoji: String) {
        guard let client else { return }
        Task {
            if let updated = try? await client.react(messageId: message.id, emoji: emoji) {
                replace(updated)
            }
        }
    }

    func edit(_ message: Message, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty, trimmed != message.content else { return }
        Task {
            if let updated = try? await client.edit(messageId: message.id, content: trimmed) {
                replace(updated)
            }
        }
    }

    func unsend(_ message: Message) {
        guard let client else { return }
        Task {
            if let updated = try? await client.unsend(messageId: message.id) {
                replace(updated)
            }
        }
    }

    /// "Forward…" — the message's text sent into another conversation as a
    /// fresh message of mine.
    func forward(_ message: Message, to conversationId: String) {
        guard let client, !message.content.isEmpty else { return }
        Task {
            let sent = try? await client.send(
                conversationId: conversationId,
                clientMsgId: UUID().uuidString.lowercased(),
                content: message.content,
                replyToMessageId: nil,
                attachmentIds: []
            )
            if let sent { ingest(sent) }
        }
    }

    // The server refuses bodies over 100 MB and sends over 10 attachments;
    // catching both here turns a silent vanish into a visible refusal.
    private static let maxUploadBytes = 100 * 1024 * 1024
    private static let maxAttachmentsPerMessage = 10
    /// An upload up to this size is kept on disk for its own thumbnail.
    private static let seededUploadLimit = 20 * 1024 * 1024

    /// The task finishes when every file has been read and uploaded (or
    /// refused); a caller that must clean up after the files — the phone's
    /// picked-video copy — waits on it.
    @discardableResult
    func attach(fileURLs: [URL], in conversationId: String) -> Task<Void, Never> {
        guard let client else { return Task {} }
        attachmentErrors[conversationId] = nil
        uploadingCounts[conversationId, default: 0] += 1
        return Task {
            defer { uploadingCounts[conversationId, default: 1] -= 1 }
            for url in fileURLs {
                // Size first: a multi-gigabyte video picked on the phone used
                // to be read whole before the 100 MB refusal could show.
                if let size = Self.fileSize(of: url), size > Self.maxUploadBytes {
                    attachmentErrors[conversationId] = "\(url.lastPathComponent) is over 100 MB"
                    continue
                }
                // Read off the main actor, mapped rather than copied, with the
                // security-scoped access held open until the read returns.
                guard let file = await Self.readFile(at: url) else {
                    attachmentErrors[conversationId] = "Couldn't read \(url.lastPathComponent)"
                    continue
                }
                await upload(
                    data: file.data,
                    fileName: file.name,
                    contentType: file.contentType,
                    in: conversationId,
                    client: client
                )
            }
        }
    }

    private nonisolated static func fileSize(of url: URL) -> Int? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private struct PickedFile: Sendable {
        let data: Data
        let name: String
        let contentType: String
    }

    private nonisolated static func readFile(at url: URL) async -> PickedFile? {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let typed = Self.typed(name: url.lastPathComponent, data: data)
            return PickedFile(data: data, name: typed.name, contentType: typed.contentType)
        }.value
    }

    func attach(imageData: Data, fileName: String, contentType: String, in conversationId: String) {
        guard let client else { return }
        attachmentErrors[conversationId] = nil
        uploadingCounts[conversationId, default: 0] += 1
        Task {
            defer { uploadingCounts[conversationId, default: 1] -= 1 }
            await upload(
                data: imageData, fileName: fileName, contentType: contentType,
                in: conversationId, client: client
            )
        }
    }

    private func upload(
        data: Data, fileName: String, contentType: String, in conversationId: String,
        client: HQClient
    ) async {
        guard data.count <= Self.maxUploadBytes else {
            attachmentErrors[conversationId] = "\(fileName) is over 100 MB"
            return
        }
        guard drafts(in: conversationId).count < Self.maxAttachmentsPerMessage else {
            attachmentErrors[conversationId] = "10 attachments per message"
            return
        }
        do {
            let uploaded = try await client.upload(
                conversationId: conversationId,
                data: data,
                fileName: fileName,
                contentType: contentType,
                pixelSize: Self.pixelSize(of: data)
            )
            // The draft chip draws this very file; without the bytes on disk
            // it would download what was just sent. Written off the main
            // actor and atomically by the cache. Not for the big ones: a
            // video or an archive is not drawn in the chip.
            if data.count <= Self.seededUploadLimit {
                AttachmentFileCache.shared.seed(uploaded, data: data)
            }
            setDraftAttachments(drafts(in: conversationId) + [uploaded], for: conversationId)
        } catch {
            attachmentErrors[conversationId] = "Upload of \(fileName) failed"
        }
    }

    // For failures that happen before the store ever sees bytes — the iOS
    // photo picker loading an item, say — so they land in the same strip.
    func noteAttachmentFailure(_ message: String, in conversationId: String) {
        attachmentErrors[conversationId] = message
    }

    /// The attachments staged for one conversation. Depends on that
    /// conversation's draft only.
    func drafts(in conversationId: String) -> [Attachment] {
        draftSlot(for: conversationId).attachments
    }

    func isUploading(in conversationId: String) -> Bool {
        uploadingCounts[conversationId, default: 0] > 0
    }

    func removeDraft(_ attachment: Attachment, in conversationId: String) {
        setDraftAttachments(
            drafts(in: conversationId).filter { $0.id != attachment.id }, for: conversationId
        )
    }

    // A promised drop (Slack, some browsers, Mail) often lands as a bare
    // "file" with no extension. Typed by its name alone, an image would ride
    // as an octet-stream document forever — never a photo bubble, and never
    // previewable. The bytes know better, so they get the last word.
    private nonisolated static func typed(name: String, data: Data) -> (name: String, contentType: String) {
        if let named = UTType(filenameExtension: (name as NSString).pathExtension),
           let mime = named.preferredMIMEType {
            return (name, mime)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let sniffed = UTType(identifier),
              let mime = sniffed.preferredMIMEType,
              let fileExtension = sniffed.preferredFilenameExtension
        else { return (name, "application/octet-stream") }
        let base = (name as NSString).deletingPathExtension
        return ("\(base.isEmpty ? "image" : base).\(fileExtension)", mime)
    }

    // Read straight out of the image header rather than through a platform
    // image class: the bytes carry the dimensions, both platforms have
    // ImageIO, and nothing has to decode a 40-megapixel photo to learn how
    // wide it is.
    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Search

    func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, query.count >= 2 else {
            searchResults = []
            return
        }
        let results = (try? await client.search(query: query)) ?? []
        guard !Task.isCancelled,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        searchResults = results
    }

    func openSearchResult(conversationId: String, messageId: String) async {
        searchQuery = ""
        selectedConversationId = conversationId
        lastConversationId = conversationId
        await loadMessages(conversationId)
        guard selectedConversationId == conversationId else { return }
        messageJump = MessageJump(conversationId: conversationId, messageId: messageId)
    }

    // MARK: - History

    func loadOlder(
        in conversationId: String,
        willPrepend: () -> Void = {}
    ) async {
        guard let client, !isLoadingOlder, !exhaustedHistory.contains(conversationId) else { return }
        guard let oldest = loadedMessages(conversationId).first(where: { !$0.id.hasPrefix("pending-") }),
              let deviceId = session?.deviceId else { return }
        isLoadingOlder = true
        historyLoadErrors[conversationId] = nil
        defer { isLoadingOlder = false }
        let older: [Message]
        do {
            older = try await client.messages(conversationId: conversationId, before: oldest.id)
        } catch {
            if session?.deviceId == deviceId { historyLoadErrors[conversationId] = "Couldn’t load earlier messages." }
            return
        }
        guard session?.deviceId == deviceId else { return }
        // A trim while the page was loading (the window closed, the chat
        // was left) moved the oldest row: the page would land above a gap,
        // and an empty one would wrongly end the history.
        guard loadedMessages(conversationId).first(where: { !$0.id.hasPrefix("pending-") })?.id == oldest.id
        else { return }
        if older.isEmpty {
            exhaustedHistory.insert(conversationId)
            return
        }
        // A native transcript can snapshot its live viewport after the
        // network wait but immediately before these rows change its layout.
        // Keeping that timing here avoids freezing a person's scroll while
        // the request is in flight. And only when the page changes rows: a
        // snapshot taken for a page that adds nothing would be applied to
        // the next unrelated layout change instead.
        merge(messages: older, into: conversationId, beforePublish: willPrepend)
    }

    /// The loaded window is `StateCache.messagesKept` — the same trailing
    /// stretch a cold start hydrates. Anything a thread accumulates beyond
    /// it (a deep scroll-back, a day of live traffic) is dropped once
    /// nothing is showing the thread; scrolling up simply re-pages it from
    /// the server. The selected thread, the active call's in-call chat and
    /// any transcript on screen (the meeting window shows a chat that is not
    /// selected) are left alone — trimming under a reader would yank their
    /// scroll. Returns how many rows it dropped.
    @discardableResult
    private func trimLoadedHistory(of conversationId: String) -> Int {
        guard conversationId != selectedConversationId,
              conversationId != activeCall?.conversationId,
              visibleTranscripts[conversationId] == nil
        else { return 0 }
        return trimToWindow(conversationId)
    }

    /// Transcripts on screen, counted by chat: the main window, the meeting
    /// window each show one, and two can show the
    /// same chat. Registered by `ChatView`; read only by the trims.
    @ObservationIgnored private var visibleTranscripts: [String: Int] = [:]

    func transcriptAppeared(_ conversationId: String) {
        visibleTranscripts[conversationId, default: 0] += 1
    }

    func transcriptDisappeared(_ conversationId: String) {
        guard let count = visibleTranscripts[conversationId] else { return }
        guard count == 1 else {
            visibleTranscripts[conversationId] = count - 1
            return
        }
        visibleTranscripts[conversationId] = nil
        // The last transcript on the chat is gone. On the phone that can be
        // after the back animation, so after the turn `destination`'s trim
        // ran and skipped it as still on screen: trim it now, a turn later
        // for the same reason.
        Task { @MainActor in self.trimLoadedHistory(of: conversationId) }
    }

    /// How far past the window a pinned transcript may grow before it is
    /// trimmed: one page, so a person reading the bottom never pays a trim
    /// per message.
    static let pinnedTrimSlack = 50

    /// The open chat's trim. A transcript pinned to its newest message never
    /// shows the rows far above it, yet each one is a laid-out bubble with
    /// its own text stack, and scroll-backs and a day of traffic pile them
    /// up for as long as the chat stays open. Called from `ChatView`'s
    /// updates, so the trim waits a turn, as `destination`'s does, and checks
    /// again then: the pin, no second transcript on the chat (it may be
    /// scrolled up), and no page of history loading (it would land above a
    /// gap).
    func trimPinnedTranscript(_ conversationId: String, isPinned: @escaping @MainActor () -> Bool) {
        guard isPinned(),
              loadedMessages(conversationId).count > StateCache.messagesKept + Self.pinnedTrimSlack
        else { return }
        Task { @MainActor in
            guard isPinned(), self.visibleTranscripts[conversationId, default: 0] <= 1, !self.isLoadingOlder
            else { return }
            self.trimToWindow(conversationId)
        }
    }

    #if os(macOS)
    /// Closing the main window keeps its chat selected, so no trim reached
    /// it, and reopening laid out every row it had piled up. A turn after the
    /// close (the transcript is still being torn down when the window says it
    /// will close), the chat goes back to the window, unless it is the call's
    /// chat and the meeting window still shows it.
    private func observeMainWindowClose() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      window.identifier?.rawValue.hasPrefix("hq-main") == true
                else { return }
                Task { @MainActor in self?.trimClosedWindowHistory() }
            }
        }
    }

    func trimClosedWindowHistory() {
        guard let conversationId = selectedConversationId else { return }
        let isMeetingWindowOpen = NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("hq-meeting") == true && $0.isVisible
        }
        if conversationId == activeCall?.conversationId, isMeetingWindowOpen { return }
        trimToWindow(conversationId)
    }
    #endif

    /// Drops all but the newest `StateCache.messagesKept` confirmed rows,
    /// keeping every pending one. Returns how many rows it dropped.
    @discardableResult
    private func trimToWindow(_ conversationId: String) -> Int {
        let loaded = loadedMessages(conversationId)
        guard loaded.count > StateCache.messagesKept else { return 0 }
        let outgoing = loaded.filter { $0.id.hasPrefix("pending-") }
        let kept = Array(loaded.filter { !$0.id.hasPrefix("pending-") }.suffix(StateCache.messagesKept))
        publishMessages(kept + outgoing, in: conversationId)
        // Rows were dropped, so "no more history" no longer holds.
        exhaustedHistory.remove(conversationId)
        return loaded.count - kept.count - outgoing.count
    }

    // MARK: - Group management

    func rename(conversationId: String, title: String?) async {
        guard let client else { return }
        if let updated = try? await client.rename(conversationId: conversationId, title: title) {
            upsert(conversation: updated)
        }
    }

    func addMembers(conversationId: String, personIds: [String]) async {
        guard let client else { return }
        if let updated = try? await client.addMembers(conversationId: conversationId, personIds: personIds) {
            upsert(conversation: updated)
        }
    }

    func leave(conversationId: String) async {
        guard let client else { return }
        try? await client.leave(conversationId: conversationId)
        removeLocally(conversationId: conversationId)
    }

    /// Delete = freeze and hide: the server archives the group and
    /// every member's sidebar drops it via `conversation_removed`. History
    /// survives server-side; nothing is destroyed.
    func deleteGroup(conversationId: String) async {
        guard let client else { return }
        guard (try? await client.deleteConversation(id: conversationId)) != nil else { return }
        removeLocally(conversationId: conversationId)
    }

    private func removeLocally(conversationId: String) {
        conversations.removeAll { $0.id == conversationId }
        publishMessages([], in: conversationId)
        if selectedConversationId == conversationId { destination = .none }
    }

    /// How far each other member has read this conversation — the "Read" line.
    func readers(of message: Message) -> [Person] {
        // The conversation's own mark slot: a receipt in another chat does not
        // wake the last outgoing row that draws this line, and neither does
        // anything else that rewrites the list.
        readMarks(in: message.conversationId)
            .filter { $0.personId != me?.id && $0.lastReadMessageId >= message.id }
            .compactMap { people[$0.personId] }
    }

    private func replace(_ message: Message) {
        let current = loadedMessages(message.conversationId)
        let updated = Self.applyingMessageUpdate(message, to: current)
        if publishMessages(updated, in: message.conversationId) {
            scheduleSave()
        }
        guard let conversationIndex = conversations.firstIndex(where: {
            $0.lastMessage?.id == message.id
        }) else { return }
        let existing = conversations[conversationIndex]
        // An agent's work row is rewritten with every step, but the row's
        // preview is its headline alone. When what a conversation row shows
        // of its last message is unchanged there is nothing to rebuild, and
        // a rebuild would wake the sidebar and the open transcript for it.
        if let last = existing.lastMessage,
           last.previewText == message.previewText, last.isDeleted == message.isDeleted,
           last.transcriptDate == message.transcriptDate, last.senderName == message.senderName,
           last.senderPersonId == message.senderPersonId, last.kind == message.kind {
            return
        }
        writeConversation(at: conversationIndex, Conversation(
            id: existing.id, kind: existing.kind, title: existing.title,
            memberIds: existing.memberIds, createdAt: existing.createdAt,
            lastMessage: message, unreadCount: existing.unreadCount,
            readMarks: currentReadMarks(existing.id), roomSlug: existing.roomSlug,
            avatarId: existing.avatarId
        ))
        scheduleSave()
    }

    // MARK: - Frame handling

    /// The single entry for every frame the socket delivers. Internal only so
    /// the store's tests can drive it with a frame.
    func handle(_ frame: ServerFrame) {
        switch frame {
        case .hello(_, _, let onlineIds):
            onlinePersonIds = Set(onlineIds)
        case .message(let message):
            ingest(message)
            // Only a live frame banners — sync replay after a reconnect must
            // never turn history into a notification storm.
            notifyIfNeeded(for: message)
        case .messageUpdated(let message):
            replace(message)
        case .conversationUpdated(let conversation):
            upsert(conversation: conversation)
        case .conversationRemoved(let conversationId):
            removeLocally(conversationId: conversationId)
        case .presence(let personId, let isOnline):
            notePresence(personId: personId, isOnline: isOnline)
        case .typing(let conversationId, let personId, let expiresAt):
            noteTyping(conversationId: conversationId, personId: personId, expiresAt: expiresAt)
        case .read(let conversationId, let personId, let lastReadMessageId):
            noteRead(conversationId: conversationId, personId: personId, messageId: lastReadMessageId)
        default:
            handleRest(frame)
        }
    }

    private func handleRest(_ frame: ServerFrame) {
        switch frame {
        case .personUpdated(let person):
            notePersonUpdated(person)
        case .botState(let conversationId, let personId, let label, let expiresAt):
            noteBotState(
                conversationId: conversationId, personId: personId,
                label: label, expiresAt: expiresAt
            )
        case .messagesMoved(let fromConversationId, let messageIds):
            dropMoved(messageIds, from: fromConversationId)
        case .syncBatch(let messages):
            // The id each conversation's replay is measured against is its own
            // row's last message; `bumpConversation` fills it in.
            ingest(messages, arrival: .replay(lastKnownId: nil))
        case .syncComplete(let isPartial):
            completeSync(isPartial: isPartial)
        case .callState(let call):
            upsert(call: call)
        case .callEnded(let callId, _):
            endCall(callId)
        case .callRing(let ring):
            startRinging(ring)
        case .callRingEnded(let callId):
            stopRinging(callId: callId)
        case .meetings(let list):
            meetings = list
        case .meetingReminder(let meeting, let minutesUntil):
            noteMeetingReminder(meeting, minutesUntil: minutesUntil)
        case .tasks(let list):
            // The hub re-sends the whole board on any change, a project's
            // rename included, so most frames restate what is already held.
            assignIfChanged(\.tasks, list)
            // The frame is the whole board, as fresh as a read of it: a
            // reconnect need not fetch it again.
            noteTailLoaded(.tasks)
            reloadProjects()
            #if os(macOS)
            WidgetSync.shared.refreshSoon()
            #endif
        default:
            break
        }
    }

    /// A receipt moves one person's mark forward, which is all the "Read" line
    /// under the last outgoing bubble needs. The mark goes to the
    /// conversation's own slot: the conversations array is not rewritten (a
    /// teammate's read used to rebuild the sidebar, the phone's list and the
    /// detail panel, none of which draw a mark) and nothing is scheduled for
    /// saving — the cache reads the merged marks whenever it is next written.
    private func noteRead(conversationId: String, personId: String, messageId: String) {
        if personId == me?.id {
            // The echo of a read this device just posted has nothing to clear:
            // `markVisibleRead` cleared the banners before it posted. Another
            // device's read does (and also tells this one the hub is caught up).
            let known = lastPostedRead[conversationId] ?? ""
            if known < messageId {
                lastPostedRead[conversationId] = messageId
                NotificationManager.shared.clearMessageNotifications(
                    readThrough: [conversationId: messageId]
                )
            }
        }
        guard isKnownConversation(conversationId) else { return }
        let current = currentReadMarks(conversationId)
        // The hub echoes a receipt to every member on every read, moved or
        // not. A mark already there changes nothing, so it writes nothing.
        guard !current.contains(where: {
            $0.personId == personId && $0.lastReadMessageId == messageId
        }) else { return }
        var marks = current.filter { $0.personId != personId }
        marks.append(ReadMark(personId: personId, lastReadMessageId: messageId))
        readMarkSlot(for: conversationId).marks = marks
    }

    // MARK: - Calls

    /// A nil meetingId joins the standing company room; otherwise the named
    /// meeting's own room.
    func joinMeeting(_ meetingId: String?, isCameraOn: Bool, isMicrophoneOn: Bool) async {
        await join(
            kind: "meeting", conversationId: nil, meetingId: meetingId,
            isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn
        )
    }

    func joinCall(conversationId: String, isCameraOn: Bool, isMicrophoneOn: Bool) async {
        await join(
            kind: "conversation", conversationId: conversationId, meetingId: nil,
            isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn
        )
    }

    func createMeeting(
        title: String,
        scheduledAt: Date?,
        inviteePersonIds: [String] = [],
        recurrence: HQClient.RecurrenceBody? = nil
    ) async -> Meeting? {
        guard let client else { return nil }
        callError = nil
        do {
            let meeting = try await client.createMeeting(
                title: title, scheduledAt: scheduledAt,
                inviteePersonIds: inviteePersonIds, recurrence: recurrence
            )
            // Local echo; the broadcast frame re-states the whole ordered list.
            if !meetings.contains(where: { $0.id == meeting.id }) { meetings.append(meeting) }
            return meeting
        } catch {
            callError = "The meeting could not be created."
            return nil
        }
    }

    /// Replaces the invite list wholesale. On a repeating meeting this is the
    /// list for every occurrence — they share one thread.
    func setMeetingInvitees(_ meetingId: String, personIds: [String]) async {
        guard let client else { return }
        callError = nil
        do {
            let updated = try await client.setMeetingInvitees(id: meetingId, personIds: personIds)
            if let index = meetings.firstIndex(where: { $0.id == updated.id }) {
                meetings[index] = updated
            }
        } catch let error as APIError {
            callError = error.localizedDescription
        } catch {
            callError = "The invite list could not be updated."
        }
    }

    /// Cancels one meeting. On a repeating one the hub puts the next
    /// occurrence up in its place, and the `meetings` frame brings it back.
    func cancelMeeting(_ meetingId: String) async {
        guard let client else { return }
        do {
            try await client.cancelMeeting(id: meetingId)
            meetings.removeAll { $0.id == meetingId }
        } catch let error as APIError {
            callError = error.localizedDescription
        } catch {
            callError = "The meeting could not be canceled."
        }
    }

    /// Stops a repeating meeting for good.
    func cancelMeetingSeries(_ seriesId: String) async {
        guard let client else { return }
        do {
            try await client.cancelMeetingSeries(id: seriesId)
            meetings.removeAll { $0.seriesId == seriesId }
        } catch let error as APIError {
            callError = error.localizedDescription
        } catch {
            callError = "The recurring meeting could not be ended."
        }
    }

    private func join(
        kind: String, conversationId: String?, meetingId: String?,
        isCameraOn: Bool, isMicrophoneOn: Bool
    ) async {
        guard let client, activeCallId == nil else { return }
        callError = nil
        do {
            let joined = try await client.startCall(
                kind: kind, conversationId: conversationId, meetingId: meetingId
            )
            upsert(call: joined.call)
            activeCallId = joined.call.id
            #if !os(macOS)
            // The system owns a live call: an app-started
            // join registers with CallKit too, so locking the phone keeps the
            // call as a first-class system call — the lock-screen call UI and
            // the Dynamic Island pill, not a background app hoping iOS spares
            // its audio. The answered-ring path already holds the session and
            // the coordinator's claim guard skips it.
            CallKitCoordinator.shared.noteOutgoingCall(
                callId: joined.call.id, title: callTitle(for: joined.call)
            )
            #endif
            callEngine.onConnectionLost = { [weak self] in
                await self?.rejoinActiveCall()
            }
            await callEngine.join(
                client: client, joined: joined,
                isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn
            )
            if case .failed(let message) = callEngine.stage {
                callError = message
                let failedCallId = activeCallId
                activeCallId = nil
                #if !os(macOS)
                if let failedCallId { CallKitCoordinator.shared.noteCallEnded(failedCallId) }
                #endif
                // The hub seated this device before the media failed; leaving
                // it there showed the room a silent ghost tile until the sweep.
                await callEngine.leave()
                return
            }
            startHeartbeat()
            await syncCallMedia()
        } catch let error as APIError {
            callError = error.localizedDescription
        } catch {
            callError = "The call could not be started."
        }
    }

    /// What the system call UI shows for a call this app started: the
    /// meeting's name, the thread's name, or the plain fallback.
    private func callTitle(for call: Call) -> String {
        if let title = call.title, !title.isEmpty { return title }
        if let meetingId = call.meetingId,
           let meeting = meetings.first(where: { $0.id == meetingId }) {
            return meeting.title
        }
        if let conversation = conversations.first(where: { $0.id == call.conversationId }) {
            return displayName(for: conversation)
        }
        return "HQ Call"
    }

    func updateHandRaised(_ isRaised: Bool) async {
        guard let client, let callId = activeCallId else { return }
        try? await client.setCallState(callId: callId, changes: [.handRaised(isRaised)])
    }

    func leaveCall() async {
        stopHeartbeat()
        let endedCallId = activeCallId
        activeCallId = nil
        #if !os(macOS)
        // A call answered through CallKit holds a system call session; HQ's
        // own end must clear it or the phone stays "in a call".
        if let endedCallId { CallKitCoordinator.shared.noteCallEnded(endedCallId) }
        #endif
        await callEngine.leave()
        await refresh()
    }

    // MARK: - Ringing

    /// Answer: joins the call the ring named, mic live and camera off — the
    /// green room is for walking into a room, not for a question already
    /// being asked.
    func answerIncomingCall() async {
        guard let ring = incomingCall else { return }
        clearRing()
        await joinCall(conversationId: ring.call.conversationId, isCameraOn: false, isMicrophoneOn: true)
        if activeCallId != nil { openWindowAction?("hq-meeting") }
    }

    func declineIncomingCall() async {
        guard let ring = incomingCall, let client else { return }
        clearRing()
        try? await client.declineCall(callId: ring.call.id)
    }

    private func startRinging(_ ring: IncomingCall) {
        // Already in a call, already being rung, or this is our own call
        // arriving back at us: nothing to ask.
        guard incomingCall == nil, activeCallId == nil else { return }
        guard ring.call.startedByPersonId != me?.id else { return }
        // A ring read back from a refresh can already be over.
        guard ring.expiresDate > Date(), ring.call.isLive else { return }
        #if os(macOS)
        // The Mac answers in a floating panel outside the scene graph, with
        // its own ringtone.
        incomingCall = ring
        ringer.start()
        IncomingCallWindow.show(store: self)
        ringTimeout?.cancel()
        let seconds = max(1, ring.expiresDate.timeIntervalSinceNow)
        ringTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // The hub agrees on its own sweep; stopping here means a ring
            // never outlives its own deadline even if that frame is late.
            self?.clearRing()
        }
        #else
        // The phone's ring surface is CallKit: the native full-screen
        // incoming call and the system ringtone, while the app runs. The
        // socket frame lands there, and the coordinator claims by call id.
        CallKitCoordinator.shared.reportRing(
            callId: ring.call.id,
            conversationId: ring.call.conversationId,
            callerName: ring.callerName,
            conversationTitle: ring.conversationTitle,
            expiresAt: ring.expiresDate
        )
        #endif
    }

    /// Answer from CallKit: same join as the panel's Answer button — mic
    /// live, camera off. CallKit already resolved the ring on its side.
    func answerCallKitRing(conversationId: String) async {
        await joinCall(conversationId: conversationId, isCameraOn: false, isMicrophoneOn: true)
    }

    func declineRungCall(callId: String) async {
        try? await client?.declineCall(callId: callId)
    }

    private func stopRinging(callId: String) {
        #if !os(macOS)
        CallKitCoordinator.shared.endRing(callId)
        #endif
        guard incomingCall?.call.id == callId else { return }
        clearRing()
    }

    private func clearRing() {
        ringTimeout?.cancel()
        ringTimeout = nil
        ringer.stop()
        incomingCall = nil
        #if os(macOS)
        IncomingCallWindow.hide()
        #endif
    }

    // The engine's connection died (ICE loss, input-route change): take a
    // fresh seat in the same call. The server treats it as a rejoin — the
    // generation supersedes and the old session's tracks end for everyone.
    private func rejoinActiveCall() async {
        guard let client else { return }
        // A call that cannot be rejoined — ended while the socket was down,
        // or a meeting call with no meeting id (rejoining blind would birth
        // a fresh Quick Call) — closes out honestly. Returning silently here
        // left a dead peer connection under a stage that read .live forever.
        guard let call = activeCall, call.isLive,
              !(call.kind == "meeting" && call.meetingId == nil)
        else {
            await leaveCall()
            return
        }
        let wasHandRaised = call.participants
            .first { $0.deviceId == session?.deviceId }?.isHandRaised ?? false
        do {
            let joined = try await client.startCall(
                kind: call.kind,
                conversationId: call.kind == "conversation" ? call.conversationId : nil,
                meetingId: call.meetingId
            )
            // The person may have hit Leave while the round trip was in
            // flight; the fresh seat must not resurrect the call with a hot
            // mic and no window.
            guard activeCallId == call.id else {
                try? await client.leaveCall(callId: joined.call.id)
                return
            }
            upsert(call: joined.call)
            await callEngine.rejoin(client: client, joined: joined)
            if wasHandRaised {
                try? await client.setCallState(callId: joined.call.id, changes: [.handRaised(true)])
            }
            await syncCallMedia()
        } catch {
            callEngine.noteRecoveryFailed()
        }
    }

    /// The Rejoin button on the failed stage: reset the strike counter and
    /// run the same recovery a dropped connection gets.
    func retryCall() async {
        callEngine.retryAfterFailure()
        await rejoinActiveCall()
    }

    private func syncCallMedia() async {
        guard let call = activeCall, let deviceId = session?.deviceId else { return }
        await callEngine.sync(call: call, myDeviceId: deviceId)
    }

    private func startHeartbeat() {
        stopHeartbeat()
        // The hub sweeps a device out of a call after 45s of silence; a beat
        // every 15s means a laptop that sleeps disappears within one sweep.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let callId = self.activeCallId else { return }
                // A failed stage must not keep its ghost seat alive: with no
                // beat the hub sweeps it, so the room stops seeing a
                // present-but-dead tile while the person decides.
                if case .failed = self.callEngine.stage { return }
                self.socket?.send(["type": "call_heartbeat", "call_id": callId])
                // The same beat over HTTP. The socket one is silently lost
                // while the socket is reconnecting or half-open, and a live
                // device was swept out of a meeting that way. The
                // answer is the roster, which is also how this device learns
                // its seat is gone when a frame saying so never arrived.
                guard let client = self.client,
                      let call = try? await client.callRoster(callId: callId),
                      self.activeCallId == callId
                else { return }
                // Read for the seat only: this answer can be older than a
                // socket frame that already arrived, and replaying it into the
                // roster would briefly undo that frame.
                if !call.isLive {
                    await self.leaveCall()
                } else if call.participants.first(where: { $0.deviceId == self.session?.deviceId })?.isPresent != true {
                    self.callEngine.noteSeatLost()
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    private func upsert(call: Call) {
        if let index = calls.firstIndex(where: { $0.id == call.id }) {
            chimeIfSomeoneJoined(old: calls[index], new: call)
            calls[index] = call
        } else {
            chimeIfSomeoneJoined(old: nil, new: call)
            calls.insert(call, at: 0)
        }
        if call.id == activeCallId {
            if call.isLive {
                // Swept or evicted while the media here still runs: the room
                // can no longer see or hear this person, and only this device
                // can put them back.
                let mySeat = call.participants.first { $0.deviceId == session?.deviceId }
                if mySeat?.isPresent != true { callEngine.noteSeatLost() }
                Task { await self.syncCallMedia() }
            } else {
                Task { await self.leaveCall() }
            }
        }
    }

    /// Pops when a meeting gains a participant who isn't me. Live socket
    /// updates only — refresh() replaces `calls` wholesale precisely so a
    /// reconnect replay can't turn into a chime storm — and only meetings:
    /// conversation calls already ring. My own joins arrive here too (the
    /// startCall upsert), so the diff has to exclude me.
    private func chimeIfSomeoneJoined(old: Call?, new: Call) {
        guard new.kind == "meeting", new.isLive else { return }
        let before = Set((old?.presentParticipants ?? []).map(\.personId))
        let joined = Set(new.presentParticipants.map(\.personId)).subtracting(before)
        guard joined.contains(where: { $0 != me?.id }) else { return }
        JoinChime.play()
    }

    private func endCall(_ callId: String) {
        guard let index = calls.firstIndex(where: { $0.id == callId }) else { return }
        let existing = calls[index]
        calls[index] = Call(
            id: existing.id, conversationId: existing.conversationId, kind: existing.kind,
            meetingId: existing.meetingId, title: existing.title,
            startedByPersonId: existing.startedByPersonId,
            startedAt: existing.startedAt, endedAt: ISO8601DateFormatter().string(from: Date()),
            participants: existing.participants, tracks: []
        )
        if callId == activeCallId { Task { await self.leaveCall() } }
    }

    private func notePresence(personId: String, isOnline: Bool) {
        if isOnline {
            onlinePersonIds.insert(personId)
        } else {
            onlinePersonIds.remove(personId)
        }
    }

    /// The source side of a move: the messages now live in another
    /// thread, which receives them as ordinary frames. Here they simply go.
    private func dropMoved(_ messageIds: [String], from conversationId: String) {
        let moved = Set(messageIds)
        publishMessages(
            loadedMessages(conversationId).filter { !moved.contains($0.id) }, in: conversationId
        )
    }

    private func noteTyping(conversationId: String, personId: String, expiresAt: String) {
        guard personId != me?.id else { return }
        typingByConversation[conversationId, default: [:]][personId] = ISO8601.parse(expiresAt)
    }

    private func noteBotState(
        conversationId: String, personId: String, label: String?, expiresAt: String
    ) {
        guard let label else {
            botActivityByConversation[conversationId] = nil
            return
        }
        botActivityByConversation[conversationId] = BotActivity(
            personId: personId, label: label, expiresAt: ISO8601.parse(expiresAt)
        )
    }

    /// The live bot state line for a conversation, nil once cleared or expired.
    func botActivity(in conversationId: String) -> (name: String, label: String)? {
        guard let activity = botActivityByConversation[conversationId] else { return nil }
        guard activity.expiresAt > Date() else { return nil }
        return (people[activity.personId]?.name ?? "Bot", activity.label)
    }

    private func completeSync(isPartial: Bool) {
        // A truncated replay means more history is waiting: ask for the next
        // page from the cursor the replay just advanced. Not a full refresh —
        // the conversation list was read when the socket connected, and the
        // rows move with the replayed messages. A replay that did not move the
        // cursor would ask for the same page forever, so it stops there.
        guard isPartial else { return }
        guard lastSeenMessageId != lastSyncSince else {
            storeLog.warning("sync replay truncated but the cursor did not move; not asking again")
            return
        }
        storeLog.notice("sync replay truncated at the server cap; resuming from cursor")
        socket?.send(syncFrame())
    }

    /// How a batch reached this device: a live frame, or a sync replay whose
    /// messages at or below `lastKnownId` the refresh already counted.
    enum Arrival: Equatable {
        case live
        case replay(lastKnownId: String?)
    }

    /// One conversation's share of a batch, in arrival order.
    struct ConversationBatch: Equatable {
        let conversationId: String
        let messages: [Message]
    }

    /// Splits a batch by conversation, each keeping its messages' order. The
    /// groups are ordered by where each conversation's NEWEST message sits in
    /// the batch, so bumping them in that order leaves the conversation of the
    /// batch's last message on top — the order one-at-a-time ingest produced.
    nonisolated static func groupedByConversation(_ messages: [Message]) -> [ConversationBatch] {
        var byConversation: [String: [Message]] = [:]
        var newestPosition: [String: Int] = [:]
        for (position, message) in messages.enumerated() {
            byConversation[message.conversationId, default: []].append(message)
            newestPosition[message.conversationId] = position
        }
        return newestPosition.sorted { $0.value < $1.value }.map {
            ConversationBatch(conversationId: $0.key, messages: byConversation[$0.key] ?? [])
        }
    }

    /// The unread count after a batch lands in one conversation, as if the
    /// messages had arrived one by one. A message from me clears the count, a
    /// row with any `kind` (a group event, an agent's work row) moves nothing,
    /// as the hub counts; anyone else's adds one;
    /// a thread being read stays at zero. A REPLAYED message at or below the
    /// conversation's last message was already counted in the hub's number
    /// that the refresh just read, so it adds nothing (reconnecting used to
    /// inflate every badge by the whole replay).
    nonisolated static func unreadAfter(
        existing: Int, messages: [Message], meId: String?, isBeingRead: Bool, arrival: Arrival
    ) -> Int {
        guard !isBeingRead else { return 0 }
        var unread = existing
        for message in messages {
            if case .replay(let lastKnownId?) = arrival, message.id <= lastKnownId { continue }
            if message.senderPersonId == meId {
                unread = 0
            } else if message.kind == nil {
                unread += 1
            }
        }
        return unread
    }

    private func ingest(_ messages: [Message], arrival: Arrival) {
        guard !messages.isEmpty else { return }
        if let newest = messages.map(\.id).max(), newest > (lastSeenMessageId ?? "") {
            lastSeenMessageId = newest
        }
        for message in messages
        where typingByConversation[message.conversationId]?[message.senderPersonId] != nil {
            // Only when there is something to clear: an optional-chained write
            // to the observed dictionary notifies even when no entry exists.
            typingByConversation[message.conversationId]?[message.senderPersonId] = nil
        }
        // A batch is one merge, one bump and one read per conversation: the
        // sync replay used to repeat the whole thread's sort, two list writes
        // and an HTTP read for every message in it.
        for batch in Self.groupedByConversation(messages) {
            if !conversations.contains(where: { $0.id == batch.conversationId }) {
                fetchUnknownConversation(batch.conversationId)
            }
            let echoed = arrival == .live ? pendingRowConfirmed(by: batch.messages, in: batch.conversationId) : nil
            merge(messages: batch.messages, into: batch.conversationId, dropping: echoed)
            bumpConversation(withBatch: batch.messages, in: batch.conversationId, arrival: arrival)
        }
        if let selected = selectedConversationId, messages.contains(where: { $0.conversationId == selected }) {
            markVisibleRead(selected)
        }
    }

    /// The hub sends my own message to my sockets before it answers the POST,
    /// and the wire carries no client id, so the message showed twice until
    /// the reply landed. A live echo of mine stands for the oldest in-flight
    /// pending row with the same text, attachments and reply: that row is
    /// dropped in the same merge, and its send is no longer pending, so a
    /// reply lost after the hub stored it never marks it "Not sent". The same
    /// words sent from my phone match too; `deliver` puts the row back when
    /// its own POST then provably failed.
    private func pendingRowConfirmed(by messages: [Message], in conversationId: String) -> String? {
        // `via` marks a post made as me but not by this app (Claude through
        // MCP): never this device's send.
        guard let meId = me?.id,
              let echo = messages.last(where: { $0.senderPersonId == meId && $0.via == nil })
        else { return nil }
        func clientMsgId(_ row: Message) -> String { String(row.id.dropFirst("pending-".count)) }
        guard let row = loadedMessages(conversationId).first(where: { row in
            row.isPending && pendingClientIds.contains(clientMsgId(row))
                && row.content == echo.content
                && row.attachments.map(\.id) == echo.attachments.map(\.id)
                && row.replyTo?.id == echo.replyTo?.id
        }) else { return nil }
        pendingClientIds.remove(clientMsgId(row))
        return row.id
    }

    /// A message for a conversation this device has never heard of: its row
    /// is fetched once, however many messages name it.
    private func fetchUnknownConversation(_ conversationId: String) {
        guard fetchingConversationIDs.insert(conversationId).inserted else { return }
        Task {
            defer { fetchingConversationIDs.remove(conversationId) }
            guard let client else { return }
            if let conversation = try? await client.conversation(id: conversationId) {
                upsert(conversation: conversation)
            }
        }
    }

    private func ingest(_ message: Message) {
        ingest([message], arrival: .live)
    }

    /// A local banner for a message the user isn't already looking at. Group
    /// events stay silent; so does the thread on screen while the app is
    /// frontmost.
    private func notifyIfNeeded(for message: Message) {
        guard message.senderPersonId != me?.id, message.kind == nil else { return }
        let conversation = conversations.first(where: { $0.id == message.conversationId })
        if isReadingThread(message.conversationId) { return }
        let title = conversation?.title ?? message.senderName
        let text = plainText(message.content)
        let body = conversation?.kind == "group"
            ? "\(message.senderName): \(text)"
            : text
        postBanner(title, body, message.conversationId, message.id)
    }

    /// "Starting in 4 min", from the socket.
    private func noteMeetingReminder(_ meeting: Meeting, minutesUntil: Int) {
        guard let conversationId = meeting.conversationId else { return }
        NotificationManager.shared.post(
            title: meeting.title,
            body: minutesUntil <= 0 ? "Starting now" : "Starting in \(minutesUntil) min",
            conversationId: conversationId,
            messageId: "meeting-\(meeting.id)"
        )
    }

    /// The one case that earns silence: HQ is the live, selected app AND the
    /// message landed in the thread on screen, so the transcript already
    /// showed it. Everything else banners, app open or not. Frontmost with
    /// the window closed or minimized is not reading.
    private func isReadingThread(_ conversationId: String) -> Bool {
        let screen = screenReading()
        return Self.shouldMarkRead(
            conversationId,
            selectedConversationId: selectedConversationId,
            isAppActive: screen.isAppActive,
            isConversationVisible: screen.isChatVisible
        )
    }

    // The screen reading and the banner, which Debug builds let tests replace:
    // a test has no window and cannot read the system's notification center.
    #if DEBUG
    @ObservationIgnored var screenReading: () -> (isAppActive: Bool, isChatVisible: Bool) = AppStore.readScreen
    @ObservationIgnored var postBanner: (_ title: String, _ body: String, _ conversationId: String, _ messageId: String) -> Void = AppStore.postSystemBanner
    #else
    private let screenReading = AppStore.readScreen
    private let postBanner = AppStore.postSystemBanner
    #endif

    /// What the OS says about the screen: whether HQ is the app in front and
    /// whether the chat can be seen.
    private static func readScreen() -> (isAppActive: Bool, isChatVisible: Bool) {
        #if os(macOS)
        let isChatVisible = NSApp.windows.contains { window in
            window.identifier?.rawValue.hasPrefix("hq-main") == true && window.isVisible
                && !window.isMiniaturized
        }
        #else
        // On the phone the selection IS the screen: popping back to the list
        // clears it, so an active app with this thread selected is someone
        // reading it. There is no window to be closed or minimized behind.
        let isChatVisible = true
        #endif
        return (Platform.isActive, isChatVisible)
    }

    private static func postSystemBanner(_ title: String, _ body: String, _ conversationId: String, _ messageId: String) {
        NotificationManager.shared.post(title: title, body: body, conversationId: conversationId, messageId: messageId)
    }

    static func shouldMarkRead(
        _ conversationId: String,
        selectedConversationId: String?,
        isAppActive: Bool,
        isConversationVisible: Bool
    ) -> Bool {
        conversationId == selectedConversationId && isAppActive && isConversationVisible
    }

    /// The app icon's red badge — the Dock tile on macOS, the home screen on
    /// iOS: unread messages across the chat list, the same count the sidebar
    /// rows carry. Cleared at zero — a badge with nothing in it is a red dot
    /// that means nothing.
    private func updateDockBadge() {
        let total = visibleConversations.reduce(0) { $0 + $1.unreadCount }
        // The same number again is not sent: on the phone this is an XPC call,
        // and a sync replay used to make two per message.
        guard total != lastBadgeTotal else { return }
        lastBadgeTotal = total
        Platform.setBadge(total)
    }

    func loadTasks() async {
        guard let client else { return }
        async let loadedTasks = try? client.tasks()
        async let loadedProjects = try? client.projects()
        let (newTasks, newProjects) = await (loadedTasks, loadedProjects)
        if let newTasks { assignIfChanged(\.tasks, newTasks) }
        if let newProjects { applyProjects(newProjects) }
        if newTasks != nil, newProjects != nil { noteTailLoaded(.tasks) }
        openPendingTask()
    }

    func refreshPlanning() async throws {
        guard let client else { throw URLError(.notConnectedToInternet) }
        async let loadedTasks = client.tasks()
        async let loadedProjects = client.projects()
        let result = try await (loadedTasks, loadedProjects)
        assignIfChanged(\.tasks, result.0)
        applyProjects(result.1)
        noteTailLoaded(.tasks)
    }

    /// The projects as the hub sent them, and the capability beside them.
    private func applyProjects(_ result: (projects: [Project], openTranscripts: Bool)) {
        assignIfChanged(\.projects, result.projects)
        assignIfChanged(\.supportsOpenTranscripts, result.openTranscripts)
    }

    /// A project write answered with the project as the hub now has it (a
    /// rename, a new description): the board shows it at once, and nothing
    /// is re-read for it. The hub's `tasks` frame still follows and restates
    /// the rest. Only a project this device already holds is replaced.
    func applyPlanningProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }),
              projects[index] != project
        else { return }
        projects[index] = project
    }

    /// The hub's answer to a task edit, applied in place: the board shows the
    /// edit without waiting for the `tasks` frame, which a half-open socket
    /// after sleep might never deliver.
    func applyPlanningTask(_ task: TeamTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              tasks[index] != task
        else { return }
        tasks[index] = task
    }

    var taskMutationError: String?

    func createTask(
        title: String, body: String? = nil, ownerPersonId: String, projectId: String?,
        recurrence: TaskRecurrence? = nil, dueAt: Date? = nil
    ) async throws {
        guard let client else { throw URLError(.notConnectedToInternet) }
        let task = try await client.createTask(
            title: title, body: body, ownerPersonId: ownerPersonId, projectId: projectId,
            recurrence: recurrence, dueAt: dueAt
        )
        // A broadcast may have arrived first.
        if !tasks.contains(where: { $0.id == task.id }) {
            if let parent = task.projectId {
                let index = tasks.lastIndex { $0.projectId == parent }.map { $0 + 1 } ?? tasks.count
                tasks.insert(task, at: index)
            } else {
                tasks.insert(task, at: 0)
            }
        }
    }

    /// Replace by id, or insert when the broadcast has not landed yet.
    private func upsert(task: TeamTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
    }

    func setTaskRecurrence(_ task: TeamTask, repeat option: TaskRepeat) {
        guard let client else { return }
        Task {
            do {
                let updated = try await client.setTaskRecurrence(
                    id: task.id, recurrence: ProjectsModel.recurrence(option, for: task)
                )
                if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = updated }
            } catch {
                taskMutationError = (error as? TaskScheduleError)?.errorDescription ?? "The repeat schedule could not be saved. Please try again."
            }
        }
    }

    func deleteTask(_ taskId: String) {
        guard let client else { return }
        Task {
            do {
                try await client.deleteTask(id: taskId)
                tasks.removeAll { $0.id == taskId }
            } catch {
                taskMutationError = "That task could not be deleted. Please try again."
            }
        }
    }

    /// A tasks frame re-states the tasks but never the projects, and every
    /// task moved changes some project's open count — so the frame is also
    /// the cue to re-read the projects, which is one small list.
    ///
    /// A trailing debounce of about a second: a card moved across a board is a
    /// handful of frames, and each used to cost its own request. Only the wait
    /// is debounced. A frame never cancels a request that is already out (a
    /// steady stream of frames, a burst of changes, would otherwise
    /// throw every request away and never read the projects), and the wait is
    /// capped at five seconds from the first frame nobody has served yet.
    private func reloadProjects() {
        guard client != nil else { return }
        let now = Date()
        let firstUnserved = projectsFirstUnservedAt ?? now
        projectsFirstUnservedAt = firstUnserved
        projectsReloadGeneration &+= 1
        let generation = projectsReloadGeneration
        let wait = Self.projectsReloadWait(sinceFirstUnservedFrame: now.timeIntervalSince(firstUnserved))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            // A newer frame owns the wait now (or a sign-out ended it).
            guard let self, generation == projectsReloadGeneration, let client, let deviceId = session?.deviceId
            else { return }
            projectsFirstUnservedAt = nil
            projectsRequestsStarted &+= 1
            let request = projectsRequestsStarted
            guard let loaded = try? await client.projects(),
                  session?.deviceId == deviceId,
                  // Requests overlap when frames keep coming; an older answer
                  // that lands after a newer one is stale.
                  request > projectsRequestApplied
            else { return }
            projectsRequestApplied = request
            applyProjects(loaded)
        }
    }

    /// How long the next frame waits before the projects are read: a second,
    /// less as the first unserved frame gets older, never more than five
    /// seconds in all.
    nonisolated static func projectsReloadWait(sinceFirstUnservedFrame elapsed: TimeInterval) -> TimeInterval {
        max(0, min(1, 5 - elapsed))
    }

    func createProject(name: String, body: String?, ownerPersonId: String) {
        guard let client else { return }
        Task {
            if let project = try? await client.createProject(
                name: name, body: body, ownerPersonId: ownerPersonId
            ), !projects.contains(project) {
                projects.append(project)
            }
        }
    }

    /// Closing needs an empty project; the hub's refusal reads back as the
    /// same message a failed task edit shows.
    func closeProject(_ projectId: String) {
        guard let client else { return }
        Task {
            do {
                let closed = try await client.closeProject(id: projectId)
                if let index = projects.firstIndex(where: { $0.id == closed.id }) {
                    projects[index] = closed
                }
            } catch {
                taskMutationError = "Finish or move its open tasks first."
            }
        }
    }

    func assignTask(_ taskId: String, to ownerPersonId: String) {
        guard let client else { return }
        Task {
            do {
                let task = try await client.assignTask(id: taskId, ownerPersonId: ownerPersonId)
                if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
            } catch {
                taskMutationError = "That task could not be handed on. Please try again."
            }
        }
    }

    /// Hand order. Moved here first so the row stays where it was dropped
    /// instead of snapping back for the round trip, then re-stated by the
    /// server's answer — the whole list, in the order it decides.
    func reorderTask(_ taskId: String, anchorId: String, isAfter: Bool) {
        guard let client, taskId != anchorId else { return }
        moveTaskLocally(taskId, anchorId: anchorId, isAfter: isAfter)
        Task {
            if let ordered = try? await client.reorderTask(
                id: taskId, anchorId: anchorId, isAfter: isAfter
            ) {
                tasks = ordered
            } else {
                // The optimistic move is a guess about a list the hub owns;
                // a refused drag must not leave it standing.
                await loadTasks()
            }
        }
    }

    /// A card dropped on a Projects board (or moved by its menu): drawn where
    /// it landed first, then written — the status, then its neighbour. A
    /// refusal puts the rows back and re-reads, since a half-landed move
    /// (status saved, order refused) is the hub's truth, not the snapshot's.
    /// The move is drawn before this returns — in the same turn as the
    /// drop, so the card never shows back in its old place for a frame —
    /// and the task answers whether it landed, so the board can say quietly
    /// that it did not.
    func moveTaskOnBoard(_ taskId: String, drop: TaskDrop) -> Task<Bool, Never> {
        let before = tasks
        let from = tasks.first { $0.id == taskId }.map(ProjectsModel.list(of:)) ?? "open"
        tasks = ProjectsModel.applying(drop, to: taskId, in: tasks)
        return Task { await writeTaskMove(taskId, drop: drop, from: from, before: before) }
    }

    private func writeTaskMove(_ taskId: String, drop: TaskDrop, from: String, before: [TeamTask]) async -> Bool {
        guard let client else {
            tasks = before
            return false
        }
        do {
            if let status = drop.status {
                for write in ProjectsModel.statusWrites(from: from, to: status) {
                    _ = try await client.updateTaskStatus(id: taskId, status: write)
                }
            }
            if let anchor = drop.anchor {
                tasks = try await client.reorderTask(id: taskId, anchorId: anchor.id, isAfter: anchor.isAfter)
            }
            // A new status changes a board card's counts; an order does not.
            if drop.status != nil { try? await refreshPlanning() }
            return true
        } catch {
            tasks = before
            try? await refreshPlanning()
            return false
        }
    }

    private func moveTaskLocally(_ taskId: String, anchorId: String, isAfter: Bool) {
        guard let from = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let moving = tasks.remove(at: from)
        guard let anchor = tasks.firstIndex(where: { $0.id == anchorId }) else {
            tasks.insert(moving, at: min(from, tasks.count))
            return
        }
        tasks.insert(moving, at: isAfter ? anchor + 1 : anchor)
    }

    func setTaskStatus(_ taskId: String, status: String) {
        guard let client else { return }
        let from = tasks.first { $0.id == taskId }.map(ProjectsModel.list(of:)) ?? "open"
        // The tick shows at once, as the board's drags do; a refusal puts the
        // task back, unless a newer board frame replaced it meanwhile.
        let heldIndex = tasks.firstIndex { $0.id == taskId }
        let held = heldIndex.map { (previous: tasks[$0], optimistic: tasks[$0].moved(to: status)) }
        if let heldIndex, let held { tasks[heldIndex] = held.optimistic }
        Task {
            do {
                var task: TeamTask?
                for write in ProjectsModel.statusWrites(from: from, to: status) {
                    task = try await client.updateTaskStatus(id: taskId, status: write)
                }
                if let task, tasks.contains(where: { $0.id == task.id }) {
                    applyTaskStatusReply(task, madeFor: held?.optimistic)
                    if task.nextTaskId != nil { await loadTasks() }
                }
            } catch {
                if let held, let index = tasks.firstIndex(where: { $0.id == taskId }), tasks[index] == held.optimistic {
                    tasks[index] = held.previous
                }
                taskMutationError = "That task could not be updated. Please try again."
            }
        }
    }

    /// A status write's reply. It lands only while the row is still the one
    /// shown when the write was made: a tick then an untick are two writes
    /// whose replies come back in either order, and the row ends where the
    /// person last put it (a `tasks` frame that replaced it meanwhile wins
    /// too). Internal so the store's tests can hand it a reply.
    func applyTaskStatusReply(_ task: TeamTask, madeFor optimistic: TeamTask?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if optimistic == nil || tasks[index] == optimistic { tasks[index] = task }
    }

    func markUnread(conversationId: String) {
        guard let client else { return }
        // The hub's mark moves back, so what this device last posted no longer
        // covers the newest message: the next read of this chat must post.
        lastPostedRead[conversationId] = nil
        Task {
            if let conversation = try? await client.markUnread(conversationId: conversationId) {
                upsert(conversation: conversation)
            }
        }
    }

    /// `droppedId` is a row to remove in the same write (the pending row a
    /// confirmed send replaces); `beforePublish` runs right before a write
    /// that really changes the rows. A merge that changes nothing — a chat
    /// switch refetching what the cache already holds — publishes nothing, so
    /// it costs no transcript pass.
    private func merge(
        messages incoming: [Message], into conversationId: String,
        dropping droppedId: String? = nil, beforePublish: () -> Void = {}
    ) {
        var loaded = loadedMessages(conversationId)
        if let droppedId { loaded.removeAll { $0.id == droppedId } }
        let merged = Self.mergingMessages(incoming, into: loaded)
        let didPublish = publishMessages(merged, in: conversationId, beforePublish: beforePublish)
        // Live traffic must not grow a background thread past the window —
        // a busy room would otherwise pile up all day and pay for it as one
        // giant layout on the next switch in. A trim that publishes is a
        // change too, even after a merge that changed nothing.
        let trimmedRows = trimLoadedHistory(of: conversationId)
        if didPublish || trimmedRows > 0 { scheduleSave() }
    }

    static func mergingMessages(_ incoming: [Message], into loaded: [Message]) -> [Message] {
        var byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        func changedAt(_ message: Message) -> Date {
            [message.createdAt, message.editedAt, message.deletedAt]
                .compactMap { $0 }.map { ISO8601.parse($0) }.max() ?? message.createdDate
        }
        for message in incoming {
            if let cached = byId[message.id], changedAt(cached) > changedAt(message) { continue }
            byId[message.id] = message
        }
        // Pending IDs are random UUIDs, not timeline positions. Retain their
        // insertion order so sync cannot rearrange failed or in-flight sends.
        var seen = Set<String>()
        let outgoing = (loaded + incoming).filter { $0.id.hasPrefix("pending-") }
            .compactMap { seen.insert($0.id).inserted ? byId[$0.id] : nil }
        return byId.values.filter { !$0.id.hasPrefix("pending-") }.sorted { $0.id < $1.id } + outgoing
    }

    static func applyingMessageUpdate(_ message: Message, to loaded: [Message]) -> [Message] {
        guard let index = loaded.firstIndex(where: { $0.id == message.id }) else { return loaded }
        var updated = loaded
        updated[index] = message
        return updated
    }

    private func replacePending(clientMsgId: String, with message: Message) {
        pendingClientIds.remove(clientMsgId)
        failedOutgoingMessages["pending-\(clientMsgId)"] = nil
        merge(messages: [message], into: message.conversationId, dropping: "pending-\(clientMsgId)")
        bumpConversation(with: message)
    }

    private func bumpConversation(with message: Message) {
        bumpConversation(withBatch: [message], in: message.conversationId, arrival: .live)
    }

    /// Moves a conversation to the top with the newest message of a batch and
    /// the batch's effect on its unread count, in ONE list write. A replayed
    /// batch that holds nothing newer than the row's last message (the
    /// refresh already read it) changes nothing: no older preview, no move.
    private func bumpConversation(withBatch messages: [Message], in conversationId: String, arrival: Arrival) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }),
              let newest = messages.last
        else { return }
        let existing = conversations[index]
        // What a replay is measured against is what the refresh left in the row.
        let measured: Arrival
        switch arrival {
        case .live: measured = .live
        case .replay: measured = .replay(lastKnownId: existing.lastMessage?.id)
        }
        if case .replay(let known?) = measured, newest.id <= known { return }
        let unread = Self.unreadAfter(
            existing: existing.unreadCount, messages: messages, meId: me?.id,
            isBeingRead: isReadingThread(conversationId), arrival: measured
        )
        let updated = existing.bumped(
            lastMessage: newest, unreadCount: unread, readMarks: currentReadMarks(conversationId)
        )
        // One assignment, not remove-then-insert: two mutations meant two
        // observation notifications and two badge recounts per message.
        var reordered = conversations
        reordered.remove(at: index)
        reordered.insert(updated, at: 0)
        guard reordered != conversations else { return }
        conversations = reordered
    }

    /// Whether a read is worth telling the hub. My mark already covers the
    /// newest message and the chat shows nothing unread (a chat marked unread
    /// must still post), so there is nothing to say: the hub answers every
    /// read by re-broadcasting to the whole conversation and pushing my other
    /// devices, moved or not.
    nonisolated static func shouldPostRead(latestId: String, alreadyPosted: String?, unreadCount: Int) -> Bool {
        guard let alreadyPosted else { return true }
        return alreadyPosted < latestId || unreadCount > 0
    }

    private func markVisibleRead(_ conversationId: String) {
        guard isReadingThread(conversationId),
              let latest = loadedMessages(conversationId).last
                ?? conversations.first(where: { $0.id == conversationId })?.lastMessage,
              !latest.id.hasPrefix("pending-")
        else { return }
        let index = conversations.firstIndex(where: { $0.id == conversationId })
        let unread = index.map { conversations[$0].unreadCount } ?? 0
        let previous = lastPostedRead[conversationId]
        guard Self.shouldPostRead(latestId: latest.id, alreadyPosted: previous, unreadCount: unread) else { return }
        NotificationManager.shared.clearMessageNotifications(
            readThrough: [conversationId: latest.id]
        )
        guard let client else { return }
        if let index, unread > 0 {
            conversations[index] = conversations[index].bumped(
                lastMessage: conversations[index].lastMessage, unreadCount: 0,
                readMarks: currentReadMarks(conversationId)
            )
        }
        // Remembered before the request is out, so a second caller in the same
        // turn (a chat switch asks twice) finds it; a refusal takes it back.
        lastPostedRead[conversationId] = max(previous ?? "", latest.id)
        Task {
            do {
                try await client.markRead(conversationId: conversationId, messageId: latest.id)
            } catch {
                if lastPostedRead[conversationId] == latest.id { lastPostedRead[conversationId] = previous }
            }
        }
    }

    /// `me` reads from the enrollment session, not the people map, so a
    /// self-update has to land in both — and in the Keychain, or the next
    /// launch resurrects the old picture.
    private func notePersonUpdated(_ person: Person) {
        people[person.id] = person
        updateDockBadge()
        if let session, session.person.id == person.id {
            let updated = StoredSession(
                bearer: session.bearer, deviceId: session.deviceId, person: person
            )
            if shouldPersistSession { Keychain.save(updated) }
            self.session = updated
        }
        scheduleSave()
    }

    // MARK: - Avatars

    func setMyAvatar(imageData: Data) async {
        guard let client, let prepared = AvatarImagePrep.prepare(imageData) else { return }
        guard let person = try? await client.setMyAvatar(
            data: prepared.data, contentType: prepared.contentType
        ) else { return }
        notePersonUpdated(person)
    }

    func clearMyAvatar() async {
        guard let client, let person = try? await client.clearMyAvatar() else { return }
        notePersonUpdated(person)
    }

    // MARK: - Members

    /// Everyone still in the company, by name — what every picker offers.
    /// Removed people keep their row so history resolves their name and
    /// picture, and drop out of everywhere new activity can start.
    var roster: [Person] { Self.roster(from: Array(people.values)) }

    /// People frozen off the roster. Kept reachable so a removal can be
    /// undone, and nowhere near the list of who is actually here.
    var removedMembers: [Person] { Self.removedMembers(from: Array(people.values)) }

    /// Machine credentials, not teammates — listed so an admin can see which
    /// machines hold a bearer, never mixed in with the people.
    var serviceAccounts: [Person] { Self.serviceAccounts(from: Array(people.values)) }

    static func roster(from people: [Person]) -> [Person] {
        people
            .filter { $0.kind == "person" && !$0.isRemoved }
            .sorted { $0.name < $1.name }
    }

    static func removedMembers(from people: [Person]) -> [Person] {
        people
            .filter { $0.kind == "person" && $0.isRemoved }
            .sorted { $0.name < $1.name }
    }

    static func serviceAccounts(from people: [Person]) -> [Person] {
        people.filter(\.isService).sorted { $0.name < $1.name }
    }

    /// These three throw so Settings can say what the hub refused — "not
    /// yourself" is a rule worth reading, not a silent no-op.
    func setRole(personId: String, isAdmin: Bool) async throws {
        guard let client else { return }
        notePersonUpdated(try await client.setPersonRole(id: personId, isAdmin: isAdmin))
    }

    func removeMember(personId: String) async throws {
        guard let client else { return }
        notePersonUpdated(try await client.removePerson(id: personId))
    }

    func restoreMember(personId: String) async throws {
        guard let client else { return }
        notePersonUpdated(try await client.restorePerson(id: personId))
    }

    func setConversationImage(conversationId: String, imageData: Data) async {
        guard let client, let prepared = AvatarImagePrep.prepare(imageData) else { return }
        guard let conversation = try? await client.setConversationImage(
            conversationId: conversationId, data: prepared.data, contentType: prepared.contentType
        ) else { return }
        upsert(conversation: conversation)
    }

    func clearConversationImage(conversationId: String) async {
        guard let client,
              let conversation = try? await client.clearConversationImage(
                  conversationId: conversationId
              )
        else { return }
        upsert(conversation: conversation)
    }

    private func upsert(conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            // The hub restates a conversation on every rename, member change
            // and read; one that came back identical writes nothing, and one
            // that differs only in its read marks (a receipt has landed since
            // the last restatement) updates the marks and leaves the list be.
            let existing = conversations[index]
            // The restatement speaks for the marks whether or not the row
            // changed in any other way (a receipt may have moved the slot
            // past the array's copy, and the hub may have moved it back).
            applyRestatedReadMarks(conversation.readMarks, for: conversation.id)
            guard existing != conversation else { return }
            if existing.isSameExceptReadMarks(conversation) { return }
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
            applyRestatedReadMarks(conversation.readMarks, for: conversation.id)
        }
        scheduleSave()
    }

    // MARK: - Display helpers

    /// Several wire shapes carry only a display name (message senders, typing,
    /// task owners); resolve back to the person so their picture can render.
    func person(named name: String) -> Person? {
        people.values.first { $0.name == name }
    }

    func displayName(for conversation: Conversation) -> String {
        if let title = conversation.title, !title.isEmpty { return title }
        // Only a conversation with nobody but me in it is named for me. A
        // group whose other members were removed (and, with a newer hub,
        // dropped from member_ids) reads "Conversation", not my own name.
        if let alone = Self.nameWithNoOthers(conversation, meId: me?.id, meName: me?.name, people: people) {
            return alone
        }
        let names = displayMembers(of: conversation).map(\.name)
        return names.isEmpty ? "Conversation" : names.joined(separator: ", ")
    }

    /// The name when nobody but me is left to name a thread for, else nil.
    static func nameWithNoOthers(
        _ conversation: Conversation, meId: String?, meName: String?, people: [String: Person]
    ) -> String? {
        let others = conversationMembers(of: conversation, people: people).filter { $0.id != meId }
        guard others.isEmpty else { return nil }
        let isSelfOnly = conversation.kind == "dm" && conversation.memberIds.allSatisfy { $0 == meId }
        return isSelfOnly ? (meName ?? "Me") : "Conversation"
    }

    /// Group membership survives removal for history and restoration, but
    /// current member lists must follow the roster. Keep a removed DM partner
    /// visible so their existing conversation still has its name and picture.
    func conversationMembers(of conversation: Conversation) -> [Person] {
        Self.conversationMembers(of: conversation, people: people)
    }

    static func conversationMembers(of conversation: Conversation, people: [String: Person]) -> [Person] {
        conversation.memberIds.compactMap { people[$0] }.filter { person in
            !person.isService && (conversation.kind == "dm" || !person.isRemoved)
        }
    }

    /// The members a thread is named and avatared for. The assistant can ride
    /// in every thread, so bots only count when no human is left.
    func displayMembers(of conversation: Conversation) -> [Person] {
        let others = conversationMembers(of: conversation).filter { $0.id != me?.id }
        let humans = others.filter { $0.kind != "bot" }
        return humans.isEmpty ? others : humans
    }

    /// The assistant is whichever person the server marks as a bot.
    func isAssistant(_ person: Person) -> Bool {
        person.kind == "bot"
    }

    // `mentionNames` (stored, top of the class): every name a bubble draws as
    // a tag. Company-wide rather than per-thread on purpose: a message keeps
    // showing the tag its sender wrote even after that person leaves the room
    // it was written in. Sorted, and not incidentally: this feeds the
    // transcript's size memo and its re-render guard, and `people` is a
    // dictionary whose values come out in no defined order. Recomputed by
    // `peopleDidChange` only when a name actually changed.

    /// Message text for a surface that draws no attributes — previews,
    /// quotes, notification banners. Same words the bubble shows. Memoized
    /// (bounded) by the words and the roster version: a Markdown render of a
    /// long message is milliseconds, and a list asks for every row on every
    /// pass. The input is never cut.
    func plainText(_ content: String) -> String {
        let key = PlainTextKey(content: content, rosterVersion: rosterVersion)
        if let cached = plainTextMemo[key] { return cached }
        let text = MentionText.plain(content, names: mentionNames)
        if plainTextMemo.count >= Self.plainTextMemoLimit { plainTextMemo.removeAll(keepingCapacity: true) }
        plainTextMemo[key] = text
        return text
    }

    /// Who can be tagged in this thread, and what the draft becomes when one
    /// is picked. The rules live in `MentionSuggestions`; the roster is here.
    static func mentionMembers(memberIds: [String], meId: String?, people: [String: Person]) -> [Person] {
        memberIds
            .filter { $0 != meId }
            .compactMap { people[$0] }
            .filter { !$0.isService && !$0.isRemoved }
    }

    func mentionSuggestions(draft: String, conversationId: String) -> MentionSuggestions {
        let room = conversation(conversationId)
        return MentionSuggestions(
            draft: draft,
            // A service holds no roster seat, but it does keep the thread
            // membership it already had — so the seat has to be filtered
            // here or the picker offers a machine that cannot be tagged.
            members: Self.mentionMembers(
                memberIds: room?.memberIds ?? [], meId: me?.id, people: people),
            assistant: people.values.filter { isAssistant($0) }.min { $0.name < $1.name }
        )
    }

    func typingNames(in conversationId: String) -> [String] {
        let now = Date()
        return (typingByConversation[conversationId] ?? [:])
            .filter { $0.value > now }
            .compactMap { people[$0.key]?.name }
    }

    /// A DM whose whole other side is bots — rendered with the bot mark.
    func isBotConversation(_ conversation: Conversation) -> Bool {
        guard conversation.kind == "dm" else { return false }
        let others = conversation.memberIds.filter { $0 != me?.id }
        guard !others.isEmpty else { return false }
        return others.allSatisfy { people[$0]?.kind == "bot" }
    }

    func isOnline(_ conversation: Conversation) -> Bool {
        conversation.memberIds.contains { $0 != me?.id && onlinePersonIds.contains($0) }
    }
}

// The store rebuilds a row in a few places; each changes one or two fields.
extension Conversation {
    /// The row after a message lands: its newest message and unread count, with
    /// the live read marks (a row rebuilt here is the one place the old marks
    /// could otherwise be written back over a receipt).
    fileprivate func bumped(lastMessage: Message?, unreadCount: Int, readMarks: [ReadMark]) -> Conversation {
        Conversation(
            id: id, kind: kind, title: title, memberIds: memberIds, createdAt: createdAt,
            lastMessage: lastMessage, unreadCount: unreadCount, readMarks: readMarks,
            roomSlug: roomSlug, avatarId: avatarId
        )
    }

    fileprivate func replacingReadMarks(_ marks: [ReadMark]) -> Conversation {
        Conversation(
            id: id, kind: kind, title: title, memberIds: memberIds, createdAt: createdAt,
            lastMessage: lastMessage, unreadCount: unreadCount, readMarks: marks,
            roomSlug: roomSlug, avatarId: avatarId
        )
    }

    /// Equal in every field a list or a header draws; only the marks may differ.
    fileprivate func isSameExceptReadMarks(_ other: Conversation) -> Bool {
        id == other.id && kind == other.kind && title == other.title && memberIds == other.memberIds
            && createdAt == other.createdAt && unreadCount == other.unreadCount
            && roomSlug == other.roomSlug && avatarId == other.avatarId
            && lastMessage == other.lastMessage
    }
}

#if DEBUG && (os(macOS) || targetEnvironment(simulator))
extension AppStore {
    // In-memory UI fixtures never enroll, open a socket, or persist a session.
    // swiftlint:disable:next cyclomatic_complexity
    private func loadSimulatorFixture() {
        loadedSimulatorFixture = true
        let fixture = HQSimulatorFixture()
        // The scenario is an explicit navigation choice; refresh must not auto-open another thread.
        didOpenInitialChat = true
        session = StoredSession(bearer: "ui-fixture-no-network", deviceId: "qa-device", person: fixture.people[0])
        people = Dictionary(uniqueKeysWithValues: fixture.people.map { ($0.id, $0) })
        if HQSimulatorFixture.scenario == "compose" {
            people["jordan"] = Person(
                id: "jordan", name: "Jordan", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil
            )
        }
        conversations = fixture.conversations
        if HQSimulatorFixture.scenario == "home" {
            setDraftText("Let's confirm the room plan.", for: "home-5")
            setDraftText("Can you take another look?", for: "bo-dm")
            setDraftAttachments([
                Attachment(
                    id: "home-draft-file", fileName: "Supply checklist.pdf", contentType: "application/pdf",
                    byteSize: 1024, width: nil, height: nil
                )
            ], for: "home-6")
        }
        messagesByConversation = fixture.messages
        calls = fixture.calls
        tasks = fixture.tasks
        projects = fixture.projects
        supportsOpenTranscripts = ProcessInfo.processInfo.environment["HQ_UI_OPEN_TRANSCRIPTS"] != "off"
        onlinePersonIds = ["bo"]
        if ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "empty" {
            conversations = []
            messagesByConversation = [:]
            calls = []
            tasks = []
            projects = []
        }
        phase = .ready
        showFixtureScenario(HQSimulatorFixture.scenario)
    }

    func addFixtureIncomingMessage() {
        guard HQSimulatorFixture.isEnabled, let id = selectedConversationId else { return }
        let message = Message(id: "z-live-\(UUID().uuidString)", conversationId: id,
                              senderPersonId: "bo", senderName: "Bo",
                              content: "New incoming message. Reading history should stay in place.",
                              createdAt: ISO8601DateFormatter().string(from: Date()))
        publishMessages(loadedMessages(id) + [message], in: id)
    }

    func showFixtureScenario(_ scenario: String) {
        guard HQSimulatorFixture.isEnabled else { return }
        let fixture = HQSimulatorFixture()
        isDetailPanelOpen = false
        activeCallId = nil
        phase = .ready
        switch scenario {
        case "enrollment": phase = .enrolling
        case "ring":
            incomingCall = IncomingCall(
                call: fixture.calls[0], callerName: "Bo",
                conversationTitle: "Spring workshop planning", expiresAt: "2099-01-01T00:00:00Z"
            )
        case "call":
            activeCallId = calls.first?.id
            #if os(macOS)
            destination = .conversation("studio")
            #endif
        case "chat", "pins": destination = .conversation("studio")
        case "history":
            destination = .conversation("studio")
            exhaustedHistory.remove("studio")
            publishMessages((0..<90).map { index in
                Message(id: String(format: "h%04d", index), conversationId: "studio",
                        senderPersonId: "bo", senderName: "Bo",
                        content: "Planning note \(index + 1). Keep the schedule predictable and leave enough room for the conversation. "
                            + "Check the sign-up form and the room plan at compact window sizes.",
                        createdAt: "2026-09-14T02:00:00Z")
            }, in: "studio")
        case "composer":
            destination = .conversation("studio")
            setDraftText(
                "Here are the updated room plans.\n"
                    + "The input grows with the message.\nReady for another look.",
                for: "studio")
            replyTarget = fixture.messages["studio"]?.first
            setDraftAttachments([
                Attachment(
                    id: "composer-file", fileName: "Room plan.pdf", contentType: "application/pdf",
                    byteSize: 2048, width: nil, height: nil
                )
            ], for: "studio")
        case "tasks": openProjects()
        case "projects": openProjects(HQSimulatorFixture.route)
        case "meetings": destination = .meetings
        case "files": destination = .files
        case "settings", "settings-general", "settings-coding", "settings-admin":
            #if os(macOS)
            if let page = SettingsPage(rawValue: String(scenario.dropFirst("settings-".count))) { settings.page = page }
            // `HQ_UI_SETTINGS_PAGES=general,admin`: then these pages, 3 s apart.
            let pages = (ProcessInfo.processInfo.environment["HQ_UI_SETTINGS_PAGES"] ?? "")
                .split(separator: ",").compactMap { SettingsPage(rawValue: String($0)) }
            Task {
                for page in pages {
                    try? await Task.sleep(for: .seconds(3))
                    settings.page = page
                }
            }
            #endif
            if HQSettingsFixture.isMember { showFixtureAsMember() }
            destination = .settings
        default: break
        }
    }
    private func showFixtureAsMember() {
        guard let session else { return }
        self.session = StoredSession(
            bearer: session.bearer, deviceId: session.deviceId,
            person: Person(id: session.person.id, name: session.person.name, kind: "person",
                           isAdmin: false, avatarId: nil, removedAt: nil))
    }
}
#endif

#if DEBUG && (os(macOS) || targetEnvironment(simulator))
    extension AppStore {
        func fixtureMessages(in conversationId: String) -> [Message] {
            messagesByConversation[conversationId] ?? []
        }
    }
#endif
