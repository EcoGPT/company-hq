import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The long-press menu, in Messages' own order: the two tapback strips — the
/// second ending in the smiley that opens the full palette — then Tapback
/// Details / Reply / Attach Sticker / Edit / Forward / Copy / the attachment
/// verbs / Select Text / Delete / Show Times. It is a sheet rather than a
/// `.contextMenu` because the tapback strips are the point — a context menu on
/// iOS cannot lay a row of reactions across the top the way Messages does.
struct MessageMenuSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let message: Message
    let isOwn: Bool
    @Binding var editing: Message?

    // Row one is the six classic tapbacks — the HA HA tapback is genuinely
    // text, in Messages too. Row two is Messages' frequent-emoji strip,
    // ending in the smiley that opens the full emoji palette.
    private static let classicTapbacks = ["🩷", "👍", "👎", "HA HA", "‼️", "❓"]
    private static let frequentTapbacks = ["😂", "🙏", "🤝", "😭", "❤️"]

    /// Sheets this menu raises over itself. Each keeps the menu up — a row
    /// that dismissed it would take its own sheet down with it.
    @State private var isEmojiTapbackOpen = false
    @State private var isSelectingText = false
    @State private var share: ShareRequest?

    private var isActionable: Bool { !message.isDeleted && !message.isPending }

    private var attachments: [Attachment] { message.attachments }
    private var images: [Attachment] { message.attachments.filter(\.isImage) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Tokens.Space.x4) {
                    if isActionable {
                        tapbackStrip(Self.classicTapbacks)
                        tapbackStrip(Self.frequentTapbacks, endsWithPalette: true)
                    }
                    VStack(spacing: 0) {
                        if isActionable {
                            actionRows
                            RowDivider()
                        }
                        row(
                            store.isShowingMessageTimes ? "Hide Times" : "Show Times",
                            "clock"
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                store.isShowingMessageTimes.toggle()
                            }
                        }
                    }
                    .hqCard()
                }
                .padding(Tokens.Space.x4)
            }
            .background(Tokens.Palette.surfaceSunken)
            .scrollContentBackground(.hidden)
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Any emoji as a tapback, the way the Mac hands the same job to the
        // system character palette. Picking one closes both the palette and
        // the menu, because a tapback is one decision.
        .sheet(isPresented: $isEmojiTapbackOpen) {
            EmojiPickerSheet(isSingleChoice: true) { emoji in
                store.react(to: message, emoji: emoji)
                isEmojiTapbackOpen = false
                dismiss()
            }
        }
        .sheet(isPresented: $isSelectingText) {
            MessageTextSheet(message: message)
        }
        .sheet(item: $share) { request in
            ShareSheet(items: request.items)
        }
    }

    @ViewBuilder
    private var actionRows: some View {
        if !message.reactions.isEmpty {
            row("Tapback Details…", "plus.magnifyingglass") {
                store.tapbackDetailsTarget = message
            }
            RowDivider()
        }
        row("Reply…", "arrowshape.turn.up.left") {
            store.replyTarget = message
        }
        // No sticker packs here; the closest true-to-life gesture is slapping
        // any emoji on, so this rides the same palette the smiley opens.
        RowDivider()
        row(
            "Attach Sticker…", "rectangle.portrait.on.rectangle.portrait.angled",
            dismissesMenu: false
        ) {
            isEmojiTapbackOpen = true
        }
        if isOwn {
            RowDivider()
            row("Edit", "pencil") { editing = message }
        }
        // A photo-only message forwards, copies and saves like any other —
        // what travels is the attachments rather than a line of text.
        RowDivider()
        row("Forward…", "arrowshape.turn.up.right") {
            store.forwardTarget = message
        }
        RowDivider()
        row("Copy", "doc.on.doc") {
            if attachments.isEmpty {
                Platform.copyToClipboard(message.content)
            } else {
                copyAttachmentFiles()
            }
        }
        if !attachments.isEmpty {
            if !message.content.isEmpty {
                RowDivider()
                row("Copy Text", "text.quote") {
                    Platform.copyToClipboard(message.content)
                }
            }
            attachmentRows
        }
        if !message.content.isEmpty {
            RowDivider()
            // The bubbles themselves are plain `Text` on purpose (the long
            // press belongs to this menu), so copying a fragment happens
            // here: the message restated in a sheet that selects.
            row("Select Text", "selection.pin.in.out", dismissesMenu: false) {
                isSelectingText = true
            }
        }
        if isOwn {
            RowDivider()
            row("Delete…", "trash", isDestructive: true) {
                store.deleteTarget = message
            }
        }
    }

    /// A lone attachment gets the plain Messages verbs; several get named ones
    /// so the right file is unambiguous. "Save…" is the share sheet, which is
    /// where Files, Photos and everything else live on a phone.
    @ViewBuilder
    private var attachmentRows: some View {
        ForEach(images) { image in
            RowDivider()
            row(images.count == 1 ? "Copy Image" : "Copy \(image.fileName)", "photo.on.rectangle") {
                copyImage(image)
            }
        }
        ForEach(attachments) { attachment in
            RowDivider()
            row(
                attachments.count == 1 ? "Save…" : "Save \(attachment.fileName)…",
                "square.and.arrow.down", dismissesMenu: false
            ) {
                startShare(attachment)
            }
        }
        if !images.isEmpty {
            RowDivider()
            row(
                images.count == 1 ? "Save to Photos" : "Save \(images.count) Photos",
                "photo.badge.arrow.down"
            ) {
                saveToPhotos()
            }
        }
    }

    private func tapbackStrip(_ emoji: [String], endsWithPalette: Bool = false) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 4)], spacing: 8) {
            ForEach(emoji, id: \.self) { symbol in
                Button {
                    // Same call the Mac makes, so a tapback already on the
                    // message toggles back off instead of doubling up.
                    store.react(to: message, emoji: symbol)
                    dismiss()
                } label: {
                    tapbackFace(
                        Text(symbol)
                            .font(
                                symbol.count > 2
                                    ? .system(size: 13, weight: .heavy) : .system(size: 26)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            if endsWithPalette {
                Button {
                    isEmojiTapbackOpen = true
                } label: {
                    tapbackFace(
                        Image(systemName: "face.smiling")
                            .font(.system(size: 22))
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More emoji")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tapbackFace(_ content: some View) -> some View {
        content
            .frame(width: 46, height: 46)
            .hqGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }

    private func row(
        _ title: String, _ symbol: String, isDestructive: Bool = false,
        dismissesMenu: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            if dismissesMenu { dismiss() }
        } label: {
            HStack(spacing: Tokens.Space.x3) {
                Text(title)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(isDestructive ? Tokens.Palette.danger : Tokens.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(
                        isDestructive ? Tokens.Palette.danger : Tokens.Palette.inkSecondary
                    )
            }
            .padding(.horizontal, Tokens.Space.x4)
            .frame(minHeight: Tokens.Layout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Attachment verbs

    /// Copy on an attachment message means the FILES: item providers over
    /// materialized bytes, so a paste in Files or Mail lands real documents
    /// rather than a string.
    private func copyAttachmentFiles() {
        guard let client = store.client else { return }
        let items = message.attachments
        Task {
            var providers: [NSItemProvider] = []
            for attachment in items {
                guard let url = try? await AttachmentFileCache.shared
                    .materialize(attachment, client: client),
                    let provider = NSItemProvider(contentsOf: url)
                else { continue }
                providers.append(provider)
            }
            guard !providers.isEmpty else { return }
            UIPasteboard.general.setItemProviders(
                providers, localOnly: false, expirationDate: nil
            )
        }
    }

    private func copyImage(_ attachment: Attachment) {
        guard let client = store.client else { return }
        Task {
            guard let data = try? await client.attachmentData(id: attachment.id),
                  let image = UIImage(data: data)
            else { return }
            UIPasteboard.general.image = image
        }
    }

    /// The Mac's Save panel; on a phone the same bytes leave through the share
    /// sheet, which is where "Save to Files" lives.
    private func startShare(_ attachment: Attachment) {
        guard let client = store.client else { return }
        Task {
            guard let url = try? await AttachmentFileCache.shared
                .materialize(attachment, client: client)
            else { return }
            share = ShareRequest([url])
        }
    }

    private func saveToPhotos() {
        guard let client = store.client else { return }
        let items = message.attachments.filter(\.isImage)
        Task {
            for attachment in items {
                guard let data = try? await client.attachmentData(id: attachment.id),
                      let image = UIImage(data: data)
                else { continue }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
        }
    }
}

/// "Select Text": the message restated in a sheet whose text selects, which is
/// how Messages lets a fragment be copied without the bubbles claiming the
/// long press for the system's selection menu.
struct MessageTextSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let message: Message

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(store.plainText(message.content))
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.x4)
            }
            .background(Tokens.Palette.surface)
            .scrollContentBackground(.hidden)
            .navigationTitle(message.senderName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy All") {
                        Platform.copyToClipboard(message.content)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "N Replies" opens the thread: the original and every loaded reply.
struct ThreadSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let original: Message

    private var replies: [Message] {
        store.messages(in: original.conversationId)
            .filter { $0.replyTo?.id == original.id && !$0.isDeleted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                    ThreadBubble(message: original, isOwn: original.senderPersonId == store.me?.id)
                    RowDivider(inset: 0)
                    ForEach(replies) { reply in
                        ThreadBubble(message: reply, isOwn: reply.senderPersonId == store.me?.id)
                    }
                }
                .padding(Tokens.Space.x4)
            }
            .background(Tokens.Palette.surface)
            .scrollContentBackground(.hidden)
            .navigationTitle(replies.count == 1 ? "1 Reply" : "\(replies.count) Replies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct ThreadBubble: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let isOwn: Bool

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
            Text(message.senderName)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            MessageBubble(message: message, isOwn: isOwn)
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }
}

/// Who reacted with what — the veil the Mac draws, as a sheet here.
struct TapbackDetailsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let message: Message

    var body: some View {
        NavigationStack {
            List {
                ForEach(message.reactions, id: \.emoji) { reaction in
                    Section {
                        ForEach(reaction.personIds, id: \.self) { personId in
                            HStack(spacing: Tokens.Space.x3) {
                                if let person = store.people[personId] {
                                    AvatarView(name: person.name, size: 32)
                                    Text(person.name).font(Tokens.Typography.row)
                                } else {
                                    Text("Someone").font(Tokens.Typography.row)
                                }
                                Spacer(minLength: 0)
                                Text(reaction.emoji)
                                    .font(reaction.emoji.count > 2
                                        ? .system(size: 11, weight: .heavy) : .system(size: 20))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tapbacks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Forward: the message sent into another thread as a fresh message — its
/// text, its attachments, or both.
struct ForwardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let message: Message

    var body: some View {
        NavigationStack {
            List(store.visibleConversations) { conversation in
                Button {
                    forward(to: conversation.id)
                    dismiss()
                } label: {
                    HStack(spacing: Tokens.Space.x3) {
                        ClusterAvatarView(conversation: conversation, size: 36)
                        Text(store.displayName(for: conversation))
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// Text alone is the store's own forward. Attachments cannot be: an
    /// upload belongs to the conversation it was made in, so the bytes are
    /// fetched and uploaded again into the target and the fresh ids ride the
    /// new message. It lands in the transcript the way anyone else's message
    /// does — the hub broadcasts it back to every device, this one included.
    private func forward(to conversationId: String) {
        guard !message.attachments.isEmpty else {
            store.forward(message, to: conversationId)
            return
        }
        guard let client = store.client else { return }
        let forwarded = message
        Task {
            var attachmentIds: [String] = []
            for attachment in forwarded.attachments {
                guard let data = try? await client.attachmentData(id: attachment.id),
                      let uploaded = try? await client.upload(
                          conversationId: conversationId,
                          data: data,
                          fileName: attachment.fileName,
                          contentType: attachment.contentType,
                          pixelSize: Self.pixelSize(of: attachment)
                      )
                else { continue }
                attachmentIds.append(uploaded.id)
            }
            guard !attachmentIds.isEmpty || !forwarded.content.isEmpty else { return }
            _ = try? await client.send(
                conversationId: conversationId,
                clientMsgId: UUID().uuidString.lowercased(),
                content: forwarded.content,
                replyToMessageId: nil,
                attachmentIds: attachmentIds
            )
        }
    }

    /// The wire already carries the pixel size; passing it on keeps the
    /// forwarded bubble the right shape before the photo arrives.
    private static func pixelSize(of attachment: Attachment) -> CGSize? {
        guard let width = attachment.width, let height = attachment.height else { return nil }
        return CGSize(width: width, height: height)
    }
}
