import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import HQ

// A chat switch rebuilds every photo bubble with no image in its state, so a
// photo already decoded this session drew a spinner for a frame before its
// `.task` fetched it back from memory. The bubble now asks the memory cache
// synchronously; that lookup must never start a load of its own.
@MainActor
final class AttachmentFirstFrameTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("first-frame-\(UUID().uuidString)")
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func photo(_ id: String, size: Int = 10) -> Attachment {
        Attachment(id: id, fileName: "test.png", contentType: "image/png", byteSize: size, width: nil, height: nil)
    }

    func testCachedImageIsNilBeforeAnyLoadAndStartsNone() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AttachmentCache(files: AttachmentFileCache(directory: directory))

        XCTAssertNil(cache.cachedImage(for: photo("never-loaded")))
        try await Task.sleep(for: .milliseconds(200))
        let written = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(written, [])
        XCTAssertEqual(cache.cachedImageCount, 0)
    }

    func testCachedImageAnswersSynchronouslyAfterALoad() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AttachmentCache(files: AttachmentFileCache(directory: directory))
        let data = try png(width: 600, height: 400)
        let folder = directory.appendingPathComponent("seen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("test.png"))
        let item = photo("seen", size: data.count)

        let image = await cache.image(for: item, client: nil)
        let loaded = try XCTUnwrap(image)
        XCTAssertTrue(cache.cachedImage(for: item) === loaded)
    }

    func testCachedThumbnailIsNilBeforeAnyLoad() {
        let card = Attachment(
            id: "never-thumbnailed", fileName: "notes.pdf", contentType: "application/pdf",
            byteSize: 10, width: nil, height: nil
        )
        XCTAssertNil(AttachmentThumbnailCache().cachedThumbnail(for: card))
    }
}
