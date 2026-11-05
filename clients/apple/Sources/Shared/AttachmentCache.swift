#if os(macOS)
import AppKit
#endif
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Original bytes stay on disk for preview, save and drag-out. Only decoded
// thumbnails enter the shared memory cache; the old unlimited dictionary of
// originals left a long-running Mac at 1 GB, mostly Image I/O pixel buffers.
@MainActor
final class AttachmentCache {
    static let shared = AttachmentCache()

    /// List-row thumbnails live apart from the transcript's 900 px budget: a
    /// Files page of images must not evict the open chat's photos. The number
    /// is the SHORT side's target: the rows fill a square (iPhone 40 pt at 3x
    /// is 120 px), so the short side is what has to cover the frame.
    nonisolated static let listThumbnailPixels = 128
    /// How far the long side may run past the target (an area cap, not an
    /// aspect cap): 16x is 2048 px at a 128 px short side, about 1 MB decoded,
    /// so a tall scrolling screenshot stays sharp and a panorama stays bounded.
    nonisolated static let listThumbnailStretch = 16

    /// The Image I/O `maxPixels` (it limits the LONG side) that leaves the
    /// short side at `target`: `ceil(target * long / short)`, never more than
    /// `target * listThumbnailStretch` and never more than the image itself, so
    /// a small image is not blown up. Only images past 16:1 are decoded with
    /// a short side under the target (and so upscaled to fill the square). Unknown dimensions fall back to `target`.
    nonisolated static func listThumbnailMaxPixels(target: Int, width: Int, height: Int) -> Int {
        guard target > 0 else { return 0 }
        let long = max(width, height), short = min(width, height)
        guard short > 0 else { return target }
        let wanted = (target * long + short - 1) / short
        return max(1, min(wanted, target * listThumbnailStretch, long))
    }

    /// Pixel size from the file's header (no decode), off the main actor.
    private nonisolated static func pixelSize(at url: URL) async -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private let images: MemoryBudgetCache<DecodedImage>
    private let smallImages: MemoryBudgetCache<DecodedImage>
    private let files: AttachmentFileCache
    private let loads = SharedLoads<DecodedImage?>()

    init(files: AttachmentFileCache? = nil, byteLimit: Int = 32 * 1024 * 1024,
         smallByteLimit: Int = 8 * 1024 * 1024) {
        self.files = files ?? .shared
        images = MemoryBudgetCache(byteLimit: byteLimit)
        smallImages = MemoryBudgetCache(byteLimit: smallByteLimit, countLimit: 256)
    }

    /// The transcript's photo bubbles. These are never held behind the
    /// download limiter: the newest, visible photos are the ones a person is
    /// looking at, and they must not queue behind older uncached attachments
    /// (file cards of up to 20 MB). Cancelling the caller's task abandons the
    /// load; the download itself stops only when nobody else is still waiting.
    func image(for attachment: Attachment, client: HQClient?) async -> PlatformImage? {
        if let cached = images.value(for: attachment.id) { return cached.image }
        guard attachment.isImage else { return nil }
        let decoded = try? await loads.load(attachment.id) { _ in
            Task {
                let url = try await self.files.materialize(attachment, client: client, priority: .interactive)
                guard let cgImage = await ImageDecoder.shared.thumbnail(at: url) else { return nil }
                try Task.checkCancellation()
                let decoded = DecodedImage(cgImage)
                self.images.insert(decoded, for: attachment.id, cost: decoded.cost)
                return decoded
            }
        }
        return decoded?.image
    }

    /// The transcript image already in memory, if any. Synchronous and starts
    /// no load: a bubble rebuilt by a chat switch draws it on its first frame
    /// instead of a spinner.
    func cachedImage(for attachment: Attachment) -> PlatformImage? {
        images.value(for: attachment.id)?.image
    }

    /// A small decode for list rows, sized by the short side: `maxPixels` is
    /// the target for the short side (see `listThumbnailMaxPixels`). Reuses
    /// the 900 px entry when the photo is already on screen elsewhere;
    /// otherwise decodes into the small budget instead of the transcript's.
    func thumbnail(
        for attachment: Attachment, maxPixels: Int = AttachmentCache.listThumbnailPixels,
        client: HQClient?
    ) async -> PlatformImage? {
        if let cached = images.value(for: attachment.id) { return cached.image }
        let key = "\(attachment.id)@\(maxPixels)"
        if let cached = smallImages.value(for: key) { return cached.image }
        guard attachment.isImage else { return nil }
        let decoded = try? await loads.load(key) { _ in
            Task {
                let url = try await self.files.materialize(attachment, client: client, priority: .background)
                var longSide = maxPixels
                if let size = await Self.pixelSize(at: url) {
                    longSide = Self.listThumbnailMaxPixels(target: maxPixels, width: size.width, height: size.height)
                }
                guard let cgImage = await ImageDecoder.shared.thumbnail(at: url, maxPixels: longSide) else {
                    return nil
                }
                try Task.checkCancellation()
                let decoded = DecodedImage(cgImage)
                self.smallImages.insert(decoded, for: key, cost: decoded.cost)
                return decoded
            }
        }
        return decoded?.image
    }

    /// The caller's .task owns the result and must discard it on cancellation.
    /// A cancelled download can still warm the disk cache, but must not decode.
    func original(for attachment: Attachment, client: HQClient?) async -> PlatformImage? {
        guard let url = try? await files.materialize(attachment, client: client),
              !Task.isCancelled,
              let image = await ImageDecoder.shared.original(at: url),
              !Task.isCancelled else { return nil }
        return DecodedImage(image).image
    }

    var cachedImageCount: Int { images.count }
    var cachedImageBytes: Int { images.totalCost }
    var cachedThumbnailCount: Int { smallImages.count }
    var cachedThumbnailBytes: Int { smallImages.totalCost }

    #if os(macOS)
    /// Save As…, which is a Mac idea. On a phone the same bytes leave through
    /// the share sheet instead, so there is nothing to mirror here.
    func save(_ attachment: Attachment, client: HQClient?) {
        guard let client else { return }
        Task {
            guard let data = try? await client.attachmentData(id: attachment.id) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.fileName
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
    #endif
}

extension HubFile {
    /// Library rows and transcript attachments reference the same disk file.
    var attachment: Attachment {
        Attachment(
            id: id, fileName: fileName, contentType: contentType,
            byteSize: byteSize, width: nil, height: nil
        )
    }
}

// Attachment bytes materialized as real files — Quick Look and drag-out both
// need a URL on disk. One file per attachment id, named for the original so
// the extension (and a Finder drop) keep their meaning.
//
// Every disk step runs off the main actor: a download streams to a temporary
// file and is moved into place by rename, so a kill mid-download never leaves
// a truncated file where `materializedURL` would call it complete.
@MainActor
final class AttachmentFileCache {
    static let shared = AttachmentFileCache()

    /// Who is asking. File-card downloads and list thumbnails queue behind a
    /// small limiter so a room full of file cards is not a download storm; a
    /// person opening a file, dragging it or hovering to prefetch is never
    /// made to wait, and neither is a transcript photo bubble.
    enum Priority { case interactive, background }

    private let loads = SharedLoads<URL>()
    private let limiter = AsyncLimiter(limit: 4)
    private var seeds: [String: Task<Void, Never>] = [:]

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(HQIdentity.bundleID)/attachment-files", isDirectory: true)
    }

    // The path is fully derivable, so the DISK is the whole cache state —
    // files materialized in an earlier run stay draggable after a relaunch.
    // Nonisolated: the drag loadHandler must answer off-main, synchronously.
    private nonisolated func fileURL(for attachment: Attachment) -> URL {
        var name = attachment.fileName.replacingOccurrences(of: "/", with: ":")
        if name.isEmpty { name = "attachment" }
        // A stored name that lost its extension (uploads before the header
        // was encoded degraded to "file") would materialize as a file Quick
        // Look cannot type — a video that never loads. The content type
        // still knows what the bytes are.
        if (name as NSString).pathExtension.isEmpty,
           let ext = UTType(mimeType: attachment.contentType)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        return directory
            .appendingPathComponent(attachment.id, isDirectory: true)
            .appendingPathComponent(name)
    }

    nonisolated func materializedURL(for attachment: Attachment) -> URL? {
        let url = fileURL(for: attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func prefetch(_ attachment: Attachment, client: HQClient?) {
        guard materializedURL(for: attachment) == nil else { return }
        Task { _ = try? await materialize(attachment, client: client) }
    }

    /// Puts bytes this device already holds (an upload it just made) where a
    /// later `materialize` finds them, so the sender never downloads its own
    /// file. The write is atomic and off the main actor; the returned task
    /// finishes when the file is in place, and `materialize` waits for it.
    @discardableResult
    func seed(_ attachment: Attachment, data: Data) -> Task<Void, Never> {
        if let pending = seeds[attachment.id] { return pending }
        let destination = fileURL(for: attachment)
        let id = attachment.id
        let task = Task { [weak self] in
            await Task.detached(priority: .utility) {
                try? Self.write(data, to: destination)
            }.value
            self?.seeds[id] = nil
        }
        seeds[id] = task
        return task
    }

    func materialize(
        _ attachment: Attachment, client: HQClient?, priority: Priority = .interactive
    ) async throws -> URL {
        if let known = materializedURL(for: attachment) { return known }
        if let pending = seeds[attachment.id] {
            await pending.value
            if let known = materializedURL(for: attachment) { return known }
        }
        try Task.checkCancellation()
        if let running = loads.running(attachment.id) {
            // A person asked for what a thumbnail queued: jump the line.
            if priority == .interactive { limiter.promote(running.ticket) }
        } else if client == nil {
            throw URLError(.userAuthenticationRequired)
        }
        let url = fileURL(for: attachment)
        return try await loads.load(attachment.id) { entry in
            Task {
                guard let client else { throw URLError(.userAuthenticationRequired) }
                if priority == .background { try await self.limiter.acquire(ticket: entry.ticket) }
                defer { if priority == .background { self.limiter.release() } }
                let temp = try await client.attachmentFile(id: attachment.id)
                do {
                    try await Task.detached(priority: .utility) {
                        try Self.install(temp, at: url)
                    }.value
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    throw error
                }
                return url
            }
        }
    }

    /// Moves a finished download next to its destination, then renames it into
    /// place. A rename is atomic, so the final name only ever points at a
    /// complete file; the loser of a race with another writer keeps theirs.
    nonisolated static func install(_ temp: URL, at destination: URL) throws {
        let manager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try? manager.removeItem(at: temp)
            return
        }
        let part = folder.appendingPathComponent(".\(UUID().uuidString).part")
        try manager.moveItem(at: temp, to: part)
        do {
            try manager.moveItem(at: part, to: destination)
        } catch {
            try? manager.removeItem(at: part)
            if manager.fileExists(atPath: destination.path) { return }
            throw error
        }
    }

    nonisolated static func write(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard !manager.fileExists(atPath: destination.path) else { return }
        try data.write(to: destination, options: .atomic)
    }
}

/// One load per key, shared by everyone who asks while it runs. Unlike a bare
/// `Task.value`, the callers are cancellable: a caller whose own task is
/// cancelled stops the shared work only when EVERY caller that joined it has
/// been cancelled, so a download another view still waits on keeps going.
@MainActor
final class SharedLoads<Value> {
    final class Entry {
        /// Names this load to an `AsyncLimiter` queue.
        let ticket = UUID()
        fileprivate var task: Task<Value, Error>?
        fileprivate var waiters = 0
        fileprivate var abandoned = 0
        fileprivate var isCancelled = false
    }

    private var entries: [String: Entry] = [:]

    func running(_ key: String) -> Entry? {
        guard let entry = entries[key], !entry.isCancelled else { return nil }
        return entry
    }

    func load(_ key: String, start: (Entry) -> Task<Value, Error>) async throws -> Value {
        let entry: Entry
        if let running = running(key) {
            entry = running
        } else {
            entry = Entry()
            entries[key] = entry
            entry.task = start(entry)
        }
        entry.waiters += 1
        defer { if entries[key] === entry { entries[key] = nil } }
        return try await withTaskCancellationHandler {
            try await entry.task!.value
        } onCancel: {
            Task { @MainActor in self.abandon(entry) }
        }
    }

    private func abandon(_ entry: Entry) {
        entry.abandoned += 1
        if entry.abandoned >= entry.waiters {
            entry.isCancelled = true
            entry.task?.cancel()
        }
    }
}

/// At most `limit` holders at a time; the rest wait and can be cancelled or
/// promoted while they wait. A freed slot goes to the NEWEST waiter: the
/// transcript mounts top to bottom while the reader sits at the bottom, so
/// the last request made is the one nearest what is on screen.
@MainActor
final class AsyncLimiter {
    private final class Waiter {
        let ticket: UUID
        let continuation: CheckedContinuation<Void, Error>
        init(ticket: UUID, continuation: CheckedContinuation<Void, Error>) {
            self.ticket = ticket
            self.continuation = continuation
        }
    }

    private let limit: Int
    private var running = 0
    private var queue: [Waiter] = []

    init(limit: Int) { self.limit = max(1, limit) }

    var holders: Int { running }
    var waiting: Int { queue.count }

    func acquire(ticket: UUID = UUID()) async throws {
        try Task.checkCancellation()
        if running < limit, queue.isEmpty {
            running += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.append(Waiter(ticket: ticket, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(ticket) }
        }
    }

    func release() {
        running = max(0, running - 1)
        while running < limit, !queue.isEmpty {
            running += 1
            queue.removeLast().continuation.resume()
        }
    }

    /// Lets a waiter start now, past the limit: someone is waiting on it.
    func promote(_ ticket: UUID) {
        guard let index = queue.firstIndex(where: { $0.ticket == ticket }) else { return }
        running += 1
        queue.remove(at: index).continuation.resume()
    }

    private func cancel(_ ticket: UUID) {
        guard let index = queue.firstIndex(where: { $0.ticket == ticket }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

// Little document previews: the square in a file row shows the page itself,
// rendered by Quick Look from the materialized file, with the doc icon as
// the until-then (and fallback) state.
