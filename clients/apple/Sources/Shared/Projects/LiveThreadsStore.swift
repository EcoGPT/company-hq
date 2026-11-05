import Foundation
import Observation

/// The Tasks tab's Live state, one per signed-in session: the hub's
/// sessions, the clock the ages read, and which folds are open. `AppStore`
/// holds it, so leaving Tasks or opening a thread and coming back shows the
/// list at once with its folds as they were.
@MainActor @Observable
final class LiveThreadsStore {
    private(set) var threads: [CodingThread] = []
    /// False until the first read answers: the list shows a spinner only then.
    private(set) var hasLoaded = false
    private(set) var failure: String?
    /// What the ages are measured against. Ticked once a minute without a
    /// read, and set again when a read changes the list or finds it a minute old.
    private(set) var now = Date()
    /// Open "+N more" and "+N more with no name or task" rows.
    var expanded: Set<String> = []
    /// Where the canvas was zoomed and panned to. The canvas's viewport is torn down with the
    /// board when a thread opens, so it keeps its camera here and a return finds it as it was.
    /// Not observed: only the viewport writes it, and nothing redraws for it.
    @ObservationIgnored var canvasCamera: LiveCanvasCamera?

    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var loadedAt: Date?

    /// Older than this at the list's appearance, it reads again at once.
    static let staleAfter: TimeInterval = 30

    init(threads: [CodingThread]? = nil) {
        if let threads {
            self.threads = threads
            hasLoaded = true
        }
    }

    var isStale: Bool { loadedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true }

    func expand(_ key: String) { expanded.insert(key) }

    func tick() { now = Date() }

    /// The launch cache's sessions, shown until the first read answers. Never
    /// over a read already landed, and still stale, so the list re-reads at once.
    func seed(_ cached: [CodingThread]) {
        guard !hasLoaded else { return }
        threads = cached
        hasLoaded = true
    }

    /// Reads every page of the window. A result equal to what is held is not
    /// assigned, and then neither is a fresh clock, so a quiet poll redraws
    /// nothing (`LiveThreadsModel.shouldMoveClock`).
    func refresh(client: HQClient?) async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let walk = await client.walkActiveCodingThreads(sinceMinutes: LiveThreadsModel.windowMinutes)
        if Task.isCancelled || (walk.failure as? URLError)?.code == .cancelled { return }
        let result = LiveThreadsModel.resolve(walk, held: threads, hasLoaded: hasLoaded)
        let changed = result.threads != threads || result.hasLoaded != hasLoaded
        if result.threads != threads { threads = result.threads }
        if result.hasLoaded != hasLoaded { hasLoaded = result.hasLoaded }
        if result.failed {
            let message = "Couldn’t load agents. Please try again."
            if failure != message { failure = message }
        } else {
            if failure != nil { failure = nil }
            loadedAt = Date()
        }
        if LiveThreadsModel.shouldMoveClock(changed: changed, clock: now) { now = Date() }
    }
}
