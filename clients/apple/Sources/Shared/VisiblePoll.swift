import SwiftUI

/// A page poll that runs only while the window (Mac) or scene (iPhone) is
/// actually on screen.
///
/// A page that re-reads itself on a timer would otherwise keep polling all day
/// from behind a hidden, minimized or fully occluded window. Put this in a
/// `.background`: it draws nothing, and its task is keyed on visibility, so
/// leaving the screen cancels the loop and coming back restarts it. The loop
/// remembers when the action last ran: coming back reads at once if a whole
/// interval has passed since then, and otherwise sleeps only the remainder
/// before the first tick, so the data is never older than one interval plus
/// the read itself, however the pauses fall.
///
/// On iPhone only `.background` pauses: `.inactive` is Control Center, the
/// notification shade, the app switcher or a call banner.
struct VisiblePoll<Key: Hashable>: View {
    /// Restarts the loop when it changes.
    let key: Key
    var interval: Duration = .seconds(30)
    let action: @MainActor () async -> Void

    /// When the action last ran for `key` (or when the loop first saw it). A
    /// reference box, so writing it never invalidates the view.
    @State private var lastRun = LastRun()
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    private final class LastRun {
        var key: Key?
        var at = ContinuousClock.now
    }

    private struct Run: Hashable {
        let key: Key
        let isVisible: Bool
    }

    var body: some View {
        #if os(macOS)
        WindowVisibilityReader { isVisible in probe(isVisible: isVisible) }
        #else
        probe(isVisible: scenePhase != .background)
        #endif
    }

    /// How long to sleep before the next read, `elapsed` after the last one:
    /// nothing once a whole interval has passed, otherwise what is left of it.
    /// A negative `elapsed` (the clock moved) waits the full interval.
    nonisolated static func remainingWait(elapsed: Duration, interval: Duration) -> Duration {
        if elapsed < .zero { return interval }
        if elapsed >= interval { return .zero }
        return interval - elapsed
    }

    private func probe(isVisible: Bool) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: Run(key: key, isVisible: isVisible)) {
                if lastRun.key != key {
                    lastRun.key = key
                    lastRun.at = .now
                }
                guard isVisible else { return }
                while !Task.isCancelled {
                    let wait = Self.remainingWait(elapsed: .now - lastRun.at, interval: interval)
                    if wait > .zero { try? await Task.sleep(for: wait) }
                    if Task.isCancelled { break }
                    await action()
                    // A read abandoned by a pause does not count as a refresh.
                    if !Task.isCancelled { lastRun.at = .now }
                }
            }
    }
}
