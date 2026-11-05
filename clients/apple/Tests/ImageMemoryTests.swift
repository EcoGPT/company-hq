import AppKit
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers
import XCTest

@testable import HQ

final class ImageMemoryTests: XCTestCase {
    private final class Object {}
    private final class WeakValue<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }

    @MainActor
    func testBudgetEvictsLeastRecentlyUsedAndReleasesObjects() {
        let cache = MemoryBudgetCache<Object>(byteLimit: 10, countLimit: 3)
        var first: Object? = Object()
        let released = WeakValue(first!)
        cache.insert(first!, for: "first", cost: 4)
        first = nil
        cache.insert(Object(), for: "second", cost: 4)
        XCTAssertNotNil(cache.value(for: "second"))
        cache.insert(Object(), for: "third", cost: 4)
        XCTAssertNil(released.value)
        XCTAssertNil(cache.value(for: "first"))
        XCTAssertNotNil(cache.value(for: "second"))
        XCTAssertEqual(cache.totalCost, 8)

        // Replacements release their prior cost, and oversize values never
        // enter the cache. Zero-cost metadata is still bounded by count.
        cache.insert(Object(), for: "second", cost: 2)
        XCTAssertEqual(cache.totalCost, 6)
        cache.insert(Object(), for: "huge", cost: 11)
        XCTAssertNil(cache.value(for: "huge"))
        for index in 0..<100 { cache.insert(Object(), for: "metadata-\(index)", cost: 0) }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.totalCost, 0)
    }

    @MainActor
    func testAttachmentDiskPathDownsamplesAndStaysBoundedAsImagesAccumulate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AttachmentFileCache(directory: root)
        let cache = AttachmentCache(files: files, byteLimit: 4 * 1024 * 1024)
        let data = try fixture(width: 2400, height: 1600)
        var weakImages: [WeakValue<NSImage>] = []
        for index in 0..<24 {
            let attachment = try write(data, id: "image-\(index)", root: root)
            let loaded = await cache.image(for: attachment, client: nil)
            let image = try XCTUnwrap(loaded)
            let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), ImageDecoder.thumbnailPixels)
            weakImages.append(WeakValue(image))
            XCTAssertLessThanOrEqual(cache.cachedImageBytes, 4 * 1024 * 1024)
        }
        XCTAssertLessThan(cache.cachedImageCount, 4)
        XCTAssertNil(weakImages.first?.value)
        XCTAssertLessThanOrEqual(weakImages.filter { $0.value != nil }.count, 3)

        // Evicted originals remain on disk and can be loaded again. Preview
        // keeps the original resolution without polluting the thumbnail cache.
        let first = try write(data, id: "image-0", root: root)
        let loadedThumbnail = await cache.image(for: first, client: nil)
        let thumbnail = try XCTUnwrap(loadedThumbnail)
        let loadedOriginal = await cache.original(for: first, client: nil)
        let original = try XCTUnwrap(loadedOriginal)
        let originalCG = try XCTUnwrap(original.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(originalCG.width, 2400)
        XCTAssertEqual(originalCG.height, 1600)
        let again = await cache.image(for: first, client: nil)
        XCTAssertTrue(thumbnail === again)
        XCTAssertEqual(try Data(contentsOf: files.materializedURL(for: first)!), data)
    }

    @MainActor
    func testConcurrentRequestsShareThumbnailAndPreviewIsNotRetained() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AttachmentCache(files: AttachmentFileCache(directory: root))
        let attachment = try write(fixture(width: 1800, height: 1200), id: "one", root: root)
        async let first = cache.image(for: attachment, client: nil)
        async let second = cache.image(for: attachment, client: nil)
        let pair = await (first, second)
        XCTAssertNotNil(pair.0)
        XCTAssertTrue(pair.0 === pair.1)
        XCTAssertEqual(cache.cachedImageCount, 1)

        var original = await cache.original(for: attachment, client: nil)
        let released = WeakValue(try XCTUnwrap(original))
        XCTAssertNotNil(released.value)
        original = nil
        XCTAssertNil(released.value)
    }

    func testDecoderHonorsOrientationAndRejectsNonImages() async throws {
        let data = try fixture(width: 2400, height: 1600, orientation: 6)
        let cgImage = await ImageDecoder.shared.thumbnail(data: data, maxPixels: 600)
        let image = try XCTUnwrap(cgImage)
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 600)
        let invalid = await ImageDecoder.shared.thumbnail(data: Data("not an image".utf8))
        XCTAssertNil(invalid)
    }

    @MainActor
    func testCancelledPreviewDoesNotReturnOrCacheAnOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AttachmentCache(files: AttachmentFileCache(directory: root))
        let attachment = try write(fixture(width: 1800, height: 1200), id: "one", root: root)
        let load = Task { await cache.original(for: attachment, client: nil) }
        load.cancel()
        let result = await load.value
        XCTAssertNil(result)
        XCTAssertEqual(cache.cachedImageCount, 0)
    }

    @MainActor
    func testLinkPreviewDecodesEncodedProviderDataAtThumbnailSize() async throws {
        let metadata = LPLinkMetadata()
        metadata.title = "Preview"
        let data = try fixture(width: 2400, height: 1600)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) {
            completion in
            completion(data, nil)
            return nil
        }
        metadata.imageProvider = provider
        let state = await LinkPreviewCache().built(from: metadata, url: URL(string: "https://example.com")!)
        guard case .loaded(let preview) = state else { return XCTFail("Expected a preview") }
        let image = try XCTUnwrap(preview.image)
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(bitmap.width, 900)
        XCTAssertEqual(bitmap.height, 600)
        XCTAssertEqual(preview.imageBytes, bitmap.bytesPerRow * bitmap.height)
    }

    private func fixture(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
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
