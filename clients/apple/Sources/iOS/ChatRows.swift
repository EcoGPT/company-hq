import SwiftUI

/// One message. The Mac opens its menu on a right-click anywhere on the row;
/// a phone has no right-click, so the whole row is a long-press target that
/// raises Messages' own two-part menu: the tapback strip, then the actions.
struct MessageRow: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let isOwn: Bool
    let shouldShowSender: Bool
    let shouldShowAvatar: Bool
    let isGroup: Bool
    let isLast: Bool
    var hasTail = true
    let replyCount: Int
    /// A jump landed here; the wash says which row.
    var isHighlighted = false
    /// `editing?.id` as a plain value, so the row can be compared without
    /// reading the binding.
    let editingID: String?
    @Binding var editing: Message?
    /// Go to the message this one quotes. The transcript owns the jump — it
    /// is the thing that can page history in and drive the scroller — so the
    /// row only names the target.
    var onOpenOriginal: ((String) -> Void)?

    @State private var isShowingEditHistory = false
    @State private var isMenuUp = false

    private var isBotSender: Bool {
        store.people[message.senderPersonId]?.kind == "bot"
    }

    private var readers: [Person] {
        guard isOwn, isLast, !message.isPending else { return [] }
        return store.readers(of: message)
    }

    var body: some View {
        // In groups every incoming row reserves the avatar gutter, so a run's
        // bubbles stay flush whether or not this row draws the avatar.
        HStack(alignment: .bottom, spacing: 6) {
            if !isOwn, isGroup || isBotSender {
                senderAvatar.opacity(shouldShowAvatar ? 1 : 0)
            }
            rowContent
        }
        // A jump — from a reply quote or a search hit — lands here; the wash
        // says which row it landed on.
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                .fill(Tokens.Palette.accent.opacity(isHighlighted ? 0.14 : 0))
                .padding(.horizontal, -6)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            isMenuUp = true
        }
        .sheet(isPresented: $isMenuUp) {
            MessageMenuSheet(message: message, isOwn: isOwn, editing: $editing)
                .environment(store)
                .presentationDetents([.height(360), .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var senderAvatar: some View {
        if isBotSender {
            BotAvatarView(name: message.senderName, size: Tokens.Bubble.avatar)
        } else {
            AvatarView(name: message.senderName, size: Tokens.Bubble.avatar)
        }
    }

    private var rowContent: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
            if shouldShowSender {
                HStack(spacing: 4) {
                    Text(message.senderName)
                    if message.isViaAgent { ViaClaudeChip() }
                }
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .padding(.leading, 12)
                .padding(.top, 6)
            } else if message.isViaAgent {
                ViaClaudeChip()
                    .padding(isOwn ? .trailing : .leading, 12)
                    .padding(.top, 6)
            }
            if let reply = message.replyTo {
                ReplyQuote(
                    reply: reply, names: store.mentionNames, isOwn: isOwn,
                    onOpenOriginal: onOpenOriginal.map { open in { open(reply.id) } }
                )
            }
            if isShowingEditHistory && editing?.id != message.id {
                ForEach(message.editRevisions, id: \.editedAt) { revision in
                    EditRevisionBubble(content: revision.content, isOwn: isOwn)
                }
            }
            if editing?.id == message.id && !message.isDeleted {
                InlineMessageEditor(message: message, editing: $editing)
            } else {
                MessageBubble(message: message, isOwn: isOwn, hasTail: hasTail)
                    // Headroom for the tapback balloon overlapping the top
                    // corner, so it never covers the row above.
                    .padding(.top, message.reactions.isEmpty ? 0 : 12)
                    .frame(maxWidth: Tokens.Bubble.maxWidth, alignment: isOwn ? .trailing : .leading)
                    .padding(isOwn ? .leading : .trailing, Tokens.Bubble.farGutter)
            }
            if store.isShowingMessageTimes && !message.isPending {
                Text(message.transcriptDate.formatted(date: .omitted, time: .shortened))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .padding(.horizontal, 12)
            }
            OutgoingMessageStatus(message: message)
            if replyCount > 0 && !message.isDeleted && editing?.id != message.id {
                repliesLink
            }
            if message.isEdited && !message.isDeleted && editing?.id != message.id {
                editedLine
            }
            if !readers.isEmpty {
                Text(readLine(for: readers))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
                    .padding(.trailing, 6)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    private var repliesLink: some View {
        Button { store.threadTarget = message } label: {
            Text(replyCount == 1 ? "1 Reply" : "\(replyCount) Replies")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.accent)
        }
        .buttonStyle(.plain)
        .padding(isOwn ? .trailing : .leading, 12)
        .padding(.top, 1)
    }

    /// "Edited" takes real layout space — as an overlay it used to hide under
    /// the next bubble — and tapping it unfolds the superseded versions.
    private var editedLine: some View {
        Button {
            withAnimation(.easeOut(duration: Tokens.Motion.base)) {
                isShowingEditHistory.toggle()
            }
        } label: {
            Text("Edited")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkTertiary)
        }
        .buttonStyle(.plain)
        .disabled(message.editRevisions.isEmpty)
        .padding(isOwn ? .trailing : .leading, 12)
    }

    private func readLine(for readers: [Person]) -> String {
        if isGroup {
            let names = readers.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
            return "Read by \(names.joined(separator: ", "))"
        }
        return "Read"
    }
}

/// Compared on the value inputs only. The closure and the binding are rebuilt
/// on every ChatView pass but behave the same for an unchanged message, so
/// they take no part; anything the row reads from the store inside its body
/// still invalidates it through observation.
extension MessageRow: Equatable {
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isOwn == rhs.isOwn
            && lhs.shouldShowSender == rhs.shouldShowSender
            && lhs.shouldShowAvatar == rhs.shouldShowAvatar
            && lhs.isGroup == rhs.isGroup
            && lhs.isLast == rhs.isLast
            && lhs.hasTail == rhs.hasTail
            && lhs.replyCount == rhs.replyCount
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.editingID == rhs.editingID
    }
}

struct MessageBubble: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let message: Message
    let isOwn: Bool
    var hasTail = true
    @State private var linkPreview: LinkPreviewCache.State = .loading
    @AppStorage(LinkPreviewSetting.key) private var showsLinkPreviews = true

    private var imageAttachments: [Attachment] { message.attachments.filter(\.isImage) }
    private var fileAttachments: [Attachment] { message.attachments.filter { !$0.isImage } }

    /// The link to preview: a message that is only a link, unless it is another person's and
    /// previews are off, so this device fetches nothing for it.
    private var previewURL: URL? {
        isOwn || showsLinkPreviews ? message.soleLinkURL : nil
    }

    /// The state to draw. A preview already in memory shows on the first
    /// frame: the bubble's `.task` resets `linkPreview` to `.loading` before it
    /// awaits, and without this a cached card would be built as a text bubble
    /// first and swapped a turn later (an extra layout pass and a flash on
    /// every chat switch).
    private var shownLinkPreview: LinkPreviewCache.State {
        if case .loading = linkPreview, let url = previewURL,
           let cached = LinkPreviewCache.shared.cachedPreview(for: url) {
            return .loaded(cached)
        }
        return linkPreview
    }

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            ForEach(imageAttachments) { attachment in
                AttachmentBubble(attachment: attachment, isOwn: isOwn, siblings: imageAttachments)
            }
            if !fileAttachments.isEmpty {
                VStack(alignment: isOwn ? .trailing : .leading, spacing: 6) {
                    ForEach(fileAttachments) { attachment in
                        AttachmentBubble(attachment: attachment, isOwn: isOwn)
                    }
                }
            }
            if !message.content.isEmpty || message.isDeleted {
                // A message that is nothing but a link renders as a preview
                // card once its metadata resolves; until then (and whenever
                // the page yields nothing usable) it stays a text bubble.
                if let url = previewURL,
                   case .loaded(let preview) = shownLinkPreview {
                    LinkPreviewCard(url: url, preview: preview)
                        .opacity(message.isPending ? 0.6 : 1)
                } else {
                    textBubble
                }
            }
        }
        .task(id: previewURL) {
            linkPreview = .loading
            guard let url = previewURL else { return }
            let loaded = await LinkPreviewCache.shared.state(for: url)
            guard !Task.isCancelled else { return }
            linkPreview = loaded
        }
        .overlay(alignment: isOwn ? .topLeading : .topTrailing) {
            if !message.reactions.isEmpty {
                TapbackPill(message: message, isOwn: isOwn)
                    .offset(x: isOwn ? -10 : 10, y: -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    private var rendered: ChatMarkdown.Rendered? {
        message.isDeleted ? nil : ChatMarkdown.render(message.content, names: store.mentionNames)
    }

    /// The wash behind code: white on the blue bubble, a faint black or white
    /// on the gray one by appearance (`ChatMarkdown.CodeStyle`).
    private var codeFill: Color {
        let fill = ChatMarkdown.CodeStyle.fill(isOwn: isOwn, isDark: colorScheme == .dark)
        return Color(white: fill.white, opacity: fill.opacity)
    }

    /// Code is drawn by a renderer; a message without any keeps SwiftUI's own
    /// text drawing untouched.
    @ViewBuilder
    private var bubbleTextView: some View {
        if let rendered {
            let accent = isOwn ? Color.white : Tokens.Palette.accent
            let text = rendered.text(linkColor: accent, mentionColor: accent)
            if rendered.hasCode {
                text.textRenderer(ChatMarkdown.CodeBackgroundRenderer(fill: codeFill))
            } else {
                text
            }
        } else {
            Text(AttributedString("Message unsent"))
        }
    }

    private var textBubble: some View {
        bubbleTextView
        .font(Tokens.Bubble.text)
        .italic(message.isDeleted)
        .foregroundStyle(bubbleForeground)
        // NOT `.textSelection(.enabled)`: on iOS that claims the long press
        // for the system's own selection menu, and the row's menu — the one
        // carrying the tapback strips — never opens. Messages does not make
        // bubbles free-select either; Copy lives in the menu.
        .padding(.horizontal, Tokens.Bubble.paddingHorizontal)
        .padding(.vertical, Tokens.Bubble.paddingVertical)
        .background(
            bubbleBackground,
            in: MessageBubbleShape(isOwn: isOwn, hasTail: hasTail && !message.isDeleted)
        )
        .opacity(message.isPending ? 0.6 : 1)
    }

    private var bubbleForeground: some ShapeStyle {
        if message.isDeleted { return AnyShapeStyle(Tokens.Palette.inkSecondary) }
        return isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(Tokens.Palette.ink)
    }

    private var bubbleBackground: some ShapeStyle {
        if message.isDeleted { return AnyShapeStyle(.quinary) }
        return isOwn
            ? AnyShapeStyle(Tokens.Palette.messageOutgoing)
            : AnyShapeStyle(Tokens.Palette.messageIncoming)
    }
}

/// The balloons hanging off a bubble's top corner; a tap opens who reacted.
struct TapbackPill: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let isOwn: Bool

    var body: some View {
        HStack(spacing: -6) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                TapbackBalloon(
                    reaction: reaction,
                    isMine: reaction.personIds.contains(store.me?.id ?? ""),
                    isTailLeading: isOwn
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.tapbackDetailsTarget = message }
    }
}

/// Editing happens on the bubble itself, the way Messages does it: an ✕ to
/// bail, the text in a fresh field, a filled ✓ to save.
struct InlineMessageEditor: View {
    @Environment(AppStore.self) private var store
    let message: Message
    @Binding var editing: Message?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.x2) {
            Button { editing = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            .buttonStyle(.plain)

            TextField("Message", text: $draft, axis: .vertical)
                .font(Tokens.Bubble.text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .padding(.horizontal, Tokens.Bubble.paddingHorizontal)
                .padding(.vertical, Tokens.Bubble.paddingVertical)
                .hqComposerGlass(in: RoundedRectangle(cornerRadius: 24), interactive: true)

            Button(action: save) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Tokens.Palette.accent)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.vertical, 2)
        .onAppear {
            draft = message.content
            isFocused = true
        }
    }

    private func save() {
        let text = draft
        editing = nil
        store.edit(message, content: text)
    }
}
