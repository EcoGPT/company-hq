import Foundation
import WidgetKit
import os

private let providerLog = Logger(subsystem: WidgetIdentity.logSubsystem, category: "widgets-timeline")

struct SummaryEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary?
    /// False once HQ is signed out on this Mac or its widget key stopped working.
    let isSignedIn: Bool
}

/// Every HQ widget draws from the same summary. HQ.app keeps the shelf fresh
/// while it runs; with HQ closed, the fifteen-minute timeline brings the
/// extension here, and it fetches for itself.
struct SummaryProvider: TimelineProvider {
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: .now, summary: .sample, isSignedIn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        // The gallery shows the cache only for the person whose key is saved; otherwise the invented sample.
        completion(SummaryEntry(date: .now, summary: WidgetShelf.loadCurrentSummary() ?? .sample, isSignedIn: true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        Task {
            let entry = await SummaryLoader.shared.entry()
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(Self.refreshInterval))))
        }
    }
}

/// One fetch for all the widgets: a reload asks every widget for a timeline
/// at once, and they should share the answer.
actor SummaryLoader {
    static let shared = SummaryLoader()

    /// A summary this new came from HQ.app a moment ago; use it as it is.
    private let freshFor: TimeInterval = 60
    private var inFlight: Task<SummaryEntry, Never>?

    func entry() async -> SummaryEntry {
        let entry: SummaryEntry
        if let inFlight {
            entry = await inFlight.value
        } else {
            let task = Task { await Self.load(freshFor: freshFor) }
            inFlight = task
            entry = await task.value
            inFlight = nil
        }
        // Sign-out may have come while the fetch ran, and joiners got the same answer: what is shown
        // must still be the person whose key is saved now.
        return Self.stillCurrent(entry)
    }

    private static func stillCurrent(_ entry: SummaryEntry) -> SummaryEntry {
        guard let summary = entry.summary, !summary.belongs(to: WidgetShelf.loadCredentials()) else { return entry }
        return SummaryEntry(date: entry.date, summary: nil, isSignedIn: false)
    }

    private static func load(freshFor: TimeInterval) async -> SummaryEntry {
        guard let credentials = WidgetShelf.loadCredentials(), let api = WidgetAPI(credentials: credentials) else {
            return SummaryEntry(date: .now, summary: nil, isSignedIn: false)
        }
        let cached = WidgetShelf.loadCurrentSummary()
        if let cached, Date.now.timeIntervalSince(cached.generatedAt) < freshFor {
            return SummaryEntry(date: .now, summary: cached, isSignedIn: true)
        }
        do {
            let (summary, data) = try await api.summary()
            // Not written, and not shown, if the key was replaced or removed while this ran.
            guard WidgetShelf.saveSummary(data, fetchedWith: credentials.key) else {
                return SummaryEntry(date: .now, summary: nil, isSignedIn: false)
            }
            return SummaryEntry(date: .now, summary: summary, isSignedIn: true)
        } catch let failure as WidgetAPI.Failure where failure.status == 401 {
            // A key the server ended (its device was revoked): drop it so HQ mints another.
            WidgetShelf.dropCredentials(ifKey: credentials.key)
            return SummaryEntry(date: .now, summary: nil, isSignedIn: false)
        } catch {
            providerLog.error("summary fetch failed: \(error.localizedDescription, privacy: .public)")
            return SummaryEntry(date: .now, summary: cached, isSignedIn: true)
        }
    }
}
