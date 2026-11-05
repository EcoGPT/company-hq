import LinkPresentation
import XCTest

@testable import HQ

// A fetch slot is held only for a bounded time. LPMetadataProvider's own
// timeout is the only other bound, and three fetches that never call back
// must not leave every later link a plain text link until the app quits.
@MainActor
final class LinkPreviewTimeoutTests: XCTestCase {
    /// Holds the stuck fetches until the test ends.
    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("link-timeout-\(UUID().uuidString)", isDirectory: true)
    }

    func testThreeStuckFetchesDoNotBlockAFourthBeyondTheBound() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate()
        defer { gate.open() }
        let cache = LinkPreviewCache(
            diskDirectory: directory,
            fetch: { url in
                if url.path().hasPrefix("/stuck") {
                    // Never answers on its own, and ignores cancellation.
                    await gate.wait()
                    return nil
                }
                let metadata = LPLinkMetadata()
                metadata.originalURL = url
                metadata.url = url
                metadata.title = "Fourth page"
                return metadata
            },
            fetchLimit: 3,
            fetchTimeout: .milliseconds(300)
        )

        let stuck = (0..<3).map { index in
            Task { await cache.state(for: URL(string: "https://example.com/stuck-\(index)")!) }
        }
        // All three reach their fetch and hold every slot.
        try await Task.sleep(for: .milliseconds(100))

        let answered = expectation(description: "fourth link answered")
        var title: String?
        Task {
            let url = URL(string: "https://example.com/fourth")!
            if case .loaded(let preview) = await cache.state(for: url) { title = preview.title }
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 3)
        XCTAssertEqual(title, "Fourth page")

        // The stuck links gave up as a transient miss, not a hang.
        let timedOut = expectation(description: "stuck links gave up")
        var results: [LinkPreviewCache.State] = []
        Task {
            for load in stuck { results.append(await load.value) }
            timedOut.fulfill()
        }
        await fulfillment(of: [timedOut], timeout: 3)
        XCTAssertEqual(results.count, 3)
        for result in results {
            guard case .unavailable = result else { return XCTFail("expected unavailable") }
        }
    }
}
