import QuickLook
import SwiftUI
import UIKit

/// An image sends as a bubble-shaped thumbnail; anything else sends as a card
/// with its name and size, the way Messages shows a document. A tap opens
/// HQ's own preview — photos zoom, `.md` keeps `MarkdownPreview`, the rest
/// draw in Quick Look — and never a system share sheet by surprise.
struct AttachmentBubble: View {
    @Environment(AppStore.self) private var store
    let attachment: Attachment
    var isOwn = false
    var siblings: [Attachment] = []
    @State private var previewRequest: AttachmentPreviewRequest?
    @State private var didLoadThumbnail = false
    @State private var thumbnail: PlatformImage?

    private var aspect: CGFloat {
        guard let width = attachment.width, let height = attachment.height, height > 0 else {
            return 4 / 3
        }
        return CGFloat(width) / CGFloat(height)
    }

    var body: some View {
        Group {
            if attachment.isImage {
                imageBubble
            } else {
                fileCard
            }
        }
        .task(id: attachment.id) {
            thumbnail = nil
            didLoadThumbnail = false
            let image = await AttachmentCache.shared.image(for: attachment, client: store.client)
            guard !Task.isCancelled else { return }
            thumbnail = image
            didLoadThumbnail = true
        }
        .fullScreenCover(item: $previewRequest) { request in
            AttachmentPreviewSheet(request: request).environment(store)
        }
    }

    private var imageBubble: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Bubble.radius, style: .continuous)
        return AttachmentImageLayout(aspect: aspect) {
            Group {
                if let image = thumbnail {
                    Image(platform: image)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fill)
                } else {
                    // The wire carries the pixel size, so the bubble is already
                    // the right shape before a byte of the photo arrives and the
                    // transcript never jumps when it lands.
                    Rectangle()
                        .fill(.quinary)
                        .aspectRatio(aspect, contentMode: .fill)
                        .overlay {
                            if didLoadThumbnail { Image(systemName: "photo.badge.exclamationmark") }
                            else { ProgressView() }
                        }
                }
            }
        }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { preview() }
        .accessibilityLabel(attachment.fileName)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Open image preview")
    }

    private var fileCard: some View {
        Button {
            preview()
        } label: {
            AttachmentFileContent(attachment: attachment)
                .padding(Tokens.Space.x3)
                .frame(maxWidth: Tokens.Attachment.cardWidth)
                .hqGlassCard(interactive: true)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Glass.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open attachment preview")

    }

    private func preview() {
        previewRequest = AttachmentPreviewRequest(attachment, siblings: siblings)
    }
}

/// What the preview was opened on, plus the message's other images so the
/// viewer can swipe between them without closing.
struct AttachmentPreviewRequest: Identifiable {
    let attachment: Attachment
    let siblings: [Attachment]

    var id: String { attachment.id }

    init(_ attachment: Attachment, siblings: [Attachment] = []) {
        self.attachment = attachment
        self.siblings = siblings.isEmpty ? [attachment] : siblings
    }
}

/// HQ's own preview, never the system's: photos page and zoom, markdown
/// renders, everything else goes through Quick Look. Sharing is an explicit
/// button, not an accident of tapping a bubble.
struct AttachmentPreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: AttachmentPreviewRequest
    @State private var selected: String
    @State private var fileURL: URL?
    @State private var isSharing = false
    @State private var didFail = false
    @State private var retryCount = 0

    init(request: AttachmentPreviewRequest) {
        self.request = request
        _selected = State(initialValue: request.attachment.id)
    }

    private var current: Attachment {
        request.siblings.first { $0.id == selected } ?? request.attachment
    }

    var body: some View {
        NavigationStack {
            Group {
                if current.isImage {
                    TabView(selection: $selected) {
                        ForEach(request.siblings) { attachment in
                            ZoomableImage(
                                attachment: attachment, isSelected: attachment.id == selected,
                                retryCount: retryCount, onRetry: { retryCount += 1 }
                            ).tag(attachment.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: request.siblings.count > 1 ? .automatic : .never))
                    .background(Tokens.Palette.stage)
                } else if current.isMarkdown {
                    MarkdownAttachmentView(attachment: current, retryCount: retryCount, onRetry: { retryCount += 1 })
                } else if let fileURL {
                    QuickLookView(url: fileURL).ignoresSafeArea(edges: .bottom)
                } else if didFail {
                    AttachmentLoadFailure { retryCount += 1 }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(current.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(fileURL == nil)
                }
            }
            .sheet(isPresented: $isSharing) {
                if let fileURL { ShareSheet(items: [fileURL]) }
            }
        }
        .preferredColorScheme(current.isImage ? .dark : nil)
        .task(id: "\(selected)-\(retryCount)") {
            fileURL = nil
            didFail = false
            let url = try? await AttachmentFileCache.shared.materialize(current, client: store.client)
            guard !Task.isCancelled else { return }
            fileURL = url
            didFail = url == nil
        }
    }
}

/// A photo that pinches and double-taps to zoom, the way Messages' viewer does.
private struct ZoomableImage: View {
    @Environment(AppStore.self) private var store
    let attachment: Attachment
    let isSelected: Bool
    let retryCount: Int
    let onRetry: () -> Void
    @State private var image: PlatformImage?
    @State private var didFail = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    PhotoZoomScrollView(image: image)
                } else if didFail {
                    AttachmentLoadFailure(retry: onRetry)
                        .environment(\.colorScheme, .dark)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .contentShape(Rectangle())
        .clipped()
        .background(Tokens.Palette.stage)
        .task(id: "\(isSelected)-\(retryCount)") {
            image = nil
            didFail = false
            guard isSelected else { return }
            let loaded = await AttachmentCache.shared.original(for: attachment, client: store.client)
            guard !Task.isCancelled else { return }
            image = loaded
            didFail = loaded == nil
        }
        .onDisappear { image = nil }
    }
}

private struct MarkdownAttachmentView: View {
    @Environment(AppStore.self) private var store
    let attachment: Attachment
    let retryCount: Int
    let onRetry: () -> Void
    @State private var text: String?
    @State private var didFail = false

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    MarkdownFileView(text: text)
                        .padding(Tokens.Space.x4)
                }
            } else if didFail {
                AttachmentLoadFailure(retry: onRetry)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.surface)
        .task(id: "\(attachment.id)-\(retryCount)") {
            text = nil
            didFail = false
            let data = try? await store.client?.attachmentData(id: attachment.id)
            guard !Task.isCancelled else { return }
            text = data.flatMap { String(data: $0, encoding: .utf8) }
            didFail = text == nil
        }
    }
}

private struct AttachmentLoadFailure: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't open attachment", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
        } description: {
            Text("Check your connection and try again.")
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(QuietCapsuleButtonStyle())
        }
    }
}

private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url as NSURL
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url as NSURL) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: NSURL

        init(url: NSURL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> QLPreviewItem {
            url
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The staged attachments under the composer, each removable before sending.
struct AttachmentDraftStrip: View {
    @Environment(AppStore.self) private var store
    let conversationId: String

    var body: some View {
        let drafts = store.drafts(in: conversationId)
        let error = store.attachmentErrors[conversationId]
        if !drafts.isEmpty || store.isUploading(in: conversationId) || error != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Space.x2) {
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
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.danger)
                    }
                }
                .padding(.vertical, Tokens.Glass.scrollInset)
                .hqGlassContainer()
                .padding(.horizontal, Tokens.Space.x4)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
        }
    }
}
