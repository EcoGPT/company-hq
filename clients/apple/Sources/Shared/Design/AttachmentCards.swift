import SwiftUI

/// Shared document identity for sent files and the per-conversation draft strip.
struct AttachmentFileContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let attachment: Attachment
    var thumbnail: PlatformImage?

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            if !dynamicTypeSize.isAccessibilitySize {
                Group {
                    if let thumbnail {
                        Image(platform: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(Tokens.Palette.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Tokens.Palette.accent.opacity(0.08))
                    }
                }
                .frame(width: Tokens.Attachment.iconSize, height: Tokens.Attachment.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumb))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.fileName)
                    .font(Tokens.Typography.rowEmphasis)
                    .foregroundStyle(Tokens.Palette.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .truncationMode(.middle)
                Text(attachment.sizeLabel)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if attachment.isImage { return "photo" }
        if attachment.isMarkdown { return "doc.text" }
        if attachment.contentType.hasPrefix("video/") { return "film" }
        if attachment.contentType.hasPrefix("audio/") { return "waveform" }
        if attachment.contentType == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}

struct AttachmentDraftItem: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppStore.self) private var store
    let attachment: Attachment
    let onRemove: () -> Void
    @State private var thumbnail: PlatformImage?

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x1) {
            AttachmentFileContent(attachment: attachment, thumbnail: thumbnail)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .hqMinimumControlTarget()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.fileName)")
        }
        .padding(Tokens.Space.x2)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? Tokens.Attachment.accessibleDraftWidth : Tokens.Attachment.draftWidth)
        .hqGlassCard()
        .task(id: attachment.id) {
            thumbnail = nil
            let loaded = await AttachmentCache.shared.image(for: attachment, client: store.client)
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
    }
}

/// Preserve image proportions while respecting the width offered by the transcript.
struct AttachmentImageLayout: Layout {
    let aspect: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ratio = max(aspect, 0.05)
        let width = max(0, min(proposal.width ?? Tokens.Attachment.imageMaxWidth,
                              Tokens.Attachment.imageMaxWidth, Tokens.Attachment.imageMaxHeight * ratio))
        return CGSize(width: width, height: width / ratio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
