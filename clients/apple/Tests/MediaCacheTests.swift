import AppKit
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers
import XCTest

@testable import HQ

/// Intercepts the attachment route on the shared session, so `HQClient`'s real
/// `download(for:)` path runs without a hub.
private final class AttachmentStubProtocol: URLProtocol {
    nonisolated(unsafe) static var hits = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var delay: TimeInterval = 0
    private static let lock = NSLock()

    static func reset(status: Int = 200, body: Data = Data(), delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        hits = 0
        self.status = status
        self.body = body
        self.delay = delay
    }

    static var hitCount: Int { lock.lock(); defer { lock.unlock() }; return hits }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/v1/attachments/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.hits += 1
        let status = Self.status, body = Self.body, delay = Self.delay
        Self.lock.unlock()
        let respond = { [self] in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}

final class MediaCacheTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func attachment(_ id: String, name: String = "note.txt", type: String = "text/plain",
                            size: Int = 10) -> Attachment {
        Attachment(id: id, fileName: name, contentType: type, byteSize: size, width: nil, height: nil)
    }

    private func entries(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: seed / install

    @MainActor
    func testSeedWritesAtomicallyAndMaterializeNeedsNoClient() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AttachmentFileCache(directory: directory)
        let item = attachment("seeded")
        let bytes = Data("sent from this device".utf8)

        XCTAssertNil(files.materializedURL(for: item))
        files.seed(item, data: bytes)
        // No await in between: materialize must wait for the pending write,
        // not report a miss and throw for want of a client.
        let url = try await files.materialize(item, client: nil)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(entries(in: directory.appendingPathComponent("seeded")), ["note.txt"])

        // Ids are immutable: a second seed never replaces the first file.
        await files.seed(item, data: Data("other".utf8)).value
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testInstallRenamesFinishedDownloadIntoPlace() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("a/b/file.bin")

        let first = directory.appendingPathComponent("tmp-1")
        try Data("one".utf8).write(to: first)
        try AttachmentFileCache.install(first, at: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("one".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(entries(in: destination.deletingLastPathComponent()), ["file.bin"])

        // Losing a race leaves the winner's complete file and no scrap behind.
        let second = directory.appendingPathComponent("tmp-2")
        try Data("two".utf8).write(to: second)
        try AttachmentFileCache.install(second, at: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("one".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(entries(in: destination.deletingLastPathComponent()), ["file.bin"])
    }

    // MARK: download path

    @MainActor
    func testMaterializeStreamsToFileAndSharesOneDownload() async throws {
        URLProtocol.registerClass(AttachmentStubProtocol.self)
        defer { URLProtocol.unregisterClass(AttachmentStubProtocol.self) }
        let bytes = Data(repeating: 7, count: 4096)
        AttachmentStubProtocol.reset(body: bytes, delay: 0.2)
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AttachmentFileCache(directory: directory)
        let client = HQClient(bearer: "test")
        let item = attachment("downloaded", name: "report.pdf", type: "application/pdf")

        async let first = files.materialize(item, client: client)
        async let second = files.materialize(item, client: client, priority: .background)
        let urls = try await [first, second]
        XCTAssertEqual(urls[0], urls[1])
        XCTAssertEqual(try Data(contentsOf: urls[0]), bytes)
        XCTAssertEqual(AttachmentStubProtocol.hitCount, 1)
        XCTAssertEqual(entries(in: urls[0].deletingLastPathComponent()), ["report.pdf"])
    }

    @MainActor
    func testRefusedDownloadLeavesNothingOnDisk() async throws {
        URLProtocol.registerClass(AttachmentStubProtocol.self)
        defer { URLProtocol.unregisterClass(AttachmentStubProtocol.self) }
        AttachmentStubProtocol.reset(status: 404)
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AttachmentFileCache(directory: directory)
        let item = attachment("gone")
        do {
            _ = try await files.materialize(item, client: HQClient(bearer: "test"))
            XCTFail("a 404 must throw")
        } catch {}
        XCTAssertNil(files.materializedURL(for: item))
    }

    @MainActor
    func testCancellingOneWaiterKeepsTheSharedDownloadAlive() async throws {
        URLProtocol.registerClass(AttachmentStubProtocol.self)
        defer { URLProtocol.unregisterClass(AttachmentStubProtocol.self) }
        let bytes = Data(repeating: 1, count: 2048)
        AttachmentStubProtocol.reset(body: bytes, delay: 0.4)
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AttachmentFileCache(directory: directory)
        let client = HQClient(bearer: "test")
        let item = attachment("shared", name: "a.bin", type: "application/octet-stream")

        let staying = Task { try await files.materialize(item, client: client) }
        let leaving = Task { try await files.materialize(item, client: client) }
        try await Task.sleep(nanoseconds: 100_000_000)
        leaving.cancel()
        let url = try await staying.value
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(AttachmentStubProtocol.hitCount, 1)
    }

    // MARK: shared loads and the limiter

    @MainActor
    func testSharedLoadCancelsOnlyWhenEveryWaiterLeaves() async throws {
        let loads = SharedLoads<Int>()
        var started = 0
        let work: (SharedLoads<Int>.Entry) -> Task<Int, Error> = { _ in
            started += 1
            return Task {
                try await Task.sleep(nanoseconds: 300_000_000)
                return 42
            }
        }
        let a = Task { try await loads.load("k", start: work) }
        let b = Task { try await loads.load("k", start: work) }
        try await Task.sleep(nanoseconds: 50_000_000)
        a.cancel()
        let result = try await b.value
        XCTAssertEqual(result, 42)
        XCTAssertEqual(started, 1)

        let c = Task { try await loads.load("k2", start: work) }
        try await Task.sleep(nanoseconds: 50_000_000)
        c.cancel()
        do {
            _ = try await c.value
            XCTFail("the only waiter left: the work is cancelled")
        } catch is CancellationError {}
        // A cancelled entry is never joined: the next caller starts afresh.
        let d = try await loads.load("k2", start: work)
        XCTAssertEqual(d, 42)
        XCTAssertEqual(started, 3)
    }

    @MainActor
    func testLimiterAdmitsNewestFirstAndAtMostItsLimit() async throws {
        let limiter = AsyncLimiter(limit: 2)
        try await limiter.acquire()
        try await limiter.acquire()
        XCTAssertEqual(limiter.holders, 2)

        var order: [Int] = []
        let third = Task { try await limiter.acquire(); order.append(3) }
        let fourth = Task { try await limiter.acquire(); order.append(4) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(limiter.waiting, 2)
        XCTAssertTrue(order.isEmpty)

        // The newest waiter (4) goes first: it is nearest what is on screen.
        limiter.release()
        try await fourth.value
        XCTAssertEqual(order, [4])
        XCTAssertEqual(limiter.holders, 2)
        limiter.release()
        try await third.value
        XCTAssertEqual(order, [4, 3])
        limiter.release(); limiter.release()
        XCTAssertEqual(limiter.holders, 0)
    }

    @MainActor
    func testLimiterCancelsAndPromotesWaiters() async throws {
        let limiter = AsyncLimiter(limit: 1)
        try await limiter.acquire()
        let cancelled = Task { try await limiter.acquire() }
        let ticket = UUID()
        var promoted = false
        let urgent = Task { try await limiter.acquire(ticket: ticket); promoted = true }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(limiter.waiting, 2)

        cancelled.cancel()
        do { try await cancelled.value; XCTFail("cancelled waiter must throw") } catch is CancellationError {}
        XCTAssertEqual(limiter.waiting, 1)

        limiter.promote(ticket)
        try await urgent.value
        XCTAssertTrue(promoted)
        XCTAssertEqual(limiter.holders, 2)
    }

    // MARK: list thumbnails

    @MainActor
    func testListThumbnailDecodesSmallAndLeavesTheTranscriptBudgetAlone() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AttachmentCache(files: AttachmentFileCache(directory: directory))
        let item = try write(fixture(width: 2400, height: 1600), id: "wide", root: directory)

        let loaded = await cache.thumbnail(for: item, client: nil)
        let small = try XCTUnwrap(loaded)
        let bitmap = try XCTUnwrap(small.cgImage(forProposedRect: nil, context: nil, hints: nil))
        // 3:2 landscape: the SHORT side is the target, the long side follows.
        XCTAssertEqual(min(bitmap.width, bitmap.height), AttachmentCache.listThumbnailPixels)
        XCTAssertEqual(max(bitmap.width, bitmap.height), AttachmentCache.listThumbnailPixels * 3 / 2)
        XCTAssertEqual(cache.cachedImageCount, 0)
        XCTAssertEqual(cache.cachedThumbnailCount, 1)
        XCTAssertLessThan(cache.cachedThumbnailBytes, 200_000)

        // Once the 900 px version is cached for the chat, the list reuses it.
        let big = await cache.image(for: item, client: nil)
        let reused = await cache.thumbnail(for: item, client: nil)
        XCTAssertTrue(big === reused)
    }

    func testListThumbnailSizesByTheShortSideAndNeverUpscales() {
        let target = 128
        func pixels(_ width: Int, _ height: Int) -> Int {
            AttachmentCache.listThumbnailMaxPixels(target: target, width: width, height: height)
        }
        // Square: the target itself.
        XCTAssertEqual(pixels(1000, 1000), 128)
        // 16:9 photo: 128 on the short side needs 228 on the long side.
        XCTAssertEqual(pixels(1920, 1080), 228)
        // iPhone screenshot, portrait: same arithmetic, either orientation.
        XCTAssertEqual(pixels(1179, 2556), 278)
        XCTAssertEqual(pixels(2556, 1179), 278)
        // Past 4:1 (up to 16:1) the short side still lands on the target: the
        // cap is on the long side (at most 16x the target), not on aspect.
        XCTAssertEqual(pixels(6_000, 500), 1536)
        XCTAssertEqual(pixels(1179, 8000), 869)
        // Beyond 16:1 the long side is capped, and the short side falls short.
        XCTAssertEqual(pixels(10_000, 500), 2048)
        XCTAssertEqual(pixels(100_000, 500), 2048)
        // An image smaller than the target is not blown up.
        XCTAssertEqual(pixels(100, 60), 100)
        XCTAssertEqual(pixels(64, 64), 64)
        // Unknown or degenerate dimensions fall back to the target.
        XCTAssertEqual(pixels(0, 0), 128)
        XCTAssertEqual(pixels(500, 0), 128)
        // The short side of every result covers the target when the image can.
        for (w, h) in [(1920, 1080), (1179, 2556), (4000, 3000), (3000, 4000), (6_000, 500), (1179, 8000)] {
            let long = pixels(w, h)
            let scale = Double(long) / Double(max(w, h))
            XCTAssertGreaterThanOrEqual(Double(min(w, h)) * scale, Double(target) - 1)
        }
    }

    @MainActor
    func testTallListThumbnailKeepsItsShortSideAtTheTarget() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AttachmentCache(files: AttachmentFileCache(directory: directory))
        let item = try write(fixture(width: 1179, height: 2556), id: "shot", root: directory)
        let loaded = await cache.thumbnail(for: item, client: nil)
        let bitmap = try XCTUnwrap(try XCTUnwrap(loaded).cgImage(forProposedRect: nil, context: nil, hints: nil))
        // 1179x2556 portrait: the short side lands on the target (Image I/O may
        // round a pixel either way), the long side on 278.
        XCTAssertEqual(bitmap.width, AttachmentCache.listThumbnailPixels, accuracy: 1)
        XCTAssertEqual(bitmap.height, 278, accuracy: 1)
    }

    // MARK: link previews

    func testFailureMemoHoldsDeterministicMissesAndExpiresTransientOnes() {
        var memo = LinkFailureMemo()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(memo.isRemembered("a", at: start))

        memo.record("transient", transient: true, at: start)
        memo.record("dead", transient: false, at: start)
        let beforeExpiry = start.addingTimeInterval(LinkFailureMemo.retryInterval - 1)
        XCTAssertTrue(memo.isRemembered("transient", at: beforeExpiry))
        XCTAssertTrue(memo.isRemembered("dead", at: beforeExpiry))

        let afterExpiry = start.addingTimeInterval(LinkFailureMemo.retryInterval + 1)
        XCTAssertFalse(memo.isRemembered("transient", at: afterExpiry))
        // A deterministic miss (the page has no title) stays for the session.
        XCTAssertTrue(memo.isRemembered("dead", at: start.addingTimeInterval(86_400 * 30)))

        // Recorded again, a transient miss gets a fresh window.
        memo.record("transient", transient: true, at: afterExpiry)
        XCTAssertTrue(memo.isRemembered("transient", at: afterExpiry.addingTimeInterval(60)))
    }

    @MainActor
    func testFailedFetchIsRetriedAfterTheMemoExpires() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 2_000_000)
        var fetches = 0
        var online = false
        let cache = LinkPreviewCache(diskDirectory: directory, fetch: { _ in
            fetches += 1
            guard online else { return nil }
            let metadata = LPLinkMetadata()
            metadata.title = "Back online"
            return metadata
        }, now: { clock })
        let link = URL(string: "https://flaky.example/page")!

        _ = await cache.state(for: link)
        _ = await cache.state(for: link)
        XCTAssertEqual(fetches, 1)

        online = true
        clock.addTimeInterval(LinkFailureMemo.retryInterval + 1)
        let state = await cache.state(for: link)
        XCTAssertEqual(fetches, 2)
        guard case .loaded(let preview) = state else { return XCTFail("expected the retry to resolve") }
        XCTAssertEqual(preview.title, "Back online")
    }

    @MainActor
    func testTitlelessPageStaysFailedForTheSession() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 3_000_000)
        var fetches = 0
        let cache = LinkPreviewCache(diskDirectory: directory, fetch: { _ in
            fetches += 1
            return LPLinkMetadata()
        }, now: { clock })
        let link = URL(string: "https://untitled.example/")!
        _ = await cache.state(for: link)
        // The title-less metadata is archived off the main actor, and a second
        // look would read that archive before it fetched. Wait for it to land,
        // then empty the directory, so only the memo can keep fetches at 1.
        // The write is atomic (a temporary sibling, then a rename), so wait for
        // the final .metadata file, not just any entry.
        for _ in 0..<100 where !entries(in: directory).contains(where: { $0.hasSuffix(".metadata") }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(entries(in: directory).contains { $0.hasSuffix(".metadata") }, "the archive never landed")
        try? FileManager.default.removeItem(at: directory)
        clock.addTimeInterval(LinkFailureMemo.retryInterval * 10)
        _ = await cache.state(for: link)
        XCTAssertEqual(fetches, 1)
    }

    @MainActor
    func testDeadLinkIsFetchedOncePerSession() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var fetches = 0
        let cache = LinkPreviewCache(diskDirectory: directory) { _ in
            fetches += 1
            return nil
        }
        let dead = URL(string: "https://dead.example/page")!
        for _ in 0..<5 {
            let state = await cache.state(for: dead)
            guard case .unavailable = state else { return XCTFail("expected unavailable") }
        }
        XCTAssertEqual(fetches, 1)
        XCTAssertNil(cache.cachedPreview(for: dead))

        // Flooding the memory cache past its count limit must not forget it.
        for index in 0..<200 {
            _ = await cache.state(for: URL(string: "https://dead.example/\(index)")!)
        }
        _ = await cache.state(for: dead)
        XCTAssertEqual(fetches, 201)
    }

    @MainActor
    func testResolvedPreviewIsSynchronouslyAvailableAndReadsBackFromDisk() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = URL(string: "https://good.example/post")!
        var fetches = 0
        let first = LinkPreviewCache(diskDirectory: directory) { _ in
            fetches += 1
            let metadata = LPLinkMetadata()
            metadata.title = "A post"
            return metadata
        }
        XCTAssertNil(first.cachedPreview(for: link))
        _ = await first.state(for: link)
        XCTAssertEqual(first.cachedPreview(for: link)?.title, "A post")
        XCTAssertEqual(first.cachedPreview(for: link)?.host, "good.example")

        // The archive is written off the main actor; wait for it to land.
        for _ in 0..<100 where entries(in: directory).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(entries(in: directory).count, 1)

        let second = LinkPreviewCache(diskDirectory: directory) { _ in
            fetches += 1
            return nil
        }
        XCTAssertNil(second.cachedPreview(for: link))
        let state = await second.state(for: link)
        guard case .loaded(let preview) = state else { return XCTFail("expected the archived preview") }
        XCTAssertEqual(preview.title, "A post")
        XCTAssertEqual(fetches, 1)
    }

    // MARK: markdown

    func testMarkdownParsesOncePerTextAndKeepsItsBlocks() {
        let text = "# Title \(UUID().uuidString)\n\n- one\n- two\n\nBody paragraph.\n"
        let before = MarkdownBlocks.parseCount
        let first = MarkdownBlocks.parse(text)
        let second = MarkdownBlocks.parse(text)
        XCTAssertEqual(MarkdownBlocks.parseCount, before + 1)
        XCTAssertEqual(first.map(\.kind), second.map(\.kind))
        XCTAssertEqual(first.first?.kind, .heading(1))
        XCTAssertEqual(first.dropFirst().first?.kind, .listItem(marker: "•", indent: 0))
        XCTAssertEqual(first.last?.kind, .paragraph)
        XCTAssertNotNil(MarkdownBlocks.cached(text))
    }

    // MARK: fixtures

    private func fixture(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func write(_ data: Data, id: String, root: URL) throws -> Attachment {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("test.png"))
        return Attachment(id: id, fileName: "test.png", contentType: "image/png", byteSize: data.count, width: nil, height: nil)
    }
}
