import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AttachmentThumbnailCache {
    static let shared = AttachmentThumbnailCache()
    private let thumbnails = MemoryBudgetCache<DecodedImage>(byteLimit: 16 * 1024 * 1024)
    private let loads = SharedLoads<DecodedImage?>()
    /// A room full of file cards must not put dozens of requests in front of
    /// Quick Look's XPC service at once.
    private let generation = AsyncLimiter(limit: 4)

    func thumbnail(for attachment: Attachment, client: HQClient?) async -> NSImage? {
        if let cached = thumbnails.value(for: attachment.id) { return cached.image }
        guard attachment.byteSize <= 20 * 1024 * 1024 else { return nil }
        let decoded = try? await loads.load(attachment.id) { entry in
            Task {
                let url = try await AttachmentFileCache.shared
                    .materialize(attachment, client: client, priority: .background)
                try await self.generation.acquire(ticket: entry.ticket)
                defer { self.generation.release() }
                try Task.checkCancellation()
                let request = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 200, height: 267),
                    scale: NSScreen.main?.backingScaleFactor ?? 2,
                    representationTypes: .thumbnail
                )
                guard let representation = try? await QLThumbnailGenerator.shared
                    .generateBestRepresentation(for: request) else { return nil }
                let decoded = DecodedImage(representation.cgImage)
                self.thumbnails.insert(decoded, for: attachment.id, cost: decoded.cost)
                return decoded
            }
        }
        return decoded?.image
    }

    /// The thumbnail already in memory, if any; starts no load.
    func cachedThumbnail(for attachment: Attachment) -> NSImage? {
        thumbnails.value(for: attachment.id)?.image
    }
}

// An image sends as a bubble-shaped thumbnail; anything else sends as a row
// with its name and size, the way Messages shows a document. A click opens
// the attachment in HQ's own preview (markdown keeps MarkdownPreview); Copy
// Image and Save live in the row's context menu; every bubble drags out as a
// file. `siblings` are the message's other images, so the viewer can walk
// them without closing.
struct AttachmentBubble: View {
    @Environment(AppStore.self) private var store
    let attachment: Attachment
    var isOwn = false
    var siblings: [Attachment] = []
    @State private var previewedMarkdown: Attachment?
    @State private var previewRequest: AttachmentPreviewRequest?
    @State private var didLoadThumbnail = false
    @State private var thumbnail: NSImage?

    /// The image to draw. One already in memory shows on the first frame:
    /// the `.task` resets `thumbnail` before it awaits, and without this a
    /// cached photo drew a spinner for a frame on every chat switch.
    private var shownThumbnail: NSImage? {
        if let thumbnail { return thumbnail }
        return attachment.isImage
            ? AttachmentCache.shared.cachedImage(for: attachment)
            : AttachmentThumbnailCache.shared.cachedThumbnail(for: attachment)
    }

    private var aspect: CGFloat {
        guard let width = attachment.width, let height = attachment.height, height > 0 else { return 4 / 3 }
        return CGFloat(width) / CGFloat(height)
    }

    var body: some View {
        Group {
            if attachment.isImage {
                imageBubble
            } else {
                fileRow
            }
        }
        .sheet(item: $previewRequest) { request in
            AttachmentPreviewSheet(request: request)
        }
        .task(id: attachment.id) {
            thumbnail = nil
            didLoadThumbnail = false
            let loaded = if attachment.isImage {
                await AttachmentCache.shared.image(for: attachment, client: store.client)
            } else {
                await AttachmentThumbnailCache.shared.thumbnail(for: attachment, client: store.client)
            }
            guard !Task.isCancelled else { return }
            thumbnail = loaded
            didLoadThumbnail = true
        }
        .onDrag { dragProvider() }
        // Finder only writes a dropped file from a real file URL — the lazy
        // item-provider bridge silently fizzles (verified live) — so the
        // bytes must be on disk BEFORE the drag starts. Hover is that window.
        .onHover { isHovering in
            guard isHovering, attachment.byteSize <= 20 * 1024 * 1024 else { return }
            AttachmentFileCache.shared.prefetch(attachment, client: store.client)
        }
    }

    private func preview() {
        previewRequest = AttachmentPreviewRequest(attachment, siblings: siblings)
    }

    // The file representation is the ONE shape Finder writes a file from
    // (verified live: an NSItemProvider(contentsOf:) drag silently fizzles) —
    // and only when the loadHandler answers within the drop's window. Hover
    // prefetch puts the bytes on disk so the handler can answer on the spot.
    private func dragProvider() -> NSItemProvider {
        AttachmentFileCache.shared.prefetch(attachment, client: store.client)
        let provider = NSItemProvider()
        // Receivers append the type's own extension to suggestedName; the
        // full fileName would land as "name.pdf.pdf".
        provider.suggestedName = (attachment.fileName as NSString).deletingPathExtension
        let client = store.client
        let attachment = attachment
        let type = UTType(filenameExtension: (attachment.fileName as NSString).pathExtension)
            ?? UTType(mimeType: attachment.contentType) ?? .data
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
        ) { completion in
            // Never complete synchronously inside this callback — the bridge
            // drops a completion that fires before it hands back the Progress.
            Task { @MainActor in
                do {
                    let url = try await AttachmentFileCache.shared
                        .materialize(attachment, client: client)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private var imageBubble: some View {
        AttachmentImageLayout(aspect: aspect) {
            ZStack {
                if let image = shownThumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            if didLoadThumbnail { Image(systemName: "photo.badge.exclamationmark") }
                            else { ProgressView().controlSize(.small) }
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Bubble.radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Bubble.radius, style: .continuous))
        .onTapGesture { preview() }
        .accessibilityLabel(attachment.fileName)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Open image preview")
        .help(attachment.fileName)
    }

    private var fileRow: some View {
        Button {
            if attachment.isMarkdown { previewedMarkdown = attachment } else { preview() }
        } label: {
            AttachmentFileContent(attachment: attachment, thumbnail: shownThumbnail)
                .padding(Tokens.Space.x3)
                .frame(width: Tokens.Attachment.cardWidth)
                .hqGlassCard(interactive: true)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Glass.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open attachment preview")
        .sheet(item: $previewedMarkdown) { MarkdownPreviewSheet(attachment: $0) }
    }


}

// The row of pending uploads above the composer.
struct AttachmentDraftStrip: View {
    @Environment(AppStore.self) private var store
    let conversationId: String

    var body: some View {
        let drafts = store.drafts(in: conversationId)
        let error = store.attachmentErrors[conversationId]
        if !drafts.isEmpty || store.isUploading(in: conversationId) || error != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(drafts) { attachment in
                        AttachmentDraftItem(attachment: attachment) {
                            store.removeDraft(attachment, in: conversationId)
                        }
                    }
                    if store.isUploading(in: conversationId) {
                        ProgressView().controlSize(.small)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, Tokens.Glass.scrollInset)
                .hqGlassContainer()
                .padding(.leading, 14)
                .padding(.trailing, BottomStackMetrics.trailingGutter)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
