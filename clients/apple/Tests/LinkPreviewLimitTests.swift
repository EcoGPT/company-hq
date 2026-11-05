import CryptoKit
import LinkPresentation
import XCTest

@testable import HQ

// The transcript mounts every row at once, so a chat with many distinct
// links used to start that many page fetches together. They now go three at
// a time; a link already archived on disk never waits behind them.
@MainActor
final class LinkPreviewLimitTests: XCTestCase {
    /// Holds every fetch until opened.
    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("link-limit-\(UUID().uuidString)", isDirectory: true)
    }

    func testAtMostThreeFetchesRunAtOnce() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate()
        var live = 0
        var most = 0
        let cache = LinkPreviewCache(diskDirectory: directory, fetch: { _ in
            live += 1
            most = max(most, live)
            await gate.wait()
            live -= 1
            return nil
        })

        let loads = (0..<10).map { index in
            Task { await cache.state(for: URL(string: "https://example.com/page-\(index)")!) }
        }
        // Every disk lookup misses, and each reaches its fetch or the queue.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThanOrEqual(most, 3)

        gate.open()
        for load in loads {
            guard case .unavailable = await load.value else { return XCTFail("expected unavailable") }
        }
        XCTAssertEqual(live, 0)
    }

    func testAnArchivedLinkDoesNotWaitBehindHeldFetches() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archived = URL(string: "https://example.com/archived")!
        let metadata = LPLinkMetadata()
        metadata.originalURL = archived
        metadata.url = archived
        metadata.title = "Archived page"
        let digest = SHA256.hash(data: Data(archived.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NSKeyedArchiver.archivedData(withRootObject: metadata, requiringSecureCoding: true)
            .write(to: directory.appendingPathComponent("\(digest).metadata"))

        let gate = Gate()
        var live = 0
        let cache = LinkPreviewCache(diskDirectory: directory, fetch: { _ in
            live += 1
            await gate.wait()
            live -= 1
            return nil
        })
        let held = (0..<3).map { index in
            Task { await cache.state(for: URL(string: "https://example.com/held-\(index)")!) }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(live, 3)

        let answered = expectation(description: "archived link answered")
        var title: String?
        Task {
            if case .loaded(let preview) = await cache.state(for: archived) { title = preview.title }
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertEqual(title, "Archived page")

        gate.open()
        for load in held { _ = await load.value }
    }
}
