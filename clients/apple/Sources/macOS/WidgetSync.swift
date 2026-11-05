import Foundation
import WidgetKit
import os

private let syncLog = Logger(subsystem: WidgetIdentity.logSubsystem, category: "widgets")

/// Keeps the desktop widgets current while HQ runs: mints the extension's
/// widget key, writes each fresh summary (and your picture) to the App Group
/// shelf, and asks WidgetKit to redraw. With HQ closed the extension fetches
/// for itself; this is only the fast path, and it stays silent on a Mac with
/// no HQ widget on it, or against a server that has no widgets.
///
/// Widgets need an App Group, which only a build signed with a team has
/// (`HQ_SIGNING_MODE = team`, README "Desktop widgets"). Any other build
/// compiles this class without `HQ_WIDGETS`, so `start` and `stop` do nothing
/// and WidgetKit is never asked for anything.
@MainActor
final class WidgetSync {
    static let shared = WidgetSync()

    /// Whether this build carries widgets at all.
    #if HQ_WIDGETS
    nonisolated static let isBuilt = true
    #else
    nonisolated static let isBuilt = false
    #endif

    /// Debounce for a burst of task frames, and the idle beat for what no frame announces.
    private static let settle: Duration = .seconds(2)
    nonisolated private static let beat: TimeInterval = 5 * 60
    /// WidgetKit never says when it drops a reload (it budgets them for a background app), and
    /// `lastReloaded` is set when one is *asked for*, so a dropped reload of unchanged content is not
    /// seen. This ceiling is the repair: the outer bound on how stale a widget can stay. It is checked
    /// on every fetch (the 5-minute beat, task frames and reconnects), with half a beat of slack (see
    /// `shouldReload`), so in practice a widget is redrawn between about 12.5 and 17.5 minutes after its
    /// last reload at the latest.
    nonisolated static let longestWithoutReload: TimeInterval = 15 * 60

    private var api: WidgetAPI?
    private var personId: String?
    private var deviceId: String?
    private var pending: Task<Void, Never>?
    private var timer: Timer?
    /// The server answered 404: it has no widget routes. Quiet until relaunch.
    private var isServerWithoutWidgets = false
    /// What the last reload this app *asked for* was drawn from, and when. Held in memory, never read
    /// from the shelf: the shelf is written before the reload is asked, so a change the shelf already
    /// holds must still look new. It cannot see a reload WidgetKit dropped; the ceiling repairs that.
    private var lastReloaded: (summary: WidgetSummary, at: Date)?

    private init() {}

    /// Idempotent: the socket calls it on every (re)connect.
    func start(bearer: String, personId: String, deviceId: String) {
        #if HQ_WIDGETS
        #if DEBUG
        if HQSimulatorFixture.isEnabled { return }
        #endif
        guard WidgetShelf.isAvailable, let base = URL(string: HQConfig.baseURLString) else { return }
        let isSame = api?.bearer == bearer && self.personId == personId
        api = WidgetAPI(baseURL: base, bearer: bearer)
        self.personId = personId
        self.deviceId = deviceId
        if !isSame {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: Self.beat, repeats: true) { _ in
                Task { @MainActor in WidgetSync.shared.refreshSoon() }
            }
        }
        refreshSoon()
        #endif
    }

    /// Sign-out: the key dies on the server and everything leaves the shelf.
    func stop() {
        #if HQ_WIDGETS
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        let api = self.api
        self.api = nil
        personId = nil
        deviceId = nil
        lastReloaded = nil
        WidgetShelf.clear()
        WidgetCenter.shared.reloadAllTimelines()
        if let api { Task { try? await api.revokeKey() } }
        #endif
    }

    func refreshSoon() {
        guard api != nil, !isServerWithoutWidgets else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Whether this Mac shows an HQ widget. A Mac that cannot load the
    /// extension (macOS 15) has none, so it never calls the server for them.
    private func hasWidgets() async -> Bool {
        let installed = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return installed.contains { $0.kind.hasPrefix(WidgetIdentity.kindPrefix) }
    }

    /// Still the session this call started under — not signed out, not
    /// another person — after an await.
    private func isCurrent(_ api: WidgetAPI) -> Bool {
        self.api?.bearer == api.bearer
    }

    private func refresh() async {
        guard let api, let personId, let deviceId, !isServerWithoutWidgets, await hasWidgets() else { return }
        guard isCurrent(api) else { return }
        await ensureKey(api: api, personId: personId, deviceId: deviceId)
        guard isCurrent(api), !isServerWithoutWidgets else { return }
        do {
            let (summary, data) = try await api.summary()
            guard isCurrent(api), let key = WidgetShelf.loadCredentials()?.key else { return }
            // The app's summary goes to the shelf under the key that is saved now, so a key the
            // extension just dropped is never refilled with someone's tasks.
            guard WidgetShelf.saveSummary(data, fetchedWith: key) else { return }
            let gotAvatar = await cacheAvatar(summary, api: api)
            // The server stamps every summary with the time it was built, so most fetches differ from the
            // last in that field alone. Widgets redraw only when what they show changed.
            let now = Date()
            guard Self.shouldReload(summary, previous: lastReloaded, now: now, gotAvatar: gotAvatar) else { return }
            lastReloaded = (summary, now)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            note(error, doing: "summary refresh")
        }
    }

    /// One key per device and person; a new sign-in (a new device), a different server, or a key the
    /// extension deleted because the server refused it, mints again. A key minted while sign-out raced
    /// it is revoked, never saved.
    private func ensureKey(api: WidgetAPI, personId: String, deviceId: String) async {
        let base = api.baseURL.absoluteString
        if let saved = WidgetShelf.loadCredentials(),
           Self.keepsKey(saved, personId: personId, deviceId: deviceId, baseURL: base) { return }
        do {
            let key = try await api.mintKey()
            guard isCurrent(api) else {
                try? await api.revokeKey()
                return
            }
            WidgetShelf.saveCredentials(.init(baseURL: base, key: key, personId: personId, deviceId: deviceId))
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            note(error, doing: "key mint")
        }
    }

    private func note(_ error: Error, doing work: String) {
        if let failure = error as? WidgetAPI.Failure, failure.status == 404 {
            isServerWithoutWidgets = true
            timer?.invalidate()
            timer = nil
            syncLog.info("server has no /v1/widgets; widget sync paused until relaunch")
            return
        }
        syncLog.error("widget \(work, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Your face for the board's cards: the extension holds no bearer that
    /// can read pictures, so the app leaves it on the shelf.
    /// True when it saved a picture the shelf did not have, which the widgets should then draw.
    private func cacheAvatar(_ summary: WidgetSummary, api: WidgetAPI) async -> Bool {
        let me = summary.me
        guard let avatarId = me.avatarId, !WidgetShelf.hasAvatar(personId: me.id, avatarId: avatarId),
              let data = try? await api.avatar(personId: me.id, avatarId: avatarId), isCurrent(api) else { return false }
        WidgetShelf.saveAvatar(data, personId: me.id, avatarId: avatarId)
        return true
    }

    /// Whether the saved key is still this person's, on this device and server.
    nonisolated static func keepsKey(_ saved: WidgetShelf.Credentials, personId: String, deviceId: String, baseURL: String) -> Bool {
        saved.personId == personId && saved.deviceId == deviceId && saved.baseURL == baseURL
    }

    /// Whether two summaries would draw the same widgets: equal but for `generatedAt`, which the
    /// widgets use only to decide how fresh a cached copy is. Nil (nothing on the shelf) is never the same.
    nonisolated static func isSameContent(_ summary: WidgetSummary, as previous: WidgetSummary?) -> Bool {
        guard var previous else { return false }
        previous.generatedAt = summary.generatedAt
        return previous == summary
    }
}

extension WidgetSync {
    /// Whether to ask WidgetKit to redraw for this fetch. `previous` is what the last *requested* reload
    /// drew from. A reload is due when:
    /// - nothing was requested yet (launch, or after sign-out), or a new picture landed;
    /// - the content differs (`isSameContent`);
    /// - the last reload is about `longestWithoutReload` old (within half a beat: this runs on the beat
    ///   and also on task frames and reconnects, so `previous.at` need not line up with the beat), so a
    ///   dropped reload heals within roughly 12.5-17.5 minutes: the ceiling is the repair, not the
    ///   content comparison.
    nonisolated static func shouldReload(
        _ summary: WidgetSummary, previous: (summary: WidgetSummary, at: Date)?, now: Date, gotAvatar: Bool
    ) -> Bool {
        guard let previous, !gotAvatar else { return true }
        if !isSameContent(summary, as: previous.summary) { return true }
        return now.timeIntervalSince(previous.at) >= longestWithoutReload - beat / 2
    }
}

extension AppStore {
    /// A desktop widget's row: `hq://task/…` opens that task's card, `hq://mine` the board.
    func open(_ link: WidgetLink) {
        switch link {
        case .task(let id): openProjects(.task(id))
        case .mine: openProjects(.mine)
        }
    }
}
