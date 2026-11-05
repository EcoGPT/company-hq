import SwiftUI

// The sidebar renders whatever its LIVE width calls for — the full Messages
// list when wide, the avatar rail when narrow — swapping at the same
// threshold RootView's settle pass uses, so a drag shows exactly the state
// letting go will land on. RootView owns the resting widths.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    @Binding var isComposing: Bool
    /// Set by Edit ▸ Find; the field takes focus once it is on screen (the
    /// rail has none) and clears the request.
    @Binding var searchFocusRequested: Bool
    @FocusState private var isSearchFocused: Bool
    let onWidthChange: (CGFloat) -> Void
    // Local mirror of the store selection. The List writes nil through its
    // binding when it unmounts (e.g. the rail replaces it); only non-nil
    // picks forward to the store.
    @State private var listSelection: String?
    let onToggleSidebar: () -> Void
    @State private var greenRoom: GreenRoomTarget?
    // The list's last measured height. It outlives this view (a takeover
    // unmounts the sidebar) and a relaunch, so the grid's height rule has a
    // number on the first frame instead of drawing the whole grid and collapsing.
    // `listHeight` is the live number, held in memory; the AppStorage copy is
    // written once the height settles (and when the list leaves), not on
    // every height tick — each write was a UserDefaults store plus a sidebar
    // re-run for a value the grid only needs when its collapse flips.
    @AppStorage("sidebarListHeight", store: PresentationDefaults.current) private var storedListHeight = 0.0
    @State private var liveListHeight: Double?
    @ScaledMetric(relativeTo: .caption) private var itemWidth = Tokens.Home.shortcutWidth
    // The group awaiting delete confirmation: deleting freezes and
    // hides — the alert says so before anything happens.
    @State private var deleteTarget: Conversation?

    private var listHeight: Double { liveListHeight ?? storedListHeight }

    /// The grid's collapse rule at `listHeight`, from the same inputs the bar
    /// gets. Read from the sidebar's own state so a height change can tell
    /// whether it flips the rule; a More / Less choice makes the height moot.
    private func isGridCollapsed(listHeight: Double, availableWidth: CGFloat) -> Bool {
        let choice = SidebarGrid.Choice(
            rawValue: PresentationDefaults.current.integer(forKey: "sidebarGridChoice")) ?? .none
        let meetingCards = store.liveMeetings.filter { $0.id != store.activeCallId }.count
        return SidebarGrid.isCollapsed(
            choice: choice, listHeight: CGFloat(listHeight),
            cells: DesktopWorkspaceBar.cellCount,
            columns: DesktopWorkspaceBar.columnCount(availableWidth: availableWidth, itemWidth: itemWidth),
            pinCount: pinnedConversations.count, meetingCards: meetingCards)
    }

    var body: some View {
        GeometryReader { geo in
            let isRailWidth = geo.size.width < SidebarMetrics.railBelow
            VStack(spacing: 0) {
                sidebarHeader(isRailWidth: isRailWidth)
                if isRailWidth {
                    CollapsedRailView()
                } else {
                    searchField
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    expandedList(availableWidth: geo.size.width - 16)
                }
            }
            .clipped()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsFooter(isRail: isRailWidth)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            .onChange(of: geo.size.width) { _, newWidth in
                // RootView ignores collapsed geometry during split-view relayout.
                onWidthChange(newWidth)
            }
            .onAppear {
                onWidthChange(geo.size.width)
            }
        }
        .navigationTitle("")
        // Own the action so a rapid second click is not swallowed by the
        // split view's visibility changes during a programmatic divider move.
        .toolbar(removing: .sidebarToggle)
        .onChange(of: store.selectedConversationId) { _, newValue in
            listSelection = newValue
        }
        .onChange(of: listSelection) { _, newValue in
            guard let newValue, newValue != store.selectedConversationId else { return }
            store.openConversation(newValue)
        }
        .sheet(item: $greenRoom) { target in
            GreenRoomView(
                title: target.title, kind: target.kind,
                conversationId: target.conversationId, meetingId: target.meetingId
            )
        }
    }

    private var searchField: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search messages")
                .focused($isSearchFocused)
            if !store.searchQuery.isEmpty {
                Button { store.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Tokens.Home.desktopInputHeight)
        .hqComposerGlass(in: Capsule(), interactive: true)
        .onChange(of: searchFocusRequested, initial: true) { _, requested in
            guard requested else { return }
            isSearchFocused = true
            searchFocusRequested = false
        }
    }

    private func sidebarHeader(isRailWidth: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if isRailWidth {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 48)
                    sidebarToggle(isRailWidth: true)
                }
            } else {
                HStack(spacing: 4) {
                    Spacer(minLength: 90)
                    Button { isComposing = true } label: {
                        headerSymbol("square.and.pencil", verticalOffset: -1)
                    }
                    .buttonStyle(.plain)
                    .help("New conversation")
                    .accessibilityLabel("New conversation")
                    .padding(.top, 16)
                    sidebarToggle(isRailWidth: false).padding(.top, 16)
                }
                .padding(.trailing, 16)
                .frame(height: 48)
            }
        }
    }

    private func sidebarToggle(isRailWidth: Bool) -> some View {
        Button(action: onToggleSidebar) {
            headerSymbol("sidebar.left")
        }
        .buttonStyle(.plain)
        .help(isRailWidth ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityLabel(isRailWidth ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityIdentifier("desktop-sidebar-toggle")
    }

    private func headerSymbol(_ name: String, verticalOffset: CGFloat = 0) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .font(.system(size: 16, weight: .regular))
            .frame(width: 20, height: 18)
            // SF Symbols have different optical insets; align the ink, not the asset bounds.
            .offset(y: verticalOffset)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }

    private var pinnedConversations: [Conversation] {
        store.pinnedConversations(ids: preferences.pinnedIDs)
    }

    @ViewBuilder private func sidebarAccessories(availableWidth: CGFloat) -> some View {
        let meetingCards = store.liveMeetings.filter { $0.id != store.activeCallId }
        ForEach(meetingCards) { call in
            ActiveMeetingCard(call: call, isCompact: availableWidth < 250) {
                greenRoom = GreenRoomTarget(
                    conversationId: nil, kind: "meeting",
                    title: call.title ?? "Meeting", meetingId: call.meetingId
                )
            }
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        // The bar and the pins take the column count, not the width: they
        // re-run when a column comes or goes, not on every pixel of a drag.
        let columns = DesktopWorkspaceBar.columnCount(availableWidth: availableWidth, itemWidth: itemWidth)
        DesktopWorkspaceBar(columnCount: columns, listHeight: CGFloat(listHeight),
                            meetingCards: meetingCards.count, pinCount: pinnedConversations.count)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 12, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        if !pinnedConversations.isEmpty {
            DesktopPinnedChats(conversations: pinnedConversations, columns: columns)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    private func expandedList(availableWidth: CGFloat) -> some View {
        @Bindable var store = store
        return List(selection: $listSelection) {
            if store.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Section("Messages") {
                    if store.searchResults.isEmpty {
                        Text("No matches")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    ForEach(store.searchResults) { message in
                        SearchResultRow(message: message)
                    }
                }
            } else {
                sidebarAccessories(availableWidth: availableWidth)
                ForEach(store.visibleConversations.filter { !preferences.isPinned($0.id) }) { conversation in
                    // Equatable on the id alone: the row reads its own
                    // conversation, so a change to one row re-renders that row
                    // while this body re-running leaves the others alone.
                    ConversationRow(conversationID: conversation.id)
                        .equatable()
                        .tag(conversation.id)
                        .contextMenu {
                            Button { preferences.pin(conversation.id) } label: {
                                Label("Pin Conversation", systemImage: "pin")
                            }
                            .disabled(preferences.pinnedIDs.count >= HomePreferences.maximumPins)
                            Button {
                                store.markUnread(conversationId: conversation.id)
                            } label: {
                                Label("Mark as Unread", systemImage: "envelope.badge")
                            }
                            if conversation.kind == "group" && conversation.roomSlug == nil {
                                Divider()
                                Button("Delete Group…", role: .destructive) {
                                    deleteTarget = conversation
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        // The grid's height rule reads the list's visible height. Its own
        // content changing never changes this frame, so the rule cannot loop.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            let old = listHeight
            guard abs(old - Double(height)) >= 1 else { return }
            liveListHeight = Double(height)
            // A height that flips the grid's collapse rule is written at once,
            // so a quit inside the debounce cannot relaunch into the wrong
            // state for a frame. Other changes wait for the settle.
            if isGridCollapsed(listHeight: old, availableWidth: availableWidth)
                != isGridCollapsed(listHeight: Double(height), availableWidth: availableWidth) {
                storedListHeight = Double(height)
            }
        }
        .task(id: liveListHeight) {
            guard let height = liveListHeight else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            storedListHeight = height
        }
        .onDisappear {
            if let height = liveListHeight { storedListHeight = height }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 8)
        .alert(
            "Delete “\(deleteTarget?.title ?? "this conversation")”?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { isPresented in if !isPresented { deleteTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    Task { await store.deleteGroup(conversationId: target.id) }
                }
            }
        } message: {
            Text(
                "The chat is frozen and hidden for everyone. History is kept "
                    + "and backed up — nothing is destroyed."
            )
        }
        // The launch selection lands before this List exists (start() races
        // the mount), and onChange only reports changes — seed the mirror so
        // the opened conversation is highlighted from the first frame.
        .onAppear { listSelection = store.selectedConversationId }
        .task(id: store.searchQuery) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            await store.runSearch()
        }
        .safeAreaInset(edge: .bottom) {
            if store.conversations.isEmpty {
                Text("No conversations yet — start one with ⌘N.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
    }
}

private struct ActiveMeetingCard: View {
    let call: Call
    let isCompact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if !isCompact {
                    Image(systemName: "video.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Tokens.Palette.live)
                        .frame(width: 32, height: 32)
                        .background(Tokens.Palette.live.opacity(0.12), in: Circle())
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(call.title ?? "Meeting")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(call.presentParticipants.count) in call")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("Join")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.live)
                    .fixedSize()
                if !isCompact {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.live)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .hqGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                     tint: Tokens.Palette.live.opacity(0.06), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Join \(call.title ?? "Meeting"), \(call.presentParticipants.count) in call")
        .help("Join " + (call.title ?? "Meeting"))
    }
}

// A hit jumps to its conversation; the thread it belongs to is named above the
// matching line so the result reads like Messages' search.
private struct SearchResultRow: View {
    @Environment(AppStore.self) private var store
    let message: Message

    private var conversationName: String {
        guard let conversation = store.conversation(message.conversationId)
        else { return "Conversation" }
        return store.displayName(for: conversation)
    }

    var body: some View {
        Button {
            Task {
                await store.openSearchResult(
                    conversationId: message.conversationId, messageId: message.id
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversationName)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(message.createdDate.formatted(date: .numeric, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(message.senderName): \(store.plainText(message.previewText))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Dropping files on a conversation row stages them as that thread's drafts
// and opens it, the way Messages does. Same AppKit catcher as the chat —
// a dragged screenshot thumbnail is a file promise here too.
struct ConversationDropTarget: ViewModifier {
    @Environment(AppStore.self) private var store
    let conversationId: String
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                FileDropCatcher(isTargeted: $isTargeted) { urls in
                    store.attach(fileURLs: urls, in: conversationId)
                    store.openConversation(conversationId)
                } onImageData: { data, fileName, contentType in
                    store.attach(
                        imageData: data, fileName: fileName, contentType: contentType,
                        in: conversationId
                    )
                    store.openConversation(conversationId)
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.blue, lineWidth: 2)
                }
            }
    }
}

private struct ConversationRow: View, Equatable {
    @Environment(AppStore.self) private var store
    let conversationID: String

    // Everything the row draws comes from its own conversation (read below,
    // so only a write to this one wakes it) and the store's name and preview
    // helpers (which track the roster themselves). Nothing else crosses in.
    static func == (lhs: ConversationRow, rhs: ConversationRow) -> Bool {
        lhs.conversationID == rhs.conversationID
    }

    var body: some View {
        if let conversation = store.conversation(conversationID) {
            row(conversation)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
                .opacity(conversation.unreadCount > 0 ? 1 : 0)
            ClusterAvatarView(conversation: conversation, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.displayName(for: conversation))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer()
                    if let last = conversation.lastMessage {
                        Text(RelativeStamp.list(last.transcriptDate))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                // Two preview lines are always reserved, so every row lands at
                // the same height whether the last message wrapped or not.
                Text(
                    conversation.lastMessage.map { store.plainText($0.previewText) }
                        ?? "No messages yet"
                )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .modifier(ConversationDropTarget(conversationId: conversation.id))
    }
}

// Settings pinned under the list — a gear row when expanded, a bare gear in
// the rail. It selects a destination like any conversation, not a modal.
private struct SettingsFooter: View {
    @Environment(AppStore.self) private var store
    let isRail: Bool

    private var isSelected: Bool { store.destination == .settings }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            // The pill sits beside the gear button, not inside it — a button
            // nested in another button's label never receives the click.
            HStack(spacing: 0) {
                Button {
                    store.destination = .settings
                } label: {
                    Group {
                        if isRail {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape.fill")
                                    .foregroundStyle(isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
                                Text("Settings")
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
    }
}

// The narrow rail: everything stacks vertically like the Messages rail —
// pinned destinations as small circles, then one cluster avatar per
// conversation, selection as the Messages blue rounded square.
private struct CollapsedRailView: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences

    private var conversations: [Conversation] {
        let visible = store.visibleConversations
        return store.pinnedConversations(ids: preferences.pinnedIDs)
            + visible.filter { !preferences.isPinned($0.id) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            // Lazy: the rail's cells are a fixed 56pt, so only the visible
            // ones are built (this is the rail, not the transcript).
            LazyVStack(spacing: 14) {
                DesktopWorkspaceBar(isRail: true)
                    .padding(.top, 4)
                Divider()
                    .padding(.horizontal, 14)
                ForEach(conversations) { conversation in
                    RailCell(conversation: conversation)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

struct RailCell: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    let conversation: Conversation

    private var isSelected: Bool { store.selectedConversationId == conversation.id }

    var body: some View {
        Button {
            store.openConversation(conversation.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(.clear))
                ClusterAvatarView(conversation: conversation)
            }
            .frame(width: 56, height: 56)
            .overlay(alignment: .topLeading) {
                if conversation.unreadCount > 0 {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .offset(x: -2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(store.displayName(for: conversation))
        .modifier(ConversationDropTarget(conversationId: conversation.id))
        .contextMenu {
            Button(preferences.isPinned(conversation.id) ? "Unpin Conversation" : "Pin Conversation",
                   systemImage: preferences.isPinned(conversation.id) ? "pin.slash" : "pin") {
                if preferences.isPinned(conversation.id) { preferences.unpin(conversation.id) }
                else { preferences.pin(conversation.id) }
            }
            .disabled(!preferences.isPinned(conversation.id) && preferences.pinnedIDs.count >= HomePreferences.maximumPins)
            Button {
                store.markUnread(conversationId: conversation.id)
            } label: {
                Label("Mark as Unread", systemImage: "envelope.badge")
            }
        }
    }
}
