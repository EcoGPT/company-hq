import AppKit
import SwiftUI

// The message context menu, copied from the one Messages shows on a
// right-click: two tapback rows, then the verb list in Messages' order —
// Tapback Details / Reply / Attach Sticker | Edit | Forward / Copy |
// Delete | Show Times.
struct MessageMenu: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let isOwn: Bool
    @Binding var editing: Message?

    // Row one is the six classic tapbacks — the HA HA tapback is genuinely
    // text, in Messages too. Row two is Messages' frequent-emoji strip,
    // ending in the smiley that opens the full emoji palette.
    private static let classicTapbacks = ["🩷", "👍", "👎", "HA HA", "‼️", "❓"]
    private static let frequentTapbacks = ["😂", "🙏", "🤝", "😭", "❤️"]

    // Emoji render at tapback size; the HA HA glyph is genuinely bold text.
    private static func paletteIcon(for symbol: String) -> NSImage {
        let isTextGlyph = symbol.count > 2
        let attributes: [NSAttributedString.Key: Any] = isTextGlyph
            ? [
                .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                .foregroundColor: NSColor.labelColor,
            ]
            : [.font: NSFont.systemFont(ofSize: 16)]
        let size = (symbol as NSString).size(withAttributes: attributes)
        let image = NSImage(size: size, flipped: false) { rect in
            (symbol as NSString).draw(in: rect, withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    var body: some View {
        if !message.isDeleted && !message.isPending {
            // .palette is what lays a group out as a horizontal strip inside
            // a menu; the default style collapses it into a submenu row. The
            // strip tints text labels away as templates, so every tapback is
            // drawn into a full-color image first.
            ControlGroup {
                ForEach(Self.classicTapbacks, id: \.self) { emoji in
                    Button {
                        store.react(to: message, emoji: emoji)
                    } label: {
                        Image(nsImage: Self.paletteIcon(for: emoji))
                    }
                }
            }
            .controlGroupStyle(.palette)
            ControlGroup {
                ForEach(Self.frequentTapbacks, id: \.self) { emoji in
                    Button {
                        store.react(to: message, emoji: emoji)
                    } label: {
                        Image(nsImage: Self.paletteIcon(for: emoji))
                    }
                }
                Button {
                    store.emojiTapbackTarget = message
                } label: {
                    Image(systemName: "face.smiling")
                }
            }
            .controlGroupStyle(.palette)
            if !message.reactions.isEmpty {
                Button {
                    store.tapbackDetailsTarget = message
                } label: {
                    Label("Tapback Details…", systemImage: "plus.magnifyingglass")
                }
            }
            Button {
                store.replyTarget = message
            } label: {
                Label("Reply…", systemImage: "arrowshape.turn.up.left")
            }
            // No sticker packs here; the closest true-to-life gesture is
            // slapping any emoji on, so this rides the same palette flow.
            Button {
                store.emojiTapbackTarget = message
            } label: {
                Label("Attach Sticker…", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
            }
            if isOwn {
                Divider()
                Button {
                    editing = message
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            Divider()
            if !message.content.isEmpty {
                Button {
                    store.forwardTarget = message
                } label: {
                    Label("Forward…", systemImage: "arrowshape.turn.up.right")
                }
            }
            // Copy on an attachment message means the FILES — paste lands
            // the actual documents in Finder or Mail. The text keeps its own
            // item when the message carries both.
            Button {
                if message.attachments.isEmpty {
                    copyText()
                } else {
                    copyAttachmentFiles()
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if !message.attachments.isEmpty {
                if !message.content.isEmpty {
                    Button {
                        copyText()
                    } label: {
                        Label("Copy Text", systemImage: "text.quote")
                    }
                }
                attachmentItems
            }
            if isOwn {
                Divider()
                Button {
                    store.deleteTarget = message
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
        }
        Divider()
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                store.isShowingMessageTimes.toggle()
            }
        } label: {
            Label(store.isShowingMessageTimes ? "Hide Times" : "Show Times", systemImage: "clock")
        }
    }

    // A lone attachment gets the plain Messages verbs; several get named ones
    // so the right file is unambiguous.
    @ViewBuilder
    private var attachmentItems: some View {
        let images = message.attachments.filter(\.isImage)
        ForEach(images) { attachment in
            Button {
                copyImage(attachment)
            } label: {
                Label(
                    images.count == 1 ? "Copy Image" : "Copy \(attachment.fileName)",
                    systemImage: "photo.on.rectangle"
                )
            }
        }
        ForEach(message.attachments) { attachment in
            Button {
                AttachmentCache.shared.save(attachment, client: store.client)
            } label: {
                Label(
                    message.attachments.count == 1
                        ? "Save Attachment…" : "Save \(attachment.fileName)…",
                    systemImage: "square.and.arrow.down"
                )
            }
        }
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    private func copyAttachmentFiles() {
        guard let client = store.client else { return }
        let attachments = message.attachments
        Task {
            var urls: [NSURL] = []
            for attachment in attachments {
                if let url = try? await AttachmentFileCache.shared
                    .materialize(attachment, client: client) {
                    urls.append(url as NSURL)
                }
            }
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls)
        }
    }

    private func copyImage(_ attachment: Attachment) {
        guard let client = store.client else { return }
        Task {
            guard let data = try? await client.attachmentData(id: attachment.id),
                  let image = NSImage(data: data)
            else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }
}

// Clicking a tapback (or "Tapback Details…") shows Messages' who-reacted
// view: the chat dims behind a veil and every reactor floats above a
// restatement of the message — their tapback on a plate over their avatar.
// Read live from the store so it tracks changes while open; click anywhere
// to dismiss.
struct TapbackDetailsOverlay: View {
    @Environment(AppStore.self) private var store
    let message: Message

    private struct Reactor: Identifiable {
        let person: Person
        let emoji: String
        var id: String { "\(person.id)-\(emoji)" }
    }

    private var live: Message {
        store.messages(in: message.conversationId)
            .first { $0.id == message.id } ?? message
    }

    private var reactors: [Reactor] {
        live.reactions.flatMap { reaction in
            reaction.personIds.compactMap { personId in
                store.people[personId].map { Reactor(person: $0, emoji: reaction.emoji) }
            }
        }
    }

    private var isOwn: Bool { live.senderPersonId == store.me?.id }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture { store.tapbackDetailsTarget = nil }
            VStack(spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(reactors) { reactor in
                        reactorColumn(reactor)
                    }
                }
                restatedBubble
            }
            .padding(30)
            .allowsHitTesting(false)
        }
        .transition(.opacity)
    }

    private func reactorColumn(_ reactor: Reactor) -> some View {
        VStack(spacing: 8) {
            Text(reactor.emoji)
                .font(reactor.emoji.count > 2 ? .system(size: 15, weight: .heavy) : .system(size: 30))
                .frame(width: 64, height: 64)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Circle().fill(.regularMaterial).frame(width: 10, height: 10).offset(x: 2, y: 4)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            if reactor.person.kind == "bot" {
                BotAvatarView(name: reactor.person.name, size: 40)
            } else {
                AvatarView(name: reactor.person.name, size: 40)
            }
            Text(reactor.person.name.split(separator: " ").first.map(String.init) ?? reactor.person.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var restatedBubble: some View {
        if !live.content.isEmpty {
            Text(store.plainText(live.content))
                .font(.system(size: 13))
                .foregroundStyle(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isOwn ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .frame(maxWidth: 420)
        }
    }
}

// "Forward…" — pick a conversation, the text lands there as a new message.
struct ForwardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let message: Message

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forward To").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(12)
            Divider()
            List(store.visibleConversations) { conversation in
                Button {
                    store.forward(message, to: conversation.id)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        if store.isBotConversation(conversation) {
                            BotAvatarView(name: store.displayName(for: conversation), size: 28)
                        } else {
                            AvatarView(
                                name: store.displayName(for: conversation),
                                isGroup: conversation.kind == "group",
                                size: 28
                            )
                        }
                        Text(store.displayName(for: conversation))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(width: 300, height: 380)
    }
}

// An invisible field that holds first responder so the system emoji palette
// types into it — and, because the palette anchors to the focused field, the
// panel springs from wherever this field sits. Tapbacks take one emoji and
// close (`picksOnce`); the composer's smiley keeps the palette up and
// forwards every pick.
struct EmojiPaletteCatcher: NSViewRepresentable {
    var picksOnce = true
    let onPick: (String) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        // The window exists only after insertion; focus and the palette have
        // to wait for it.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            NSApp.orderFrontCharacterPalette(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(picksOnce: picksOnce, onPick: onPick, onEnd: onEnd)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let picksOnce: Bool
        let onPick: (String) -> Void
        let onEnd: () -> Void

        init(picksOnce: Bool, onPick: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
            self.picksOnce = picksOnce
            self.onPick = onPick
            self.onEnd = onEnd
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.currentEditor()?.string ?? field.stringValue
            guard !text.isEmpty else { return }
            // One clear: setting stringValue against a live field editor
            // would redo the clear through the cell path.
            if let editor = field.currentEditor() {
                editor.string = ""
            } else {
                field.stringValue = ""
            }
            if picksOnce {
                field.window?.makeFirstResponder(nil)
                if let emoji = text.first { onPick(String(emoji)) }
            } else {
                onPick(text)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onEnd()
        }
    }
}
