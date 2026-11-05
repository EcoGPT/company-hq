import LinkPresentation
import XCTest

@testable import HQ

// Past its bound a fetch is cancelled, and the cancel has to reach the
// provider: LPMetadataProvider's async call does not watch Task.cancel, so
// without it a timed-out fetch keeps running after its slot is given back.
@MainActor
final class LinkPreviewCancelTests: XCTestCase {
    /// A provider that never answers on its own; only `cancel()` ends a fetch.
    /// Its state is behind the lock, since a cancel may come from any thread.
    private final class StuckProvider: LinkMetadataProviding, @unchecked Sendable {
        private let lock = NSLock()
        private nonisolated(unsafe) var waiter: CheckedContinuation<LPLinkMetadata, Error>?
        private nonisolated(unsafe) var isCancelled = false
        private nonisolated(unsafe) var cancels = 0
        private nonisolated(unsafe) var starts = 0
        private nonisolated(unsafe) var ends = 0

        var cancelCount: Int { lock.withLock { cancels } }
        var startCount: Int { lock.withLock { starts } }
        var endCount: Int { lock.withLock { ends } }

        func startFetchingMetadata(for url: URL) async throws -> LPLinkMetadata {
            defer { lock.withLock { ends += 1 } }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                starts += 1
                if isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        }

        nonisolated func cancel() {
            lock.withLock { cancels += 1 }
            release()
        }

        /// Ends a stuck fetch without counting as a cancel (test cleanup).
        nonisolated func release() {
            lock.lock()
            isCancelled = true
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(throwing: CancellationError())
        }
    }

    private let url = URL(string: "https://example.com/stuck")!

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCancellingTheFetchCancelsTheProvider() async throws {
        let provider = StuckProvider()
        defer { provider.release() }
        let url = url
        let fetch = Task { await LinkPreviewCache.fetchMetadata(for: url, with: provider) }
        try await waitUntil { provider.startCount == 1 }
        XCTAssertEqual(provider.startCount, 1)

        fetch.cancel()
        let ended = expectation(description: "cancelled fetch ended")
        var result: LPLinkMetadata?
        Task {
            result = await fetch.value
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(provider.cancelCount, 1)
        XCTAssertNil(result)
    }

    /// The real provider class, answering at once and noting the thread its
    /// fetch was started on.
    private final class ThreadNotingProvider: LPMetadataProvider, @unchecked Sendable {
        private(set) var wasStartedOnMain = false

        override func startFetchingMetadata(
            for url: URL, completionHandler: @escaping (LPLinkMetadata?, Error?) -> Void
        ) {
            wasStartedOnMain = Thread.isMainThread
            let metadata = LPLinkMetadata()
            metadata.title = "Answered"
            completionHandler(metadata, nil)
        }
    }

    // LPMetadataProvider is started on the main thread, as the old
    // `@MainActor` fetch closure did before the protocol stood in for it.
    func testTheProviderIsStartedOnTheMainThread() async {
        let provider = ThreadNotingProvider()
        let metadata = await LinkPreviewCache.fetchMetadata(for: url, with: provider)
        XCTAssertEqual(metadata?.title, "Answered")
        XCTAssertTrue(provider.wasStartedOnMain)
    }

    func testATimedOutFetchStopsItsProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StuckProvider()
        defer { provider.release() }
        let cache = LinkPreviewCache(
            diskDirectory: directory,
            fetch: { url in await LinkPreviewCache.fetchMetadata(for: url, with: provider) },
            fetchTimeout: .milliseconds(200)
        )

        guard case .unavailable = await cache.state(for: url) else {
            return XCTFail("a timed-out fetch answers unavailable")
        }
        try await waitUntil { provider.endCount == 1 }
        XCTAssertEqual(provider.cancelCount, 1)
        XCTAssertEqual(provider.endCount, 1)
    }
}
