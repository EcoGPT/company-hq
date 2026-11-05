#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum AvatarKind: String {
    case people
    case conversations
}

/// Which avatars just failed to download, and until when. A stale avatarId
/// (404), a revoked bearer (401), bytes that do not decode, or no network all
/// land here, so a broken avatar costs one request per `retryAfter` instead of
/// one per render. A different bearer is a different session: its failures
/// say nothing about this one, so they are forgotten.
struct AvatarFailureBackoff {
    static let retryAfter: TimeInterval = 5 * 60

    private var until: [String: Date] = [:]
    private(set) var session: String?

    func isBlocked(_ key: String, at now: Date) -> Bool {
        guard let until = until[key] else { return false }
        return until > now
    }

    /// `session` is the bearer the failed fetch started under. If the backoff
    /// has moved to another session since (a re-enrolment while the request
    /// was out), the failure belongs to the old one and is dropped.
    /// Returns whether the failure was kept.
    @discardableResult
    mutating func record(_ key: String, at now: Date, session: String? = nil) -> Bool {
        if let session, self.session != session { return false }
        until[key] = now.addingTimeInterval(Self.retryAfter)
        return true
    }

    /// Call with the session's identity before every lookup; a change clears.
    mutating func observeSession(_ id: String) {
        guard session != id else { return }
        if session != nil { until.removeAll() }
        session = id
    }
}

// Avatar bytes are immutable per id — a change mints a new id server-side —
// so, like AttachmentFileCache, the disk file is the whole cache state:
// one file per {ownerId}-{avatarId}, no index, survives relaunch. Replacing
// an owner's picture sweeps their older files on the next fetch.
//
// `image(...)` runs inside view bodies, so it never writes anything a body
// reads. The three dictionaries are `@ObservationIgnored`; the one observed
// value is `version`, bumped only when a picture finishes loading, and read
// only on the miss path — so a hit never subscribes, and an arrival re-renders
// just the views that were still waiting. Disk reads, decodes and downloads
// all happen off the main thread: a cold miss returns nil and the arrival
// bumps `version`.
@MainActor
@Observable
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    typealias Fetch = @Sendable (HQClient, AvatarKind, String, String) async throws -> Data

    /// Observed. Bumped when a picture lands, never from `image(...)`.
    private(set) var version = 0

    @ObservationIgnored private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var fullImages: [String: PlatformImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var backoff = AvatarFailureBackoff()
    /// True while any picture is being read or downloaded. Not observed; the
    /// tests poll it instead of sleeping.
    var isLoading: Bool { !inFlight.isEmpty }
    private let directory: URL
    private let fetch: Fetch
    private let now: () -> Date

    init(
        directory: URL = AvatarImageCache.defaultDirectory,
        fetch: @escaping Fetch = { client, kind, ownerId, avatarId in
            try await client.avatarData(kind: kind, ownerId: ownerId, avatarId: avatarId)
        },
        now: @escaping () -> Date = Date.init
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.fetch = fetch
        self.now = now
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(HQIdentity.bundleID)/avatars", isDirectory: true)
    }

    /// Returns the picture pre-rendered at `size` points with the circle mask
    /// baked in. Menu labels (the Tasks person filter) flatten SwiftUI's
    /// resize and clip modifiers and draw an NSImage at its native size, so
    /// the image itself must already be the right shape.
    func image(
        kind: AvatarKind, ownerId: String, avatarId: String?, client: HQClient?, size: CGFloat
    ) -> PlatformImage? {
        guard let avatarId else { return nil }
        let key = "\(ownerId)-\(avatarId)"
        let thumbKey = "\(key)@\(Int(size))"
        if let cached = images[thumbKey] { return cached }
        if let full = fullImages[key] {
            let thumb = Self.circularThumbnail(full, side: size)
            images[thumbKey] = thumb
            return thumb
        }
        // A picture already on disk shows on the first frame, as it always
        // has: one small file read here beats a frame of initials at every
        // launch. Only a network fetch is waited for.
        if !inFlight.contains(key), !backoff.isBlocked(key, at: now()),
           let data = try? Data(contentsOf: directory.appendingPathComponent(key)),
           let full = Self.decode(data) {
            fullImages[key] = full
            let thumb = Self.circularThumbnail(full, side: size)
            images[thumbKey] = thumb
            return thumb
        }
        // A miss waits for an arrival: reading `version` is what re-renders
        // this body when one lands.
        _ = version
        load(key: key, kind: kind, ownerId: ownerId, avatarId: avatarId, client: client)
        return nil
    }

    private struct Decoded: @unchecked Sendable { let image: PlatformImage }

    private func load(key: String, kind: AvatarKind, ownerId: String, avatarId: String, client: HQClient?) {
        if let client { backoff.observeSession(client.bearer) }
        guard !inFlight.contains(key), !backoff.isBlocked(key, at: now()) else { return }
        inFlight.insert(key)
        let file = directory.appendingPathComponent(key)
        let directory = directory
        let fetch = fetch
        let startedUnder = client?.bearer
        Task {
            // The file first: its read and decode stay off the main thread.
            let stored = await Task.detached(priority: .userInitiated) { () -> Decoded? in
                guard let data = try? Data(contentsOf: file), let image = Self.decode(data)
                else { return nil }
                return Decoded(image: image)
            }.value
            if let stored {
                land(key, stored.image)
                return
            }
            guard let client else {
                inFlight.remove(key)
                return
            }
            let downloaded = await Task.detached(priority: .utility) { () -> Decoded? in
                guard
                    let data = try? await fetch(client, kind, ownerId, avatarId),
                    let image = Self.decode(data)
                else { return nil }
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                )) ?? []
                for stale in contents
                where stale.lastPathComponent.hasPrefix("\(ownerId)-")
                    && stale.lastPathComponent != key {
                    try? FileManager.default.removeItem(at: stale)
                }
                try? data.write(to: file)
                return Decoded(image: image)
            }.value
            if let downloaded {
                land(key, downloaded.image)
            } else {
                let kept = backoff.record(key, at: now(), session: startedUnder)
                inFlight.remove(key)
                // A failure from a session that has since changed is dropped,
                // so no backoff holds the key back. A view that found the key
                // in flight under the new session is waiting on `version`;
                // bump it so that view asks again.
                if !kept { version += 1 }
            }
        }
    }

    private func land(_ key: String, _ image: PlatformImage) {
        fullImages[key] = image
        inFlight.remove(key)
        version += 1
    }

    /// Bytes to a fully decoded picture, paid on the loading thread rather
    /// than the first draw. `NSImage(data:)` and `UIImage(data:)` both decode
    /// lazily, so the pixels are forced here: ImageIO with
    /// `ShouldCacheImmediately` on the Mac, `preparingForDisplay` on iOS.
    /// Orientation is applied on both.
    nonisolated static func decode(_ data: Data) -> PlatformImage? {
        #if os(macOS)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            // A thumbnail at full size is how ImageIO applies the EXIF
            // rotation (as `NSImage(data:)` does); no max size, so no scaling.
            let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        guard let image = PlatformImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
        #endif
    }

    #if os(macOS)
    // Resolution-independent: the drawing handler re-renders at whatever
    // backing scale the screen asks for, so an 18pt chip stays sharp.
    private static func circularThumbnail(_ image: PlatformImage, side: CGFloat) -> PlatformImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
    }
    #else
    // UIKit has no deferred drawing handler, so the renderer bakes the
    // device's own scale in — which is the same answer for a screen that
    // never changes underneath the app.
    private static func circularThumbnail(_ image: PlatformImage, side: CGFloat) -> PlatformImage {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: bounds.size).image { _ in
            UIBezierPath(ovalIn: bounds).addClip()
            image.draw(in: bounds)
        }
    }
    #endif
}

enum AvatarImagePrep {
    // Center-crop to a square and cap at 512px, re-encoded as JPEG — plenty
    // for the largest circle we draw at @2x, small enough that upload and
    // every teammate's fetch stay instant. Also strips whatever metadata the
    // original carried. CoreGraphics all the way through: the same pass has
    // to serve a Mac drop and a photo straight off the camera roll.
    static func prepare(_ data: Data) -> (data: Data, contentType: String)? {
        guard let cg = decodeOriented(data) else { return nil }
        let side = min(cg.width, cg.height)
        let crop = CGRect(
            x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side
        )
        let square = cg.cropping(to: crop) ?? cg
        let target = min(side, 512)
        guard let context = CGContext(
            data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, "image/jpeg")
    }

    /// A phone's photos carry their rotation in EXIF rather than in the
    /// pixels. Asking ImageIO for a transformed full-size "thumbnail" is what
    /// applies it — decoding the raw CGImage instead hands back a portrait
    /// selfie lying on its side.
    private static func decodeOriented(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}
