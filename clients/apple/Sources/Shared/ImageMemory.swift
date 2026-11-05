import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A deterministic budget, measured in decoded bytes rather than file size.
/// NSCache's cost limit is advisory; this cache must evict before admitting a
/// new value. Visible views own their images separately, so an eviction does
/// not invalidate a view or trigger another decode.
@MainActor
final class MemoryBudgetCache<Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var lastUse: UInt64
    }

    let byteLimit: Int
    let countLimit: Int
    private(set) var totalCost = 0
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    var count: Int { entries.count }

    init(byteLimit: Int, countLimit: Int = 128) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }

    func value(for key: String) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    func insert(_ value: Value, for key: String, cost: Int) {
        if let previous = entries.removeValue(forKey: key) { totalCost -= previous.cost }
        let cost = max(0, cost)
        guard cost <= byteLimit, countLimit > 0 else { return }
        while entries.count >= countLimit || totalCost > byteLimit - cost {
            guard let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
                  let removed = entries.removeValue(forKey: victim) else { break }
            totalCost -= removed.cost
        }
        clock &+= 1
        entries[key] = Entry(value: value, cost: cost, lastUse: clock)
        totalCost += cost
    }
}

/// Only a decoded bitmap crosses into an NSImage/UIImage. In particular the
/// thumbnail must not retain an original-resolution Image I/O source.
struct DecodedImage {
    let image: PlatformImage
    let cost: Int

    init(_ cgImage: CGImage) {
        #if os(macOS)
        image = PlatformImage(cgImage: cgImage, size: .zero)
        #else
        image = PlatformImage(cgImage: cgImage)
        #endif
        cost = cgImage.bytesPerRow * cgImage.height
    }
}

/// Decode serially off the main actor: opening a transcript must not start a
/// full-size decode for every row at once. 900px covers a 300pt bubble @3x.
/// Thumbnails stay serial on purpose (bounded peak memory); the full-resolution
/// viewer decode runs on its own `FullImageDecoder` so it neither waits behind
/// queued thumbnails nor holds them up.
actor ImageDecoder {
    static let shared = ImageDecoder()
    static let thumbnailPixels = 900

    func thumbnail(at url: URL, maxPixels: Int = thumbnailPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return ImageDecoding.thumbnail(source: source, maxPixels: maxPixels)
    }

    func thumbnail(data: Data, maxPixels: Int = thumbnailPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return ImageDecoding.thumbnail(source: source, maxPixels: maxPixels)
    }

    /// Full resolution belongs to the open preview, never the shared cache.
    /// Forwards to the viewer's own actor, so callers keep this entry point.
    nonisolated func original(at url: URL) async -> CGImage? {
        await FullImageDecoder.shared.original(at: url)
    }
}

/// The open viewer's decode, apart from the thumbnails' queue.
actor FullImageDecoder {
    static let shared = FullImageDecoder()

    /// The transformed Image I/O decode also honors camera EXIF orientation.
    func original(at url: URL) -> CGImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let identifier = CGImageSourceGetType(source) as String?,
           UTType(identifier)?.conforms(to: .image) == true,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return ImageDecoding.thumbnail(source: source, maxPixels: max(width, height))
    }
}

enum ImageDecoding {
    static func thumbnail(source: CGImageSource, maxPixels: Int) -> CGImage? {
        guard maxPixels > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}
