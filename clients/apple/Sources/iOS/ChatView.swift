import SwiftUI

/// The transcript, Messages-shaped: bubbles under a centered title, a
/// floating composer, and the same arithmetic the Mac uses for runs, quiet
/// gaps, sender labels, and avatars (`TranscriptLayout`).
///
/// Deliberately a plain `LazyVStack`-free `VStack` inside a `ScrollView`
/// (`docs/architecture.md` § SwiftUI layout traps): lazy placement plus measured
/// bubble text once re-measured itself into a multi-second main-thread hang.
/// History pages on scroll-near-top instead.
struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let conversationId: String
    @State private var editing: Message?
    @State private var bottomStackHeight: CGFloat = 0
    @State private var attachmentMenu = ChatAttachmentMenuState()
    @State private var isDetailsUp = false
    @State private var isGreenRoomUp = false
    // The bottom-pinning intent: true until the user scrolls away, reset by
    // every thread switch. Read when layout moves under the viewport.
    @State private var isPinnedToBottom = true
    @State private var isUserScrolling = false
    @State private var historyTrigger = TranscriptProximityHistoryTrigger()
    @State private var viewportPreserver = TranscriptViewportPreserver()
    // The row a jump landed on, washed so the landing is visible, then
    // cleared. A jump comes from a reply quote in this transcript or from a
    // search hit (`store.messageJump`); anything else that learns to name a
    // message — a push carrying a message id — publishes the same value and
    // arrives here with nothing new to write.
    @State private var highlighted: String?
    // A jump OWNS the viewport while it runs: it pages older history in and
    // then parks the transcript mid-thread, and both of those are exactly
    // what the bottom pin and the history prefetch read as reasons to move.
    // Neither may act until the landing is done.
    @State private var isJumping = false
    // Older systems overlay the header and reserve its height as transcript
    // padding; the header's fonts scale, so the reservation scales with them.
    @ScaledMetric(relativeTo: .title2) private var legacyHeaderClearance: CGFloat = 104
    @ScaledMetric(relativeTo: .title2) private var legacyCompactHeaderClearance: CGFloat = 52
    @ScaledMetric(relativeTo: .title2) private var videoControlSize: CGFloat = 44

    // Both read this conversation's own slot in the store: a message, an agent
    // step or a read receipt in any other chat does not re-run this body.
    private var messages: [Message] {
        TranscriptLayout.orderedMessages(store.messages(in: conversationId))
    }

    private var conversation: Conversation? {
        store.conversation(conversationId)
    }

    private func makeLayout(
        for room: Conversation?, myPersonId: String?, messages: [Message]
    ) -> TranscriptLayout {
        TranscriptLayout(
            messages: messages,
            myPersonId: myPersonId,
            isGroup: room?.kind == "group",
            isBotDM: room.map { store.isBotConversation($0) } ?? false,
            isBot: { store.people[$0]?.kind == "bot" }
        )
    }

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .bottom) {
            Tokens.Palette.messageCanvas.ignoresSafeArea()
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
                    // re-runs the transcript, not the composer and header
                    // around it. `messages` filters the whole loaded
                    // transcript, and the scroll action
                    // below runs on every scroll frame, so it reads the Bool.
                    let ordered = messages
                    let hasMessages = !ordered.isEmpty
                    transcript(proxy: proxy, ordered: ordered)
                        // Opens already at its bottom — anchored before first
                        // layout, never scrolled there afterwards. Later size
                        // changes retain the bottom anchor only while reading
                        // the live edge. History browsing and message jumps
                        // keep their own viewport instead.
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .defaultScrollAnchor(isPinnedToBottom && !isJumping ? .bottom : nil, for: .sizeChanges)
                        .onScrollPhaseChange { _, phase in
                            isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                        }
                        .onScrollGeometryChange(for: TranscriptScrollProbe.self) { geometry in
                            TranscriptScrollProbe(geometry)
                        } action: { oldValue, newValue in
                            // A jump is already steering the viewport: its own
                            // paging and its landing scroll both emit geometry,
                            // and arming either rule from that is how a jump
                            // ends up snapped back to the live edge.
                            guard !isJumping else { return }
                            if hasMessages,
                               historyTrigger.shouldLoad(at: newValue.offsetY) {
                                Task { @MainActor in
                                    await store.loadOlder(in: conversationId) {
                                        viewportPreserver.beginPrepend()
                                    }
                                    viewportPreserver.endPrependWhenLayoutSettles()
                                }
                            }
                            // Pinning is an intent, not a reading: only the user
                            // leaves the bottom through a scroll gesture. Keyboard
                            // animation can also emit offset-only changes.
                            // Content growing under a pinned viewport
                            // (pages landing in a cold-opened thread, a link
                            // preview card, a typing line) re-asserts the bottom
                            // every time, so growths that race one another —
                            // and cancel any single corrective scroll — converge
                            // on the last one instead of parking the chat
                            // wherever the race left it.
                            if newValue.isAtBottom {
                                isPinnedToBottom = true
                            } else if isUserScrolling {
                                isPinnedToBottom = false
                            } else if isPinnedToBottom && newValue.layoutDiffers(from: oldValue) {
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
                        .onChange(of: ordered.last?.id) { _, newValue in
                            guard newValue != nil, !isJumping else { return }
                            // Deferred a turn: the new row — and any timestamp
                            // break inserted with it — must be laid out before
                            // the target is measured, or the slide lands short.
                            // The target is the transcript's end, not the row,
                            // so typing lines under the new message stay in view.
                            Task { @MainActor in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom)
                                }
                            }
                        }
                        // A search hit names a message in some other thread;
                        // this transcript pages back to it, lands on it, and
                        // flashes the row. `initial: true` because the jump is
                        // already published by the time the transcript mounts —
                        // `openSearchResult` selects the conversation and sets
                        // the jump in the same turn, which is what CREATES
                        // this view.
                        .onChange(of: store.messageJump, initial: true) { _, target in
                            guard let target, target.conversationId == conversationId else { return }
                            store.messageJump = nil
                            reveal(target.messageId, proxy: proxy)
                        }
                        // A fresh thread starts pinned no matter where the
                    // last one ended.
                    .onChange(of: conversationId) {
                        isPinnedToBottom = true
                        isJumping = false
                        highlighted = nil
                        historyTrigger.reset()
                        viewportPreserver.reset()
                    }
                    .id(conversationId)
                }
            }
        }
        .modifier(PhoneBottomBar {
            ChatBottomStack(conversationId: conversationId, height: $bottomStackHeight, attachmentMenu: attachmentMenu)
                .accessibilityIdentifier("conversation-bottom-controls")
        })
        .modifier(ChatHeaderMount { conversationHeader })
        .overlay { ChatAttachmentMenu(menu: attachmentMenu) }
        .onChange(of: conversationId) { attachmentMenu.isPresented = false }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        // Hiding the system back button also turns the edge swipe off; the
        // header's own Back button pops the same stack, so the swipe must too.
        .background { InteractivePopGestureEnabler() }
        .sheet(isPresented: $isGreenRoomUp) {
            GreenRoomView(conversationId: conversationId, meetingId: nil,
                          title: conversation.map { store.displayName(for: $0) } ?? "Call")
                .environment(store)
        }
        .onChange(of: store.activeCallId) { _, callId in
            if callId != nil { isGreenRoomUp = false }
        }
        .sheet(isPresented: $isDetailsUp) {
            if let conversation {
                ConversationDetailsView(conversation: conversation).environment(store)
            }
        }
        .sheet(item: $store.threadTarget) { original in
            ThreadSheet(original: original).environment(store)
        }
        .sheet(item: $store.tapbackDetailsTarget) { target in
            TapbackDetailsSheet(message: target).environment(store)
        }
        .sheet(item: $store.forwardTarget) { message in
            ForwardSheet(message: message).environment(store)
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
        .task(id: conversationId) { await store.loadMessages(conversationId) }
        // On screen, so no background trim drops rows from under it.
        .onAppear { store.transcriptAppeared(conversationId) }
        .onDisappear { store.transcriptDisappeared(conversationId) }
        .onChange(of: conversationId) { previous, current in
            store.transcriptDisappeared(previous)
            store.transcriptAppeared(current)
        }
    }

    /// iOS 26 mounts the header in a top `safeAreaBar`, so the system supplies
    /// the inset the transcript starts below and fades text out under it. Older
    /// systems overlay the header and reserve its height here.
    private var transcriptTopClearance: CGFloat {
        if #available(iOS 26.0, *) { return Tokens.Space.x2 }
        return verticalSizeClass == .compact
            ? Self.cappedHeaderMetric(legacyCompactHeaderClearance, base: 52)
            : Self.cappedHeaderMetric(legacyHeaderClearance, base: 104)
    }

    /// The header's controls stop growing at the second accessibility size, so
    /// the back capsule and video circle never crowd the 180pt title pill; the
    /// metrics tied to them stop at the same scale.
    private static func cappedHeaderMetric(_ scaled: CGFloat, base: CGFloat) -> CGFloat {
        let ceiling = UIFontMetrics(forTextStyle: .title2).scaledValue(
            for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityLarge))
        return min(scaled, ceiling)
    }

    private var conversationHeader: some View {
        ZStack(alignment: .top) {
            HStack(alignment: .top) {
                ChatBackButton(conversationId: conversationId) {
                    dismiss()
                    store.destination = .none
                }
                Spacer()
                Button { isGreenRoomUp = true } label: {
                    let side = Self.cappedHeaderMetric(videoControlSize, base: 44)
                    Image(systemName: "video")
                        .font(.title2)
                        .frame(width: side, height: side)
                        .hqComposerGlass(in: Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Call conversation")
            }
            if let conversation {
                Button { isDetailsUp = true } label: {
                    ConversationTitlePill(conversation: conversation)
                        .frame(maxWidth: 180)
                }
                .accessibilityLabel("Conversation details")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.Palette.ink)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier("conversation-header")
    }

    /// Takes the proxy rather than reading one of its own: a jump from a reply
    /// quote starts on a row, deep inside the stack, and the row needs the
    /// same scroller the jump observer above uses.
    private func transcript(proxy: ScrollViewProxy, ordered: [Message]) -> some View {
        ScrollView {
            // One layout snapshot for the whole render — the same discipline
            // as the Mac: row closures updating later must not re-read the
            // store and see an array the trim already shrank.
            // The room's facts, and who I am, read once per render rather than
            // once per row.
            let room = conversation
            let isGroup = room?.kind == "group"
            let isFeed = room.map { store.isFeedRoom($0) } ?? false
            let meID = store.me?.id
            let editingID = editing?.id
            let layout = makeLayout(for: room, myPersonId: meID, messages: ordered)
            let messages = layout.messages
            let runs = layout.eventRuns
            let replyCounts = layout.replyCounts
            // The last message I wrote, found once: the "Read" line hangs off
            // it. (Found per row it was a scan of the whole transcript each.)
            let lastOwnID = messages.last(where: { $0.senderPersonId == meID })?.id
            // The live work row already says what the bot is doing, in the
            // transcript; the shimmer line is for
            // turns that write no row — the Mac's rule.
            let hasLiveWorkRow = messages.last(where: \.isWork)?.isWorking == true
            VStack(spacing: 2) {
                VStack(spacing: 2) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if runs.absorbed.contains(message.id) {
                            EmptyView()
                        } else {
                            if layout.shouldShowTimestamp(at: index) {
                                TimestampSeparator(date: message.transcriptDate)
                            }
                            row(
                                message, at: index, layout: layout,
                                runs: runs.runs, replyCounts: replyCounts,
                                context: RowContext(
                                    isGroup: isGroup, isFeed: isFeed, meID: meID,
                                    lastOwnID: lastOwnID, editingID: editingID
                                ),
                                proxy: proxy
                            )
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Tokens.Space.x4)
                // The lines sit outside the gutter padding, on their own
                // built-in 14pt — a transcript row's alignment, not doubled.
                TypingLine(conversationId: conversationId)
                if !hasLiveWorkRow {
                    BotActivityLine(conversationId: conversationId, isGroup: isGroup)
                }
            }
            .padding(.top, transcriptTopClearance)
            .padding(.bottom, Tokens.Space.x3)
            // The whole-content anchor every scroll-to-bottom targets, so the
            // lines below the last row are included in "the bottom".
            .id(TranscriptAnchor.bottom)
            .background {
                TranscriptScrollViewResolver { scrollView in
                    viewportPreserver.attach(to: scrollView)
                }
            }
        }
        // Loading state floats over the transcript instead of becoming a row:
        // showing or hiding it must not move the page before the older rows
        // have even arrived.
        .overlay(alignment: .top) { HistoryLoadingSpinner() }
        .scrollDismissesKeyboard(.interactively)
    }

    /// What every row of one render shares, read once up front.
    private struct RowContext {
        let isGroup: Bool
        let isFeed: Bool
        let meID: String?
        let lastOwnID: String?
        let editingID: String?
    }

    @ViewBuilder
    private func row(
        _ message: Message, at index: Int, layout: TranscriptLayout,
        runs: [String: [Message]], replyCounts: [String: Int],
        context: RowContext, proxy: ScrollViewProxy
    ) -> some View {
        if message.isWork {
            WorkRow(message: message)
                .id(message.id)
        } else if let run = runs[message.id] {
            GroupEventRun(messages: run, isFeed: context.isFeed)
                .id(message.id)
        } else if message.isSystem {
            GroupEventRow(message: message, isFeed: context.isFeed)
                .id(message.id)
        } else {
            MessageRow(
                message: message,
                isOwn: message.senderPersonId == context.meID,
                shouldShowSender: layout.shouldShowSender(at: index),
                shouldShowAvatar: layout.shouldShowAvatar(at: index),
                isGroup: context.isGroup,
                isLast: message.id == context.lastOwnID,
                hasTail: index == layout.messages.count - 1 || layout.isStartOfRun(at: index + 1),
                replyCount: replyCounts[message.id] ?? 0,
                isHighlighted: highlighted == message.id,
                editingID: context.editingID,
                editing: $editing,
                onOpenOriginal: { reveal($0, proxy: proxy) }
            )
            // Equatable on its value inputs (the closure behaves the same for
            // an unchanged message), so a pass that changed nothing about this
            // row skips its body. It still observes the store for what it reads.
            .equatable()
            .padding(.top, index > 0 && layout.isStartOfRun(at: index) ? 10 : 0)
            .id(message.id)
        }
    }

    /// Goes to a named message: pulls older pages until it is loaded, parks it
    /// in the middle of the viewport, and washes the row so the landing is
    /// legible. The Mac's `ChatView.reveal` with the phone's paging.
    ///
    /// `isJumping` holds for the whole run — including the flash — because
    /// every step of it moves layout under the two rules that watch layout:
    /// the bottom pin would re-assert the live edge on the first prepend, and
    /// the proximity prefetch would page again from wherever the jump parked.
    private func reveal(_ messageId: String, proxy: ScrollViewProxy) {
        // Claimed synchronously, before the first await: the geometry action
        // reads the value its body pass captured, so setting it inside the
        // task would leave one prepend's worth of callbacks still armed.
        isJumping = true
        // The jump is a deliberate departure from the live edge, and any
        // preservation still armed from a scroll gesture would fight the pages
        // this pulls in.
        isPinnedToBottom = false
        viewportPreserver.reset()
        Task { @MainActor in
            defer { isJumping = false }
            while !messages.contains(where: { $0.id == messageId }) {
                let oldest = store.messages(in: conversationId).first?.id
                await store.loadOlder(in: conversationId)
                // No new page — history ran out, or another load is already in
                // flight. Either way this jump has nowhere to go.
                guard store.messages(in: conversationId).first?.id != oldest else { return }
            }
            // A search hit loads its rows in the same update that creates this
            // scroll view. Let that layout land before asking the proxy for a
            // row it has not measured yet.
            await Task.yield()
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

    private var isDeleteConfirmPresented: Binding<Bool> {
        Binding(
            get: { store.deleteTarget != nil },
            set: { isPresented in
                if !isPresented { store.deleteTarget = nil }
            }
        )
    }
}

/// The header's Back capsule with the unread total of every OTHER chat. The
/// total is read here, in a view of its own: summing the visible conversations
/// inside ChatView's body re-ran the whole transcript for every read receipt
/// and bump.
private struct ChatBackButton: View {
    @Environment(AppStore.self) private var store
    let conversationId: String
    let action: () -> Void

    private var unreadCount: Int {
        store.visibleConversations.filter { $0.id != conversationId }.reduce(0) { $0 + $1.unreadCount }
    }

    var body: some View {
        let count = unreadCount
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.medium))
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Tokens.Palette.actionInk)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Tokens.Palette.action, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .hqComposerGlass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .accessibilityLabel("Back to messages")
        .accessibilityValue("\(count) unread messages")
    }
}

/// The history spinner. `isLoadingOlder` flips twice per page; read in
/// ChatView's body it re-ran the transcript for each flip.
private struct HistoryLoadingSpinner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.isLoadingOlder {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }
}

/// The centered avatar-over-name pill the Mac header uses, carried
/// onto the phone as the navigation bar's principal item. Pressing it opens
/// details — the same gesture, the same destination.
private struct ConversationTitlePill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let conversation: Conversation

    /// "Cy", a titled group's title, or "Cy +4" — the Mac's rule.
    private var title: String {
        if let title = conversation.title, !title.isEmpty { return title }
        let names = store.displayMembers(of: conversation).map(\.name)
        guard let first = names.first else { return store.displayName(for: conversation) }
        let firstName = first.split(separator: " ").first.map(String.init) ?? first
        return names.count > 1 ? "\(firstName) +\(names.count - 1)" : firstName
    }

    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass != .compact {
                ClusterAvatarView(conversation: conversation, size: 60)
            }
            HStack(spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.headline)
                    .foregroundStyle(Tokens.Palette.ink)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .hqComposerGlass(in: Capsule(), interactive: true)
        }
    }
}

/// Mounts the conversation header. On iOS 26 it is a top `safeAreaBar`, the
/// counterpart of the composer's `PhoneBottomBar`: the system draws its soft
/// scroll-edge effect behind the controls and insets the transcript. Only the
/// controls carry glass; the bar itself paints nothing. Older systems keep the
/// transparent overlay.
private struct ChatHeaderMount<Header: View>: ViewModifier {
    @ViewBuilder var header: () -> Header

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top, spacing: 0) { header() }
        } else {
            content.overlay(alignment: .top) { header() }
        }
    }
}

/// Keeps swipe-back alive while the system back button is hidden. UIKit turns
/// the pop recognizers off when the top controller hides the back button, so
/// each gets a delegate that answers `shouldReceive` and `shouldBegin` itself
/// and forwards every other public delegate method (simultaneity, failure
/// requirements — what makes the full-width iOS 26 pan yield to scrolling and
/// the draft strip).
/// On iOS 26 the full-width recognizer is the one that actually pops: the edge
/// recognizer never began in the simulator (measured with a logging gate), so
/// both are gated, and a pop may only start from a touch at the leading edge
/// (`shouldReceive`), so horizontal drags on the attachment strip and in the
/// composer never pop. `shouldBegin` adds the checks UIKit's delegate would
/// have made: something to pop to, and no transition already running.
/// The chat sits in a `NavigationStack` that the collapsed split view pushes,
/// so the stack that pops is the nearest ancestor navigation controller holding
/// more than one view controller.
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var popGate: PopGate?
        private var contentPopGate: PopGate?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            restore()
            var ancestor = parent
            while let current = ancestor {
                if let stack = current as? UINavigationController, stack.viewControllers.count > 1,
                   let recognizer = stack.interactivePopGestureRecognizer {
                    popGate = PopGate.install(on: recognizer, stack: stack)
                    if #available(iOS 26.0, *), let content = stack.interactiveContentPopGestureRecognizer {
                        contentPopGate = PopGate.install(on: content, stack: stack)
                    }
                    return
                }
                ancestor = current.parent
            }
        }

        // The recognizer holds its delegate weakly, so the gate must never go
        // away while it is installed: put the system's own state back on every
        // way out — disappearing, leaving the parent, or being released. Not in
        // viewWillDisappear: that runs when an interactive pop STARTS, and
        // turning the recognizer off then can cancel the very swipe in flight
        // (a cancelled pop calls viewDidAppear again, which re-installs).
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restore()
        }

        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            if parent == nil { restore() }
        }

        deinit { restore() }

        private func restore() {
            popGate?.restore()
            popGate = nil
            contentPopGate?.restore()
            contentPopGate = nil
        }
    }

    final class PopGate: NSObject, UIGestureRecognizerDelegate {
        weak var stack: UINavigationController?
        weak var recognizer: UIGestureRecognizer?
        weak var original: UIGestureRecognizerDelegate?
        let wasEnabled: Bool

        init(stack: UINavigationController, recognizer: UIGestureRecognizer,
             original: UIGestureRecognizerDelegate?, wasEnabled: Bool) {
            self.stack = stack
            self.recognizer = recognizer
            self.original = original
            self.wasEnabled = wasEnabled
        }

        /// Installs a gate, chaining from one a previous chat left behind so
        /// the system's own delegate and enabled state are never lost.
        static func install(on recognizer: UIGestureRecognizer, stack: UINavigationController) -> PopGate {
            let prior = recognizer.delegate as? PopGate
            let gate = PopGate(
                stack: stack, recognizer: recognizer,
                original: prior?.original ?? recognizer.delegate,
                wasEnabled: prior?.wasEnabled ?? recognizer.isEnabled
            )
            recognizer.delegate = gate
            recognizer.isEnabled = true
            return gate
        }

        func restore() {
            guard let recognizer, recognizer.delegate === self else { return }
            recognizer.delegate = original
            recognizer.isEnabled = wasEnabled
        }

        /// Something to pop to, and no push or pop already running — a swipe
        /// mid-transition is what freezes a navigation stack.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let stack, stack.viewControllers.count > 1,
                  stack.transitionCoordinator == nil else { return false }
            return true
        }

        /// Only a touch that starts at the leading edge may begin a pop. UIKit
        /// asks `shouldBegin` at touch-down, before any movement, so direction
        /// cannot be judged there (measured: state possible, translation zero).
        /// The full-width iOS 26 recognizer would otherwise start a pop from a
        /// drag on the attachment strip or a cursor drag in the composer.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            let x = touch.location(in: view).x
            let band: CGFloat = 32
            return view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? x >= view.bounds.width - band : x <= band
        }

        /// Only public delegate methods are forwarded. The system's private
        /// `_gestureRecognizer:shouldReceiveEvent:` is the check that refuses
        /// the touch while the back button is hidden, so it stays unanswered.
        private func forwards(_ selector: Selector) -> Bool {
            !NSStringFromSelector(selector).hasPrefix("_")
                && (original as AnyObject?)?.responds(to: selector) == true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwards(selector)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            forwards(selector) ? original : super.forwardingTarget(for: selector)
        }
    }
}
