import AppKit
import QuickLookUI
import SwiftUI

// Pressing an attachment opens it INSIDE HQ. The system
// Quick Look panel floated over the window wearing another app's chrome
// ("Open with TextEdit") and typed an extension-less image as a document.
// Photos get a real viewer on the fixed dark stage — fit to the sheet, pinch
// or double-click to zoom, arrows to walk the rest of the message's photos —
// and everything else is drawn by Quick Look's own view, embedded here.

/// What a click asks for: the attachment, plus the set it can be walked
/// through (the message's other images), collapsed to just itself otherwise.
struct AttachmentPreviewRequest: Identifiable, Hashable {
    let attachments: [Attachment]
    let start: Int

    var id: String { attachments[start].id }

    init(_ attachment: Attachment, siblings: [Attachment] = []) {
        let set = siblings.contains(attachment) ? siblings : [attachment]
        attachments = set
        start = set.firstIndex(of: attachment) ?? 0
    }
}

struct AttachmentPreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: AttachmentPreviewRequest

    @State private var index: Int
    // Zoom and pan are expressed in the unscaled photo viewport.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var fileURL: URL?
    @State private var decodedPhoto: NSImage?
    @State private var hasLoadFailed = false
    @State private var retryCount = 0

    private static let headerHeight: CGFloat = 56
    private static let maxZoom: CGFloat = 6

    init(request: AttachmentPreviewRequest) {
        self.request = request
        _index = State(initialValue: request.start)
    }

    private var attachment: Attachment { request.attachments[index] }

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            Rectangle()
                .fill(Tokens.Palette.borderLight)
                .frame(height: 1)
            stage
        }
        .background(Tokens.Palette.surface)
        .frame(
            minWidth: 520, idealWidth: idealSize.width,
            minHeight: 400, idealHeight: idealSize.height
        )
        .task(id: "\(attachment.id)|\(retryCount)") {
            hasLoadFailed = false
            fileURL = nil
            decodedPhoto = nil
            let target = attachment
            if target.isImage {
                let image = await AttachmentCache.shared.original(for: target, client: store.client)
                guard !Task.isCancelled else { return }
                decodedPhoto = image
                hasLoadFailed = image == nil
                return
            }
            let url: URL
            do {
                url = try await AttachmentFileCache.shared.materialize(target, client: store.client)
                try Task.checkCancellation()
            } catch {
                guard !Task.isCancelled else { return }
                hasLoadFailed = true
                return
            }
            fileURL = url
            // A file typed as a document can still be a photo — anything
            // attached before the bytes had the last word on its type arrived
            // as an extension-less octet-stream. The viewer trusts what
            // decodes over what the type claims.
            if let cgImage = await ImageDecoder.shared.original(at: url), !Task.isCancelled {
                decodedPhoto = DecodedImage(cgImage).image
            }
        }
        .onDisappear { decodedPhoto = nil }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName)
                    .font(Tokens.Typography.rowEmphasis)
                    .foregroundStyle(Tokens.Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            Spacer(minLength: Tokens.Space.x4)
            if zoom > 1 || offset != .zero {
                Button("Fit") { resetZoom() }
                    .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
            }
            Button("Save…") {
                AttachmentCache.shared.save(attachment, client: store.client)
            }
            .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
            Button("Done") { dismiss() }
                .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .frame(height: Self.headerHeight)
    }

    private var subtitle: String {
        let size = attachment.sizeLabel
        guard request.attachments.count > 1 else { return size }
        return "\(size) · \(index + 1) of \(request.attachments.count)"
    }

    private var stage: some View {
        ZStack {
            Tokens.Palette.stage
            if let decodedPhoto {
                photoStage(decodedPhoto)
            } else if let fileURL, !attachment.isImage {
                QuickLookView(url: fileURL)
            } else if hasLoadFailed {
                VStack(spacing: 12) {
                    Text("Couldn't load this attachment")
                        .foregroundStyle(Tokens.Palette.stageInk)
                    Button("Try Again") { retryCount += 1 }
                        .buttonStyle(QuietCapsuleButtonStyle())
                }
                .padding(32)
            } else {
                ProgressView().controlSize(.small).tint(Tokens.Palette.stageInk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The zoomed image is clipped by the stage, never by the sheet.
        .contentShape(Rectangle())
        .clipped()
        .overlay(alignment: .leading) { stepButton(by: -1) }
        .overlay(alignment: .trailing) { stepButton(by: 1) }
    }

    @ViewBuilder
    private func photoStage(_ loaded: NSImage?) -> some View {
        if let image = loaded {
            GeometryReader { geometry in
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom)
                    .offset(
                        x: offset.width + drag.width,
                        y: offset.height + drag.height
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    // Clipping only affects drawing. Keep hit testing and all
                    // gestures on the unscaled viewport so Done stays reachable.
                    .contentShape(Rectangle())
                    .clipped()
                    .simultaneousGesture(panGesture)
                    .onTapGesture(count: 2) { location in
                        withAnimation(.snappy(duration: Tokens.Motion.base)) {
                            zoomPhoto(to: zoom > 1 ? 1 : 2.5, at: CGPoint(
                                x: location.x - geometry.size.width / 2,
                                y: location.y - geometry.size.height / 2
                            ))
                        }
                    }
                    .background(PhotoScrollEvents(
                        isEnabled: zoom > 1,
                        onScroll: { delta in
                            offset.width += delta.width
                            offset.height += delta.height
                        },
                        onMagnify: { magnification, pointer in
                            zoomPhoto(to: zoom * (1 + magnification), at: pointer)
                        }
                    ))
            }
        } else {
            ProgressView().controlSize(.small).tint(Tokens.Palette.stageInk)
        }
    }

    private func zoomPhoto(to proposedZoom: CGFloat, at pointer: CGPoint) {
        let nextZoom = min(max(proposedZoom, 1), Self.maxZoom)
        offset = PhotoZoomAnchor.offset(offset, from: zoom, to: nextZoom, at: pointer)
        zoom = nextZoom
    }

    // Panning only means something once the image outgrows the stage.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard zoom > 1 else { return }
                offset = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
                drag = .zero
            }
    }

    @ViewBuilder
    private func stepButton(by step: Int) -> some View {
        if request.attachments.count > 1 {
            Button {
                move(by: step)
            } label: {
                Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.stageInk)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(step < 0 ? .leftArrow : .rightArrow, modifiers: [])
            .padding(Tokens.Space.x3)
        }
    }

    private func move(by step: Int) {
        let count = request.attachments.count
        index = (index + step + count) % count
        resetZoom()
    }

    private func resetZoom() {
        zoom = 1
        offset = .zero
        drag = .zero
    }

    // The sheet opens at the photo's own shape, bounded by a comfortable
    // window; the pixel size rides on the wire, so this needs no bytes.
    private var idealSize: CGSize {
        let bounds = CGSize(width: 1000, height: 720 - Self.headerHeight)
        guard let width = attachment.width, let height = attachment.height,
              width > 0, height > 0
        else { return CGSize(width: 780, height: 620) }
        let scale = min(
            bounds.width / CGFloat(width), bounds.height / CGFloat(height), 1
        )
        return CGSize(
            width: max(CGFloat(width) * scale, 520),
            height: max(CGFloat(height) * scale, 380) + Self.headerHeight
        )
    }
}

// Quick Look's renderer as a plain subview — the same page it draws in the
// floating panel, without the panel.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }
}
