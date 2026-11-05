import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HQ

// The avatar cache must never refetch a failing picture in a loop (H9): the
// miss path asks for it again on every render, so the cache itself has to
// remember the failure.
@MainActor
final class AvatarCacheTests: XCTestCase {
    func testBackoffBlocksUntilRetryAfterThenReleases() {
        var backoff = AvatarFailureBackoff()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(backoff.isBlocked("a-1", at: start))
        backoff.record("a-1", at: start)
        XCTAssertTrue(backoff.isBlocked("a-1", at: start.addingTimeInterval(1)))
        XCTAssertTrue(backoff.isBlocked("a-1", at: start.addingTimeInterval(AvatarFailureBackoff.retryAfter - 1)))
        XCTAssertFalse(backoff.isBlocked("a-1", at: start.addingTimeInterval(AvatarFailureBackoff.retryAfter + 1)))
        XCTAssertFalse(backoff.isBlocked("b-2", at: start), "another avatar is unaffected")
    }

    func testBackoffClearsOnSessionChangeButNotOnTheFirstSession() {
        var backoff = AvatarFailureBackoff()
        let now = Date(timeIntervalSince1970: 1_000)
        backoff.observeSession("bearer-1")
        backoff.record("a-1", at: now)
        backoff.observeSession("bearer-1")
        XCTAssertTrue(backoff.isBlocked("a-1", at: now), "same session keeps its failures")
        backoff.observeSession("bearer-2")
        XCTAssertFalse(backoff.isBlocked("a-1", at: now), "a new session starts clean")
    }

    func testBackoffIgnoresAFailureFromAnEarlierSession() {
        var backoff = AvatarFailureBackoff()
        let now = Date(timeIntervalSince1970: 1_000)
        backoff.observeSession("bearer-1")
        backoff.observeSession("bearer-2")
        backoff.record("a-1", at: now, session: "bearer-1")
        XCTAssertFalse(backoff.isBlocked("a-1", at: now), "a late failure from the old session is dropped")
        backoff.record("a-1", at: now, session: "bearer-2")
        XCTAssertTrue(backoff.isBlocked("a-1", at: now))
    }

    /// Polls (yielding to the main actor) until `condition` holds, failing
    /// the test at the deadline. The hosted, coverage-instrumented run can be
    /// slow, so no fixed sleep decides anything.
    private func waitUntil(
        _ message: String, timeout: Duration = .seconds(5),
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("timed out: \(message)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFailingAvatarIsFetchedOnceNoMatterHowOftenItIsRendered() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-avatar-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = FetchCounter()
        var clock = Date(timeIntervalSince1970: 1_000)
        let cache = AvatarImageCache(
            directory: directory,
            fetch: { _, _, _, _ in
                counter.increment()
                throw APIError(status: 404, code: "not_found")
            },
            now: { clock }
        )
        let client = HQClient(bearer: "bearer-1")

        func render(_ c: HQClient) {
            XCTAssertNil(cache.image(
                kind: .people, ownerId: "p1", avatarId: "gone", client: c, size: 40))
        }
        /// A render the cache must not turn into a request: the in-flight
        /// mark is set synchronously, so a blocked render leaves it clear.
        func renderBlocked() {
            render(client)
            XCTAssertFalse(cache.isLoading, "a remembered failure starts no request")
        }
        /// A render that must start one request, then waits for it to end.
        func renderFetching(_ c: HQClient) async throws {
            render(c)
            XCTAssertTrue(cache.isLoading)
            try await waitUntil("the fetch finishes") { !cache.isLoading }
        }

        try await renderFetching(client)
        XCTAssertEqual(counter.value, 1)
        // Each pass is one more body run of a view whose avatar is missing.
        for _ in 0..<5 { renderBlocked() }
        XCTAssertEqual(counter.value, 1, "one request, then the failure is remembered")

        // Still inside the window.
        clock = clock.addingTimeInterval(AvatarFailureBackoff.retryAfter - 10)
        renderBlocked()
        XCTAssertEqual(counter.value, 1)

        // Past it: one more try.
        clock = clock.addingTimeInterval(20)
        try await renderFetching(client)
        XCTAssertEqual(counter.value, 2)

        // A new session forgets the failure at once.
        try await renderFetching(HQClient(bearer: "bearer-2"))
        XCTAssertEqual(counter.value, 3)
    }

    func testImageThatLandsBumpsVersionOnceAndIsServedFromMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-avatar-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Self.onePixelPNG())
        let counter = FetchCounter()
        let cache = AvatarImageCache(directory: directory, fetch: { _, _, _, _ in
            counter.increment()
            return png
        })
        let client = HQClient(bearer: "bearer-1")
        XCTAssertEqual(cache.version, 0)
        XCTAssertNil(
            cache.image(kind: .people, ownerId: "p1", avatarId: "a1", client: client, size: 40),
            "a cold miss never blocks on disk or network")
        try await waitUntil("the picture lands") { cache.version == 1 }
        XCTAssertEqual(cache.version, 1)
        XCTAssertNotNil(cache.image(kind: .people, ownerId: "p1", avatarId: "a1", client: client, size: 40))
        XCTAssertNotNil(cache.image(kind: .people, ownerId: "p1", avatarId: "a1", client: client, size: 28))
        XCTAssertEqual(cache.version, 1, "reading a picture never bumps the version")
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("p1-a1").path), "kept on disk for the next launch")
    }

    /// A fetch started under one bearer fails after the user re-enrols as
    /// another. The failure is dropped (it says nothing about the new
    /// session), and the view waiting on `version` must hear about it,
    /// otherwise it never asks again under the new session.
    func testDroppedStaleSessionFailureWakesWaitingViews() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-avatar-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Self.onePixelPNG())
        let gate = FetchGate()
        let cache = AvatarImageCache(directory: directory, fetch: { client, _, _, _ in
            if client.bearer == "bearer-A" {
                gate.markStarted()
                while !gate.released { try await Task.sleep(for: .milliseconds(5)) }
                throw APIError(status: 401, code: "unauthorized")
            }
            return png
        })
        func render(_ client: HQClient) -> PlatformImage? {
            cache.image(kind: .people, ownerId: "p1", avatarId: "a1", client: client, size: 40)
        }
        XCTAssertNil(render(HQClient(bearer: "bearer-A")))
        try await waitUntil("the fetch under A starts") { gate.started }
        // The user re-enrols; the render under B finds the key in flight.
        XCTAssertNil(render(HQClient(bearer: "bearer-B")))
        let before = cache.version
        gate.release()
        try await waitUntil("A's failure is dropped") { !cache.isLoading }
        XCTAssertGreaterThan(cache.version, before, "the waiting view is told to ask again")
        // That re-render fetches under B and lands.
        XCTAssertNil(render(HQClient(bearer: "bearer-B")))
        try await waitUntil("the picture lands under B") {
            render(HQClient(bearer: "bearer-B")) != nil
        }
    }

    /// A phone photo carries its rotation in EXIF. The Mac decode must apply
    /// it, as `NSImage(data:)` and the iOS path do.
    func testDecodeAppliesExifOrientation() throws {
        let jpeg = try XCTUnwrap(Self.jpeg(width: 200, height: 100, orientation: 6))
        let image = try XCTUnwrap(AvatarImageCache.decode(jpeg))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 100, "orientation 6 turns a 200x100 picture upright")
        XCTAssertEqual(cg.height, 200)
        XCTAssertEqual(image.size.width, 100)
        XCTAssertEqual(image.size.height, 200)
        let plain = try XCTUnwrap(AvatarImageCache.decode(
            try XCTUnwrap(Self.jpeg(width: 200, height: 100, orientation: 1))))
        XCTAssertEqual(plain.size.width, 200, "an upright picture is untouched")
        XCTAssertEqual(plain.size.height, 100)
    }

    private static func jpeg(width: Int, height: Int, orientation: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let cg = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, [
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private static func onePixelPNG() -> Data? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.representation(using: .png, properties: [:])
    }
}

private final class FetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isStarted = false
    private var isReleased = false
    func markStarted() { lock.lock(); isStarted = true; lock.unlock() }
    func release() { lock.lock(); isReleased = true; lock.unlock() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return isStarted }
    var released: Bool { lock.lock(); defer { lock.unlock() }; return isReleased }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
