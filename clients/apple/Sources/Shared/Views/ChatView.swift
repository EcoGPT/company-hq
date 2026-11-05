import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The transcript scrolls the full width of the pane, so its scroller comes
// down the pane's right edge and the floating bottom stack sits over it. Every
// row of that stack ends clear of the lane instead of under the bar: wider
// than the 15pt an expanded AppKit scroller draws, narrow enough that the row
// still reads as centered. The transcript's own 14pt gutter is deliberately
// NOT this number — bubbles still pass under the scroller, and moving them is
// its own call.
enum BottomStackMetrics {
    static let trailingGutter: CGFloat = 18
}

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.toggleConversationDetails) private var toggleConversationDetails
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    let conversationId: String
    /// The meeting window hosts its own copy of this view; the flag keeps
    /// each composer's key monitor scoped to its own window's events.
    var isInMeetingPanel = false
    /// Hosted inside another surface's panel (a side panel): no
    /// window chrome — the host owns the toolbar — and no key monitor, so
    /// the host's own composer keeps its keystrokes.
    var isEmbeddedPanel = false
    @State private var editing: Message?
    @State private var isDropTargeted = false
    // The floating bottom stack's live height — the clearance spacer at the
    // transcript's very end, so the resting last bubble clears the field even
    // as reply bars or attachment drafts grow the stack. A spacer IN the
    // content, never `.contentMargins`: the margin joins the scroll geometry
    // a pass after the initial bottom anchor is computed, and `scrollTo`
    // ignores it — both measured, both land the chat a stack-height short.
    @State private var bottomStackHeight: CGFloat = 0
    // The row a jump from a reply quote landed on, flashed so the landing is
    // visible, then cleared.
    @State private var highlighted: String?
    // The transcript owns the text selection so a drag can cross bubbles; the
    // bubbles only draw what it says.
    @State private var selection = TranscriptSelection()
    // The bottom-pinning intent: true until the user scrolls away, reset by
    // every thread switch. Read when layout moves under the viewport.
    @State private var isPinnedToBottom = true
    // One physical scroll gesture can load one page. AppKit owns preserving
    // the live viewport while SwiftUI lays the prepended rows out above it.
    @State private var historyTrigger = TranscriptHistoryTrigger()
    @State private var viewportPreserver = TranscriptViewportPreserver()

    // Both read this conversation's own slot in the store: a message, an agent
    // step or a read receipt in any other chat does not re-run this body.
    private var messages: [Message] {
        TranscriptLayout.orderedMessages(store.messages(in: conversationId))
    }

    private var conversation: Conversation? {
        store.conversation(conversationId)
    }

    var body: some View {
        @Bindable var store = store
        // The composer floats: the transcript spans the
        // whole column and scrolls on under the bottom stack, dimmed by its
        // glass; the measured spacer at the content's end keeps the resting
        // bottom above the field. Not safeAreaInset — through
        // ScrollViewReader that SHRINKS the scroll view, parking the field on
        // an opaque band.
        ZStack(alignment: .bottom) {
            // The transcript waits for the bottom stack's first measurement:
            // anchoring the initial offset against a zero margin and gaining
            // the real one a pass later is exactly the relaunch that opens a
            // stack-height short of the bottom. One deferred frame, launch
            // only — conversation switches reuse the measured height.
            if bottomStackHeight > 0 {
                ScrollViewReader { proxy in
                    // Ordered once per pass, and read here rather than at the
                    // top of `body`: the reader's content is its own
                    // observation scope, so a change to this chat's messages
                    // re-runs the transcript, not the composer, header and
                    // drop catcher around it. `messages` filters the whole
                    // loaded transcript.
                    let ordered = messages
                    transcript(proxy, ordered: ordered)
                        // A conversation opens already at its bottom — anchored
                        // before first layout, never scrolled there after the
                        // fact. Later layout growth is handled from the measured
                        // pin intent below; a global size-change anchor would
                        // fight the native viewport preservation during prepends.
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .onScrollGeometryChange(for: TranscriptScrollProbe.self) { geometry in
                            TranscriptScrollProbe(geometry)
                        } action: { oldValue, newValue in
                            if historyTrigger.shouldLoad(at: newValue.offsetY) {
                                Task { @MainActor in
                                    await store.loadOlder(in: conversationId) {
                                        viewportPreserver.beginPrepend()
                                    }
                                    viewportPreserver.endPrependWhenLayoutSettles()
                                }
                            }
                            // Pinning is an intent, not a reading: only the user
                            // leaves the bottom, by scrolling — a pure offset
                            // change. Content growing under a pinned viewport
                            // (pages landing in a cold-opened thread, a link
                            // preview card, a typing line) re-asserts the bottom
                            // every time, so growths that race one another —
                            // and cancel any single corrective scroll — converge
                            // on the last one instead of parking the chat
                            // wherever the race left it.
                            if newValue.isAtBottom {
                                isPinnedToBottom = true
                            } else if !newValue.layoutDiffers(from: oldValue) {
                                isPinnedToBottom = false
                            } else if isPinnedToBottom {
                                // Instantly, never animated: an animation restarts
                                // from the stale offset on every growth and is
                                // cancelled by the next one — under a paging burst it
                                // never lands — and its in-between frames read as the
                                // user scrolling away. The anchors keep ordinary
                                // at-bottom growth seamless; this fires only once
                                // they have already failed.
                                Task { @MainActor in
                                    proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom)
                                }
                            }
                        }
                        .onScrollPhaseChange { oldPhase, newPhase in
                            historyTrigger.phaseChanged(from: oldPhase, to: newPhase)
                        }
                        .onChange(of: ordered.last?.id) { _, newValue in
                            guard newValue != nil, isPinnedToBottom else { return }
                            trimIfPinned()
                            // Deferred a turn: the new row — and any timestamp break
                            // inserted with it — must be laid out before the target
                            // is measured, or the slide lands short by the break's
                            // height and the message hides behind the composer.
                            // The target is the transcript's end, not the row, so
                            // typing lines under the new message stay in view.
                            Task { @MainActor in
                                // An incoming message must not interrupt someone reading history.
                                guard isPinnedToBottom else { return }
                                isPinnedToBottom = true
                                withAnimation(shouldReduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom)
                                }
                            }
                        }
                        // Back at the bottom after a scroll-back, and still
                        // there after a few seconds: the pages it loaded are
                        // out of sight. Scrolling up again sooner cancels it,
                        // so pages just read are not dropped and re-fetched.
                        .task(id: isPinnedToBottom) {
                            guard isPinnedToBottom,
                                  (try? await Task.sleep(for: .seconds(5))) != nil
                            else { return }
                            trimIfPinned()
                        }
                        .onChange(of: store.latestOutgoingMessageIDs[conversationId]) { _, id in
                            guard id != nil else { return }
                            isPinnedToBottom = true
                            Task { @MainActor in
                                proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom)
                            }
                        }
                        // Swapping conversations swaps this property, not the
                        // view; re-identify so the new chat gets a fresh scroll
                        // view (and the initial-offset anchor) instead of the old
                        // one's offset plus an animated catch-up scroll.
                        // A fresh thread starts pinned no matter where the
                    // last one ended.
                    .onChange(of: store.messageJump, initial: true) { _, target in
                        guard let target, target.conversationId == conversationId else { return }
                        store.messageJump = nil
                        reveal(target.messageId, proxy: proxy)
                    }
                    .onChange(of: conversationId) {
                        isPinnedToBottom = true
                        historyTrigger.reset()
                        viewportPreserver.reset()
                    }
                    .id(conversationId)
                    .overlay(alignment: .bottomTrailing) {
                        if !isPinnedToBottom {
                            Button {
                                isPinnedToBottom = true
                                withAnimation(shouldReduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom)
                                }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .hqGlass(in: Circle(), interactive: true)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Jump to latest message")
                            .accessibilityLabel("Jump to latest message")
                            .padding(.trailing, BottomStackMetrics.trailingGutter)
                            .padding(.bottom, bottomStackHeight + 8)
                        }
                    }
                }
            }
            bottomStack
        }
        .background(Tokens.Palette.surface)
        .background {
            FileDropCatcher(isTargeted: $isDropTargeted) { urls in
                store.attach(fileURLs: urls, in: conversationId)
            } onImageData: { data, fileName, contentType in
                store.attach(
                    imageData: data, fileName: fileName, contentType: contentType,
                    in: conversationId
                )
            }
        }
        .overlay {
            if isDropTargeted { DropTargetVeil() }
        }
        // Tapback details and reply threads present the way Messages presents
        // them: a veil over the chat, not a sheet.
        .overlay {
            if let target = store.tapbackDetailsTarget {
                TapbackDetailsOverlay(message: target)
            } else if let target = store.threadTarget {
                ThreadOverlay(original: target) { store.threadTarget = nil }
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.tapbackDetailsTarget)
        .animation(.easeOut(duration: 0.15), value: store.threadTarget)
        .sheet(item: $store.forwardTarget) { message in
            ForwardSheet(message: message)
        }
        .confirmationDialog(
            "This message will be deleted for everyone.",
            isPresented: isDeleteConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Delete for Everyone", role: .destructive) {
                if let target = store.deleteTarget { store.unsend(target) }
                store.deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { store.deleteTarget = nil }
        }
        .background {
            // Present only while a tapback pick is pending, so the hidden
            // field never holds focus otherwise.
            if store.emojiTapbackTarget != nil {
                EmojiPaletteCatcher { emoji in
                    if let target = store.emojiTapbackTarget {
                        store.react(to: target, emoji: emoji)
                    }
                    store.emojiTapbackTarget = nil
                } onEnd: {
                    store.emojiTapbackTarget = nil
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
        }
        // Standalone chat identity shares the sidebar header row. Embedded
        // chats leave their host surface's header alone.
        .modifier(
            ChatWindowChrome(
                isEmbedded: isEmbeddedPanel || isInMeetingPanel,
                title: conversation.map { store.displayName(for: $0) } ?? ""
            ) { headerButton }
        )
        // On screen, so no background trim drops rows from under it.
        .onAppear { store.transcriptAppeared(conversationId) }
        .onDisappear { store.transcriptDisappeared(conversationId) }
        .onChange(of: conversationId) { previous, current in
            store.transcriptDisappeared(previous)
            store.transcriptAppeared(current)
        }
    }

    /// Pinned to the newest message, the rows far above are out of sight:
    /// past the window plus a page, the store trims them a turn later.
    private func trimIfPinned() {
        store.trimPinnedTranscript(conversationId) { isPinnedToBottom }
    }

    // Native glass supplies contrast as the transcript passes beneath.
    private var bottomStack: some View {
        VStack(spacing: 0) {
            ReplyBar(conversationId: conversationId)
            AttachmentDraftStrip(conversationId: conversationId)
            ComposerView(
                conversationId: conversationId,
                isInMeetingPanel: isInMeetingPanel,
                ownsWindowKeyboard: !isEmbeddedPanel
            )
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            bottomStackHeight = newValue
        }
    }

    private var headerButton: some View {
        Button {
            toggleConversationDetails()
        } label: {
            VStack(spacing: 2) {
                if let conversation {
                    if store.isBotConversation(conversation) {
                        BotAvatarView(name: store.displayName(for: conversation), size: 36)
                    } else {
                        ClusterAvatarView(conversation: conversation, size: 36)
                    }
                }
                // The chevron hangs off the name as an overlay so only the
                // name participates in centering under the avatar.
                Text(pillTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    // Bound long group names while preserving a readable header.
                    .lineLimit(1)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .hqGlass(in: Capsule(), interactive: true)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .offset(x: 12, y: 1)
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pillTitle + (store.isDetailPanelOpen ? " — Close details" : " — Show details"))
        .accessibilityLabel(pillTitle)
        .accessibilityIdentifier("conversation-header")
    }

    // A plain VStack, deliberately: a 13s main-thread hang was traced to
    // LazyVStack's placement pass endlessly re-measuring the selectable
    // bubble text. Transcripts are paged, so eager layout is cheap; older
    // pages load on scroll-near-top via onScrollGeometryChange.
    private func transcript(_ proxy: ScrollViewProxy, ordered: [Message]) -> some View {
        ScrollView {
            transcriptStack(proxy, ordered: ordered)
        }
        // The spinner reads `isLoadingOlder` in a view of its own: that flag
        // flips twice per history page, and read here it re-ran this whole
        // body for each flip.
        .overlay(alignment: .top) {
            HistoryStatusOverlay(
                conversationId: conversationId,
                topInset: (isEmbeddedPanel || isInMeetingPanel) ? 8 : Tokens.Home.desktopHeaderHeight + 8
            ) {
                Task { @MainActor in
                    await store.loadOlder(in: conversationId) {
                        viewportPreserver.beginPrepend()
                    }
                    viewportPreserver.endPrependWhenLayoutSettles()
                }
            }
        }
        // A click anywhere in the transcript parks the caret, iMessage-style;
        // simultaneous so bubble links, tapbacks, and text selection keep
        // working. Typing anywhere still reclaims the field via the monitor.
        .simultaneousGesture(TapGesture().onEnded {
            guard editing == nil else { return }
            selection.clear()
            NSApp.keyWindow?.makeFirstResponder(nil)
        })
    }

    private func transcriptStack(_ proxy: ScrollViewProxy, ordered: [Message]) -> some View {
        // The room's facts read once per render, not once per row.
        let room = conversation
        let isGroup = room?.kind == "group"
        let isFeed = room.map { store.isFeedRoom($0) } ?? false
        let layout = makeLayout(for: room, messages: ordered)
        let editingID = editing?.id
        return VStack(spacing: 4) {
            TranscriptScrollViewResolver { scrollView in
                viewportPreserver.attach(to: scrollView)
            }
            .frame(height: 0)

            if !isEmbeddedPanel && !isInMeetingPanel {
                Color.clear.frame(height: Tokens.Home.desktopHeaderHeight)
            }
            VStack(spacing: 4) {
                // One layout snapshot for the whole render: the row
                // closures update on their own schedule, and re-reading the
                // store from them can see an array the trim already shrank —
                // indices from the enumeration then trap. The snapshot keeps
                // every row decision consistent with the rows themselves.
                let messages = layout.messages
                let replyCounts = layout.replyCounts
                let eventRuns = layout.eventRuns
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    if layout.shouldShowTimestamp(at: index) {
                        TimestampSeparator(date: message.transcriptDate)
                    }
                    if message.isWork {
                        WorkRow(message: message)
                    } else if let run = eventRuns.runs[message.id] {
                        GroupEventRun(messages: run, isFeed: isFeed)
                    } else if message.isSystem {
                        // The rest of a run renders inside the row above it.
                        if !eventRuns.absorbed.contains(message.id) {
                            GroupEventRow(message: message, isFeed: isFeed)
                        }
                    } else {
                        // Equatable on its value inputs (the closures behave
                        // the same for an unchanged message), so a pass that
                        // changed nothing about this row skips its body. The
                        // row still observes the store for what it reads.
                        MessageRow(
                            message: message,
                            isOwn: message.senderPersonId == store.me?.id,
                            shouldShowSender: layout.shouldShowSender(at: index),
                            shouldShowAvatar: layout.shouldShowAvatar(at: index),
                            isGroup: isGroup,
                            isLast: index == messages.count - 1,
                            replyCount: replyCounts[message.id] ?? 0,
                            isHighlighted: highlighted == message.id,
                            editingID: editingID,
                            editing: $editing,
                            selection: selection,
                            onShowReplies: { store.threadTarget = message },
                            onOpenOriginal: { reveal($0, proxy: proxy) }
                        )
                        .equatable()
                    }
                }
            }
            .padding(.horizontal, 14)
            // The typing dots and the activity shimmer are transcript rows,
            // not floating chrome: they push the conversation up the way a
            // message would instead of covering the last bubble. They sit
            // outside the gutter padding — each carries its own 14pt, the
            // same alignment they had in the floating stack.
            // The live work row already says what the bot is doing, in the
            // transcript; the shimmer line is for turns that write no row.
            if !(layout.messages.last(where: \.isWork)?.isWorking == true) {
                BotActivityLine(conversationId: conversationId, isGroup: isGroup)
            }
            TypingLine(conversationId: conversationId)
            // The clearance under the floating composer stack, inside the
            // content so every anchor and scroll target counts it.
            Color.clear.frame(height: bottomStackHeight)
        }
        .padding(.vertical, 10)
        // The whole-content anchor every scroll-to-bottom targets, so the
        // lines below the last row are included in "the bottom".
        .id(TranscriptAnchor.bottom)
    }

    // Both clients lay a transcript out by the same arithmetic — runs,
    // quiet-gap stamps, sender labels, avatars, collapsed event bursts —
    // so the rules live in `TranscriptLayout` and this view only asks.
    private func makeLayout(for room: Conversation?, messages: [Message]) -> TranscriptLayout {
        TranscriptLayout(
            messages: messages,
            myPersonId: store.me?.id,
            isGroup: room?.kind == "group",
            isBotDM: room.map { store.isBotConversation($0) } ?? false,
            isBot: { store.people[$0]?.kind == "bot" }
        )
    }


    // "Cy", "Planning", or "Cy +4" — titled threads keep their title,
    // untitled ones shorten to the first member's first name plus a count.
    private var pillTitle: String {
        guard let conversation else { return "" }
        if let title = conversation.title, !title.isEmpty { return title }
        let names = store.displayMembers(of: conversation).map(\.name)
        guard let first = names.first else { return store.displayName(for: conversation) }
        let firstName = first.split(separator: " ").first.map(String.init) ?? first
        return names.count > 1 ? "\(firstName) +\(names.count - 1)" : firstName
    }

    private var isDeleteConfirmPresented: Binding<Bool> {
        Binding(
            get: { store.deleteTarget != nil },
            set: { isPresented in
                if !isPresented { store.deleteTarget = nil }
            }
        )
    }

    // Pressing a reply's quote goes to the message it quotes, pulling older
    // pages if the original sits above what is loaded, and flashes the row it
    // lands on so the jump is legible.
    private func reveal(_ messageId: String, proxy: ScrollViewProxy) {
        Task { @MainActor in
            while !messages.contains(where: { $0.id == messageId }) {
                let oldest = store.messages(in: conversationId).first?.id
                await store.loadOlder(in: conversationId)
                // No new page — history ran out, or another load is already
                // in flight. Either way this press has nowhere to go.
                guard store.messages(in: conversationId).first?.id != oldest else { return }
            }
            // A cross-conversation search loads rows in the same update that
            // creates the new scroll view. Let that layout land, and cancel
            // its initial bottom pin, before asking the proxy for the row.
            await Task.yield()
            isPinnedToBottom = false
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(messageId, anchor: .center)
            }
            highlighted = messageId
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeOut(duration: 0.4)) {
                if highlighted == messageId { highlighted = nil }
            }
        }
    }

}

private struct MessageRow: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let isOwn: Bool
    let shouldShowSender: Bool
    let shouldShowAvatar: Bool
    let isGroup: Bool
    let isLast: Bool
    let replyCount: Int
    let isHighlighted: Bool
    /// `editing?.id` as a plain value, so the row can be compared without
    /// reading the binding.
    let editingID: String?
    @Binding var editing: Message?
    let selection: TranscriptSelection
    let onShowReplies: () -> Void
    let onOpenOriginal: (String) -> Void

    @State private var isShowingEditHistory = false

    private var readers: [Person] {
        guard isOwn, isLast, !message.isPending else { return [] }
        return store.readers(of: message)
    }

    var body: some View {
        // In groups every incoming row reserves the avatar gutter, so a run's
        // bubbles stay flush whether or not this row draws the avatar.
        HStack(alignment: .bottom, spacing: 6) {
            if !isOwn, isGroup || isBotSender {
                senderAvatar
                    .opacity(shouldShowAvatar ? 1 : 0)
            }
            rowContent
        }
        // "Show Times" reveals each message's time in the gutter across from
        // its bubble.
        .overlay(alignment: isOwn ? .leading : .trailing) {
            if store.isShowingMessageTimes && !message.isPending {
                Text(message.transcriptDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        // A jump from a reply quote lands here; the wash says which row.
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(isHighlighted ? 0.14 : 0))
                .padding(.horizontal, -6)
        }
        // Like Messages, the whole row is the message's hit area: a
        // right-click anywhere on it — bubble, gutter, sender line — opens
        // the tapback/reply/edit menu.
        .contentShape(Rectangle())
        .contextMenu {
            MessageMenu(message: message, isOwn: isOwn, editing: $editing)
        }
        .id(message.id)
    }

    private var isBotSender: Bool {
        store.people[message.senderPersonId]?.kind == "bot"
    }

    // The avatar bottom-aligns with the run's last bubble, the way Messages
    // seats it. Bots wear their marks; people their initials.
    @ViewBuilder
    private var senderAvatar: some View {
        if store.people[message.senderPersonId]?.kind == "bot" {
            BotAvatarView(name: message.senderName, size: 28)
        } else {
            AvatarView(name: message.senderName, size: 28)
        }
    }

    private var rowContent: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
            if shouldShowSender {
                HStack(spacing: 4) {
                    Text(message.senderName)
                    if message.isViaAgent { ViaClaudeChip() }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.top, 6)
            } else if message.isViaAgent {
                ViaClaudeChip()
                    .padding(isOwn ? .trailing : .leading, 12)
                    .padding(.top, 6)
            }
            if let reply = message.replyTo {
                ReplyQuote(reply: reply, names: store.mentionNames, isOwn: isOwn) {
                    onOpenOriginal(reply.id)
                }
            }
            if isShowingEditHistory && editing?.id != message.id {
                ForEach(message.editRevisions, id: \.editedAt) { revision in
                    EditRevisionBubble(content: revision.content, isOwn: isOwn)
                }
            }
            if editing?.id == message.id && !message.isDeleted {
                InlineMessageEditor(message: message, editing: $editing)
            } else {
                MessageBubble(
                    message: message, isOwn: isOwn, editing: $editing, selection: selection
                )
                    // Headroom for the tapback balloon overlapping the top
                    // corner, so it never covers the row above.
                    .padding(.top, message.reactions.isEmpty ? 0 : 12)
                    .frame(maxWidth: Tokens.Bubble.maxWidth, alignment: isOwn ? .trailing : .leading)
                    .padding(isOwn ? .leading : .trailing, Tokens.Bubble.farGutter)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    // Messages' blue "N Replies" under a message a thread hangs off; pressing
    // it pulls the thread out over the transcript.
    private var repliesLink: some View {
        Button(action: onShowReplies) {
            Text(replyCount == 1 ? "1 Reply" : "\(replyCount) Replies")
                .font(.caption)
                .foregroundStyle(Color.blue)
        }
        .buttonStyle(.plain)
        .padding(isOwn ? .trailing : .leading, 12)
        .padding(.top, 1)
    }

    private func readLine(for readers: [Person]) -> String {
        if isGroup {
            return readers.count == 1 ? "Read by \(readers[0].name)" : "Read by \(readers.count)"
        }
        return "Read"
    }

    // "Edited" takes real layout space under the bubble — never an overlay a
    // later row can cover — and tapping it unfolds what the message used to
    // say. Edits older than the history table stay a plain label.
    @ViewBuilder
    private var editedLine: some View {
        if message.editRevisions.isEmpty {
            Text("Edited")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(isOwn ? .trailing : .leading, 8)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isShowingEditHistory.toggle() }
            } label: {
                Text(isShowingEditHistory ? "Hide Edits" : "Edited")
                    .font(.system(size: 10))
                    .foregroundStyle(isShowingEditHistory ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .padding(isOwn ? .trailing : .leading, 8)
        }
    }
}

/// The history spinner, or the retry button after a failed page. A floating
/// overlay, never a row: showing it must not move the page.
private struct HistoryStatusOverlay: View {
    @Environment(AppStore.self) private var store
    let conversationId: String
    let topInset: CGFloat
    let retry: () -> Void

    var body: some View {
        if store.isLoadingOlder {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .hqGlass(in: Capsule())
                .padding(.top, topInset)
                .allowsHitTesting(false)
        } else if store.historyLoadErrors[conversationId] != nil {
            Button("Couldn’t load earlier messages · Retry", action: retry)
                .buttonStyle(QuietCapsuleButtonStyle())
                .padding(.top, topInset)
        }
    }
}

// Compared on the value inputs only. The two closures and the binding are
// rebuilt on every ChatView pass but behave the same for an unchanged
// message, so they take no part; anything the row reads from the store inside
// its body still invalidates it through observation.
extension MessageRow: Equatable {
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isOwn == rhs.isOwn
            && lhs.shouldShowSender == rhs.shouldShowSender
            && lhs.shouldShowAvatar == rhs.shouldShowAvatar
            && lhs.isGroup == rhs.isGroup
            && lhs.isLast == rhs.isLast
            && lhs.replyCount == rhs.replyCount
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.editingID == rhs.editingID
            && lhs.selection === rhs.selection
    }
}

// Editing happens on the bubble itself, the way Messages does it: an ✕ to
// bail, the text in a fresh field, a filled ✓ to save.
private struct InlineMessageEditor: View {
    @Environment(AppStore.self) private var store
    let message: Message
    @Binding var editing: Message?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                editing = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.quinary))
            }
            .buttonStyle(.plain)
            .help("Cancel editing")
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.quaternary)
                )
                .focused($isFocused)
                .onSubmit(save)
                .onExitCommand { editing = nil }
            Button(action: save) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.blue))
            }
            .buttonStyle(.plain)
            .help("Save edit")
        }
        .frame(maxWidth: 480)
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

// "N Replies" opens Messages' thread view: the original and every loaded
// reply pulled out over a veil. Click away to dismiss.
private struct ThreadOverlay: View {
    @Environment(AppStore.self) private var store
    let original: Message
    let onDismiss: () -> Void

    private var replies: [Message] {
        store.messages(in: original.conversationId)
            .filter { $0.replyTo?.id == original.id && !$0.isDeleted }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            // A short thread hugs its height; a long one scrolls at the cap.
            ViewThatFits(in: .vertical) {
                threadStack
                ScrollView { threadStack }
            }
            .frame(maxWidth: 480, maxHeight: 440)
        }
        .transition(.opacity)
    }

    private var threadStack: some View {
        VStack(spacing: 10) {
            threadRow(original)
            ForEach(replies) { threadRow($0) }
        }
        .padding(24)
    }

    @ViewBuilder
    private func threadRow(_ message: Message) -> some View {
        let isOwn = message.senderPersonId == store.me?.id
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
            if !isOwn {
                Text(message.senderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            Text(
                message.isDeleted
                    ? AttributedString("Message unsent")
                    : linkified(
                        message.content,
                        linkColor: isOwn ? .white : .blue,
                        names: store.mentionNames,
                        mentionColor: isOwn ? .white : Tokens.Palette.accent
                    )
            )
                .font(.system(size: 14))
                .italic(message.isDeleted)
                .foregroundStyle(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    isOwn ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }
}

private struct MessageBubble: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let isOwn: Bool
    @State private var linkPreview: LinkPreviewCache.State = .loading
    @AppStorage(LinkPreviewSetting.key) private var showsLinkPreviews = true
    @Binding var editing: Message?
    let selection: TranscriptSelection

    private var imageAttachments: [Attachment] {
        message.attachments.filter(\.isImage)
    }

    private var fileAttachments: [Attachment] {
        message.attachments.filter { !$0.isImage }
    }

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
                AttachmentBubble(
                    attachment: attachment, isOwn: isOwn, siblings: imageAttachments
                )
            }
            // Documents sit side by side, the way the meeting drop pairs its
            // summary and transcript, and wrap once the bubble runs out.
            if !fileAttachments.isEmpty {
                AttachmentFlow {
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
        // Tapbacks hang off the top corner on the reactor's side, the way
        // Messages overlaps them onto the bubble.
        .overlay(alignment: isOwn ? .topLeading : .topTrailing) {
            if !message.reactions.isEmpty {
                TapbackPill(message: message, isOwn: isOwn)
                    .offset(x: isOwn ? -12 : 12, y: -14)
            }
        }
    }

    // The text is selectable — press and drag highlights it — which SwiftUI
    // cannot give us without losing the row's menu, so it is drawn by an
    // AppKit view that hands clicks back (`SelectableBubbleText`): a plain
    // click raises that menu, tapbacks first. An unsent message has nothing
    // worth selecting and stays a plain label.
    @ViewBuilder
    private var textBubble: some View {
        ChatBubble(isOwn: isOwn, isMuted: message.isDeleted) {
            if message.isDeleted {
                Text("Message unsent").italic()
            } else {
                SelectableBubbleText(
                    messageId: message.id, text: message.content, isOwn: isOwn,
                    names: store.mentionNames,
                    selection: selection, clickOpensMenu: !message.isPending
                )
            }
        }
        .opacity(message.isPending ? 0.6 : 1)
        .help(message.transcriptDate.formatted(date: .abbreviated, time: .shortened))
    }

}

// Tapback balloons the way Messages draws them: one balloon per emoji, blue
// when you are among its senders, with the little thought-bubble dots
// trailing toward the reactor's side. Clicking one opens who-reacted.
private struct TapbackPill: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let isOwn: Bool

    private var tooltip: String {
        message.reactions
            .map { reaction in
                let names = reaction.personIds.compactMap { store.people[$0]?.name }
                return "\(reaction.emoji) \(names.joined(separator: ", "))"
            }
            .joined(separator: "\n")
    }

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
        .help(tooltip)
        .contentShape(Rectangle())
        .onTapGesture { store.tapbackDetailsTarget = message }
    }
}

private struct ReplyBar: View {
    @Environment(AppStore.self) private var store
    let conversationId: String

    var body: some View {
        if let target = store.replyTarget, target.conversationId == conversationId {
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replying to \(target.senderName)")
                        .font(.caption.weight(.medium))
                    Text(store.plainText(target.previewText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    store.replyTarget = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .hqComposerGlass(in: RoundedRectangle(cornerRadius: 12))
            .padding(.leading, 54)
            .padding(.trailing, 60)
            .padding(.top, 6)
        }
    }
}

// The bot's live state — "Thinking…", "Checking the data…" — server-authored,
// shown while it works. Whole messages then land like texts; nothing streams.
// It sits on the incoming bubble's left edge, but never wears the human dots:
private struct MentionPopup: View {
    let matches: [MentionCandidate]
    let selected: Int
    let onHighlight: (Int) -> Void
    let onPick: (MentionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    onPick(candidate)
                } label: {
                    HStack(spacing: 8) {
                        switch candidate {
                        case .person(let person) where person.kind == "bot":
                            BotAvatarView(name: person.name, size: 22)
                        case .person(let person):
                            AvatarView(name: person.name, size: 22)
                        case .broadcast:
                            // No face to draw: the room is not a person.
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(
                                    index == selected
                                        ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
                                )
                                .frame(width: 22, height: 22)
                                .background(
                                    (index == selected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.14)),
                                    in: Circle()
                                )
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.label)
                                .font(.system(size: 13))
                                .foregroundStyle(
                                    index == selected
                                        ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
                                )
                            if let caption = candidate.caption {
                                Text(caption)
                                    .font(.system(size: 10))
                                    .foregroundStyle(
                                        index == selected
                                            ? AnyShapeStyle(.white.opacity(0.75))
                                            : AnyShapeStyle(.secondary)
                                    )
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        index == selected ? Tokens.Palette.accent : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Mouse and keyboard agree on one highlight, the way a menu
                // behaves: hovering a row is what Return would then confirm.
                .onHover { isHovering in
                    if isHovering { onHighlight(index) }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: 268)
        .hqComposerGlass(in: RoundedRectangle(cornerRadius: 10))
    }
}

// The drag highlight: an inset accent border with a centered pill, hovering
// over the chat without taking any events (the AppKit catcher underneath owns
// the drag).
private struct DropTargetVeil: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .padding(6)
            .overlay {
                Label("Drop files to attach", systemImage: "paperclip")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
            }
            .allowsHitTesting(false)
    }
}

/// Standalone chats share the sidebar's plain content-header height.
/// Embedded chats leave the surrounding surface's header alone.
private struct ChatWindowChrome<Header: View>: ViewModifier {
    let isEmbedded: Bool
    let title: String
    @ViewBuilder let header: () -> Header

    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(alignment: .top) {
                    header()
                        .frame(maxWidth: .infinity)
                        .frame(height: Tokens.Home.desktopHeaderHeight)
                }
                .navigationTitle(title)
        }
    }
}

private struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var homePreferences: HomePreferences?
    let conversationId: String
    var isInMeetingPanel = false
    /// A side panel embeds this composer in a window that already
    /// has a composer of its own. The window-wide half of the key monitor —
    /// grabbing stray typing, the sidebar arrows, Escape — belongs to
    /// whichever composer OWNS the window. An embedded copy still installs a
    /// monitor; it just answers for nothing but its own focused field.
    /// Installing none at all is what made ⌘V of an image do nothing there:
    /// the owning composer declines the key while another editor holds
    /// focus, and NSTextView drops an image-only pasteboard silently.
    var ownsWindowKeyboard = true
    // This conversation's draft box: a keystroke here wakes this composer and
    // nothing that shows another chat's draft.
    private var draft: String {
        get { store.draftText(for: conversationId) }
        nonmutating set { store.setDraftText(newValue, for: conversationId) }
    }
    private var draftBinding: Binding<String> {
        Binding(get: { draft }, set: { draft = $0 })
    }
    @State private var isImporterOpen = false
    @State private var isEmojiPaletteOpen = false
    // Which mention row is highlighted; typing re-filters and returns it to
    // the top, the arrows walk it from there.
    @State private var mentionIndex = 0
    // The field is an AppKit text view now, so focus is not a @FocusState:
    // it reports first-responder changes, and is pulled forward by a bumped
    // request — the same shape the phone's composer uses. It has to be
    // responder state and not the edit notifications, which arrive a
    // keystroke late (ComposerTextView).
    @State private var isFieldFocused = false
    @State private var focusRequest = 0
    @State private var keyMonitor: Any?

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.drafts(in: conversationId).isEmpty
    }

    private var placeholder: String { "Message" }

    // The picker's rules are shared with the phone (MentionSuggestions), so
    // the composer only supplies who is in the room.
    private var mentions: MentionSuggestions {
        store.mentionSuggestions(draft: draft, conversationId: conversationId)
    }

    private var mentionToken: String? { mentions.token }

    private var visibleMentions: [MentionCandidate] { mentions.visible }

    // What the field tints against: the same people the picker offers, so
    // what lights up as you type is exactly what a space can commit to.
    // `@here` and `@everyone` are not in here — MentionText knows them
    // whatever roster it is handed, and listing them would double them up.
    private var mentionNames: [String] { mentions.personNames }

    // The list can shrink under the highlight as the token narrows it.
    private var mentionSelection: Int {
        guard !visibleMentions.isEmpty else { return 0 }
        return min(mentionIndex, visibleMentions.count - 1)
    }

    var body: some View {
        // The Messages shape: a bare + circle, then a glass rounded field with
        // the send arrow inside its trailing edge, appearing only when
        // sendable, and the emoji smiley on the far right.
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                isImporterOpen = true
            } label: {
                attachLabel
            }
            .buttonStyle(.plain)
            .help("Attach a file")

            styledFieldRow
                .frame(maxWidth: .infinity)

            Button {
                if isEmojiPaletteOpen {
                    // The panel was dismissed its own way (its close button
                    // never resigns the catcher), so front it again at the
                    // catcher's caret rather than latching inert.
                    NSApp.orderFrontCharacterPalette(nil)
                } else {
                    isEmojiPaletteOpen = true
                }
            } label: {
                emojiLabel
            }
            .buttonStyle(.plain)
            .help("Emoji")
            // The system palette anchors to the focused field's caret, so a
            // hidden catcher sitting ON the button is what makes the panel
            // spring from the smiley (the Messages shape) instead of the
            // composer field. It stays up across picks; each one lands in
            // the draft, and closing it hands focus back to the field.
            .background {
                if isEmojiPaletteOpen {
                    EmojiPaletteCatcher(picksOnce: false) { emoji in
                        draft += emoji
                    } onEnd: {
                        isEmojiPaletteOpen = false
                        // End-of-editing fires for ANY focus loss, so
                        // reclaim the field only when focus didn't just
                        // move to another editor — a click on the search
                        // field or a fresh tapback catcher keeps its win.
                        DispatchQueue.main.async {
                            if (NSApp.keyWindow?.firstResponder as? NSText)?.isEditable != true {
                                focusRequest &+= 1
                            }
                        }
                    }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                }
            }
        }
        .hqGlassContainer()
        .padding(.leading, 12)
        .padding(.trailing, BottomStackMetrics.trailingGutter)
        .padding(.top, 10)
        .padding(.bottom, 12)
        // The mention picker floats just above the field, like the web app's.
        // Lifted by frame geometry, not an alignmentGuide: an explicit .top
        // guide on the overlay content was silently ignored at runtime, which
        // dropped the popup onto the field and clipped it at the window edge.
        // A zero-height anchor with the popup bottom-hanging off it cannot be.
        .overlay(alignment: .topLeading) {
            if mentionToken != nil && !visibleMentions.isEmpty {
                MentionPopup(
                    matches: visibleMentions,
                    selected: mentionSelection,
                    onHighlight: { mentionIndex = $0 },
                    onPick: applyMention
                )
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .padding(.bottom, 4)
                    .frame(height: 0, alignment: .bottomLeading)
            }
        }
        .onAppear {
            // Taking the caret on appear, and claiming the text parked for
            // the composer, are the window owner's: an embedded panel must
            // not pull focus out of the composer being typed in.
            if ownsWindowKeyboard {
                focusRequest &+= 1
                if let pending = store.pendingComposerText {
                    draft += pending
                    store.pendingComposerText = nil
                }
            }
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        // RootView reuses this view across conversation switches (no .id key),
        // and the panel swaps threads under the embedded one, so the
        // monitor's captured self — and its conversationId — go stale: ⌘V
        // would stage attachments into whichever conversation was open when
        // the monitor was installed. Reinstall to capture the current one.
        .onChange(of: conversationId) { _, _ in
            mentionIndex = 0
            isEmojiPaletteOpen = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            installKeyMonitor()
        }
        .fileImporter(
            isPresented: $isImporterOpen,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                store.attach(fileURLs: urls, in: conversationId)
            }
        }
    }

    // Shift+Return breaks the line, Escape clears a mention token, ↑/↓ on an
    // empty field walk the sidebar, and typing with focus elsewhere reclaims
    // the field — all behaviors a SwiftUI TextField cannot express, so a
    // local key monitor supplies them. Several composers can be alive at once
    // (the meeting window and a side panel each embed a ChatView), so each
    // monitor handles only its own window's events, and only the window's
    // owning composer answers for keys aimed at no field in particular.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isMeetingWindowEvent =
                event.window?.identifier?.rawValue.hasPrefix("hq-meeting") == true
            guard isMeetingWindowEvent == isInMeetingPanel else { return event }
            // A sheet (green room, compose, new meeting) owns the keyboard.
            guard event.window?.sheetParent == nil, event.window?.attachedSheet == nil else {
                return event
            }
            // Escape closes an open tapback or thread veil wherever focus
            // is — window-wide, so the owning composer answers for it.
            if ownsWindowKeyboard, event.keyCode == 53,
               store.tapbackDetailsTarget != nil || store.threadTarget != nil {
                store.tapbackDetailsTarget = nil
                store.threadTarget = nil
                return nil
            }
            // ⌘V of a copied file or image stages an attachment. This must
            // live in the key monitor: while the field is focused its field
            // editor consumes the key, and NSTextView's paste of an
            // image-only pasteboard is a silent no-op — .onPasteCommand on
            // the TextField never fires. Other text editors (rename fields)
            // keep their own paste. A composer always claims the key for its
            // OWN field or palette; the paste that belongs to no field is the
            // window owner's, which is what keeps the two in one window from
            // both staging the same image.
            if event.charactersIgnoringModifiers == "v",
               event.modifierFlags.contains(.command),
               event.modifierFlags.intersection([.shift, .option, .control]).isEmpty,
               isFieldFocused || isEmojiPaletteOpen
                   || (ownsWindowKeyboard && !isEditorFocused(in: event.window)),
               didAttachFromPasteboard() {
                return nil
            }
            if isFieldFocused {
                if event.keyCode == 36 && event.modifierFlags.contains(.shift),
                   let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.insertText("\n", replacementRange: editor.selectedRange())
                    return nil
                }
                if event.keyCode == 53 && mentionToken != nil,
                   let atIndex = draft.lastIndex(of: "@") {
                    draft = String(draft[..<atIndex])
                    return nil
                }
                // While the picker is up it owns the arrows and Tab: the
                // highlight moves, and Tab confirms it the way Return does.
                if mentionToken != nil, !visibleMentions.isEmpty {
                    if event.specialKey == .upArrow || event.specialKey == .downArrow {
                        let step = event.specialKey == .upArrow ? -1 : 1
                        let count = visibleMentions.count
                        mentionIndex = (mentionSelection + step + count) % count
                        return nil
                    }
                    if event.keyCode == 48 {
                        applyMention(visibleMentions[mentionSelection])
                        return nil
                    }
                }
                // An empty field has no caret to move, so the arrows walk the
                // conversation list instead, the way the sidebar would.
                if ownsWindowKeyboard, !isInMeetingPanel, draft.isEmpty,
                   event.specialKey == .upArrow || event.specialKey == .downArrow,
                   event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                    store.selectAdjacentConversation(event.specialKey == .upArrow ? -1 : 1,
                                                     pinnedIDs: homePreferences?.pinnedIDs ?? [])
                    return nil
                }
                return event
            }
            // Typing with focus parked anywhere that isn't a text editor
            // belongs to the window's own composer — grab focus and keep the
            // keystroke.
            if ownsWindowKeyboard, event.specialKey == nil, event.keyCode != 53,
               event.modifierFlags.intersection([.command, .control]).isEmpty,
               let characters = event.characters, !characters.isEmpty,
               !isEditorFocused(in: event.window) {
                focusRequest &+= 1
                draft += characters
                return nil
            }
            return event
        }
    }

    // Selecting a bubble's text parks focus in its (read-only) text view.
    // That is not an editor: typing there still belongs to the composer, and
    // only an editable field may keep a keystroke of its own.
    private func isEditorFocused(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSText)?.isEditable == true
    }

    private func applyMention(_ candidate: MentionCandidate) {
        draft = mentions.applying(candidate)
        focusRequest &+= 1
    }

    // Keep the full glass disc interactive, including outside the glyph.
    private var attachLabel: some View {
        composerCircle("plus")
    }

    private var emojiLabel: some View {
        composerCircle("face.smiling")
    }

    private func composerCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: Tokens.Home.desktopInputHeight, height: Tokens.Home.desktopInputHeight)
            .hqComposerGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }

    // A capsule re-rounds itself as the field grows, so a four-line draft
    // ends up in a stadium. iOS keeps the one-line corner and only gets
    // taller — that corner is half the resting search-field height.
    private static let fieldRadius = Tokens.Home.desktopInputHeight / 2

    private var styledFieldRow: some View {
        let shape = RoundedRectangle(cornerRadius: Self.fieldRadius, style: .continuous)
        return fieldRow
            .frame(minHeight: Tokens.Home.desktopInputHeight)
            .hqComposerGlass(in: shape)
    }

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // A text view rather than a TextField: only attributed text can
            // show a tag the way Messages does, and SwiftUI's field cannot
            // style a run of what it holds. The draft it reads and writes is
            // still ordinary `@Name` wire text.
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .lineLimit(1)
                        .font(Tokens.Typography.row)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                MentionComposerField(
                    text: draftBinding,
                    names: mentionNames,
                    placeholder: placeholder,
                    focusRequest: focusRequest,
                    onSubmit: {
                        // Return confirms the highlighted mention while the
                        // picker is up.
                        if mentionToken != nil, !visibleMentions.isEmpty {
                            applyMention(visibleMentions[mentionSelection])
                        } else {
                            send()
                        }
                    },
                    onFocusChange: { isFieldFocused = $0 }
                )
            }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 9)
                .onChange(of: draft) { _, newValue in
                    if !newValue.isEmpty { store.sendTyping(in: conversationId) }
                    // A new token is a new list: the highlight returns to the
                    // top rather than pointing at whoever now sits at that row.
                    mentionIndex = 0
                }
                .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in
                    paste(providers)
                }
            if canSend {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .hqGlass(in: Circle(), tint: .blue, interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send message")
                .disabled(!canSend)
                .padding(.trailing, 4)
                .padding(.bottom, 5)
            }
        }
    }

    // A copied Finder file arrives as a file URL; a copied image as data in
    // whichever encoding the source app chose. TIFF re-encodes — nobody wants
    // a .tiff attachment.
    private func paste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.attach(fileURLs: [url], in: conversationId) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                pasteImageData(from: provider, as: .png, fileName: "Pasted image.png")
            } else if provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) {
                pasteImageData(from: provider, as: .jpeg, fileName: "Pasted image.jpeg")
            } else if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
                _ = provider.loadDataRepresentation(for: .tiff) { data, _ in
                    guard let data,
                          let png = NSBitmapImageRep(data: data)?
                              .representation(using: .png, properties: [:])
                    else { return }
                    Task { @MainActor in
                        store.attach(
                            imageData: png, fileName: "Pasted image.png",
                            contentType: "image/png", in: conversationId
                        )
                    }
                }
            }
        }
    }

    // Copied Finder files attach outright. Image data attaches unless the
    // pasteboard also carries non-URL plain text — a table or rich-text copy
    // (Excel cells ship a rendered image beside the text) should stay a text
    // paste, while a browser's Copy Image only brings the source URL along.
    private func didAttachFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            store.attach(fileURLs: urls, in: conversationId)
            return true
        }
        if let text = pasteboard.string(forType: .string), URL(string: text)?.scheme == nil {
            return false
        }
        if let data = pasteboard.data(forType: .png) {
            store.attach(
                imageData: data, fileName: "Pasted image.png",
                contentType: "image/png", in: conversationId
            )
            return true
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            store.attach(
                imageData: data, fileName: "Pasted image.jpeg",
                contentType: "image/jpeg", in: conversationId
            )
            return true
        }
        if let data = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            store.attach(
                imageData: png, fileName: "Pasted image.png",
                contentType: "image/png", in: conversationId
            )
            return true
        }
        return false
    }

    private func pasteImageData(from provider: NSItemProvider, as type: UTType, fileName: String) {
        _ = provider.loadDataRepresentation(for: type) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                store.attach(
                    imageData: data, fileName: fileName,
                    contentType: type.preferredMIMEType ?? "application/octet-stream",
                    in: conversationId
                )
            }
        }
    }

    private func send() {
        let text = draft
        store.send(text, in: conversationId)
    }
}
