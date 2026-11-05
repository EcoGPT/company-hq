import XCTest

@testable import HQ

/// When HQ.app asks WidgetKit to redraw: only when the summary changed in something a widget shows.
final class WidgetSyncReloadTests: XCTestCase {
    private func sample() throws -> WidgetSummary { try XCTUnwrap(WidgetSummary.sample) }

    func testASummaryThatDiffersOnlyInWhenTheServerBuiltItIsTheSame() throws {
        let shelf = try sample()
        var fetched = shelf
        fetched.generatedAt = shelf.generatedAt.addingTimeInterval(300)
        XCTAssertTrue(WidgetSync.isSameContent(fetched, as: shelf))
    }

    func testAChangedNameOrNothingOnTheShelfReloads() throws {
        let shelf = try sample()
        var renamed = shelf
        renamed.me.name = "Someone else"
        XCTAssertFalse(WidgetSync.isSameContent(renamed, as: shelf))
        XCTAssertFalse(WidgetSync.isSameContent(shelf, as: nil), "nothing on the shelf yet: draw it")
    }

    func testAChangedCountReloadsEvenWithTheSameTimestamp() throws {
        let shelf = try sample()
        var more = shelf
        more.work.open += 1
        XCTAssertFalse(WidgetSync.isSameContent(more, as: shelf))
    }

    func testNothingRequestedYetOrANewPictureAlwaysReloads() throws {
        let now = Date()
        let summary = try sample()
        XCTAssertTrue(WidgetSync.shouldReload(summary, previous: nil, now: now, gotAvatar: false))
        XCTAssertTrue(WidgetSync.shouldReload(summary, previous: (summary, now), now: now, gotAvatar: true))
    }

    func testAQuietSummaryDoesNotReloadWithinTheWindow() throws {
        let start = Date()
        let drawn = try sample()
        var fetched = drawn
        fetched.generatedAt = start.addingTimeInterval(300)
        XCTAssertFalse(WidgetSync.shouldReload(fetched, previous: (drawn, start), now: start.addingTimeInterval(300), gotAvatar: false))
    }

    func testTheCeilingReloadsAboutEveryFifteenMinutesEvenWhenNothingChanged() throws {
        let start = Date()
        let drawn = try sample()
        var fetched = drawn
        fetched.generatedAt = start.addingTimeInterval(900)
        // Two beats on: a quiet server, nothing to draw.
        XCTAssertFalse(WidgetSync.shouldReload(fetched, previous: (drawn, start), now: start.addingTimeInterval(600), gotAvatar: false))
        // The third beat lands a hair under 900 s after the reload was asked (settle and fetch time
        // differ run to run): it must not wait for the fourth beat, 20 minutes out.
        XCTAssertTrue(WidgetSync.shouldReload(fetched, previous: (drawn, start), now: start.addingTimeInterval(899), gotAvatar: false))
        XCTAssertTrue(WidgetSync.shouldReload(fetched, previous: (drawn, start), now: start.addingTimeInterval(900), gotAvatar: false))
    }

    func testAChangeSinceTheLastRequestedReloadReloadsAgainEvenIfTheShelfAlreadyHoldsIt() throws {
        // The shelf is saved before the reload is asked; the comparison is against what was asked.
        let start = Date()
        let drawn = try sample()
        var changed = drawn
        changed.work.blocked += 1
        XCTAssertTrue(WidgetSync.shouldReload(changed, previous: (drawn, start), now: start.addingTimeInterval(60), gotAvatar: false))
        // WidgetKit does not report a dropped reload, so after `changed` was asked for, `previous` is
        // `changed` and the same content looks unchanged. The ceiling is what repairs a drop.
        XCTAssertTrue(WidgetSync.shouldReload(changed, previous: (changed, start), now: start.addingTimeInterval(900), gotAvatar: false))
    }

    func testABuildWithoutATeamNeverStartsTheSyncOrAsksForAnything() async throws {
        XCTAssertFalse(WidgetSync.isBuilt)
        await MainActor.run {
            WidgetSync.shared.start(bearer: "unused", personId: "unused", deviceId: "unused")
            // Nothing started, so there is nothing for a task frame to refresh and nothing to stop.
            WidgetSync.shared.refreshSoon()
            WidgetSync.shared.stop()
        }
    }
}
