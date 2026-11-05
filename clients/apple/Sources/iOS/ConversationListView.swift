import SwiftUI

/// Personal pins precede the shared recency list. Workspace shortcuts
/// scroll across the top of the list, and unsent drafts keep otherwise empty threads visible.
///
/// Search is Messages' own two-part search, and the same two parts the Mac's
/// sidebar shows: the local title/preview filter narrows the list instantly
/// as the field fills, and a debounced hub search (`AppStore.runSearch`)
/// fills a Messages section underneath it with real hits from every thread.
/// A hit opens its thread and jumps the transcript to the line.
struct ConversationListView: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    @Binding var selection: AppStore.Destination?
    @State private var isComposing = false
    @State private var isEditingPins = false
    @State private var isCustomizingShortcuts = false
    @State private var hasReachedPinLimit = false
    /// The group a swipe asked to delete. Delete hides it for everyone and
    /// has no undo, so the swipe only asks; the dialog below acts.
    @State private var pendingDelete: Conversation?
    @State private var filter = ConversationFilter.all
    @State private var completedSearchQuery = ""

    private enum ConversationFilter: String, CaseIterable {
        case all = "Messages"
        case unread = "Unread"
        case drafts = "Drafts"
    }

    init(selection: Binding<AppStore.Destination?>) {
        _selection = selection
    }

    /// The query lives on the store — the same property the Mac's
    /// search field binds — so `openSearchResult` clearing it empties this
    /// field and drops the list back to its normal shape in one write.
    private var trimmedQuery: String {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// The hub answers two characters and up (`AppStore.runSearch`); below
    /// that the local filter is the whole of search.
    private var isHubSearching: Bool { trimmedQuery.count >= 2 }

    private var rows: [Conversation] {
        let visibleIDs = Set(store.visibleConversations.map(\.id))
        // Which chats hold a draft is one set that changes only when a draft
        // flips between empty and non-empty — a keystroke in an open chat
        // never reaches this list. (The draft TEXT is read below only while a
        // search is typed, and each row reads its own.)
        let draftIDs = store.draftConversationIDs
        let all = store.conversations.filter { conversation in
            let hasDraft = draftIDs.contains(conversation.id)
            guard store.isListable(conversation),
                visibleIDs.contains(conversation.id) || hasDraft || preferences.isPinned(conversation.id) else {
                return false
            }
            return switch filter {
            case .all: true
            case .unread: conversation.unreadCount > 0
            case .drafts: hasDraft
            }
        }
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else { return all }
        return all.filter { conversation in
            store.displayName(for: conversation).localizedCaseInsensitiveContains(trimmed)
                || (conversation.lastMessage?.previewText ?? "")
                    .localizedCaseInsensitiveContains(trimmed)
                || store.draftText(for: conversation.id).localizedCaseInsensitiveContains(trimmed)
                || store.drafts(in: conversation.id).contains {
                    $0.fileName.localizedCaseInsensitiveContains(trimmed)
                }
        }
    }

    var body: some View {
        @Bindable var store = store
        let matching = rows
        let pins = !isSearching && filter == .all
            ? preferences.pinnedIDs.compactMap { id in matching.first { $0.id == id } } : []
        let pinIDs = Set(pins.map(\.id))
        let conversations = matching.filter { !pinIDs.contains($0.id) }
        List(selection: $selection) {
            if !isSearching {
                HomeWorkspaceBar(selection: $selection)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !pins.isEmpty {
                PinnedConversationsView(
                    conversations: pins, selection: $selection, hasReachedPinLimit: $hasReachedPinLimit
                )
                .equatable()
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if isSearching {
                if !conversations.isEmpty {
                    Section("Conversations") {
                        ForEach(conversations) { conversation in
                            conversationRow(conversation, isFirst: conversation.id == conversations.first?.id)
                        }
                    }
                }
                if isHubSearching {
                    Section("Messages") {
                        if completedSearchQuery != trimmedQuery {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Searching…").foregroundStyle(.secondary)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } else if store.searchResults.isEmpty {
                            EmptyStateText("No messages match “\(trimmedQuery)”.")
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(store.searchResults) { message in
                                MessageSearchResultRow(message: message, query: trimmedQuery)
                            }
                        }
                    }
                } else if conversations.isEmpty {
                    EmptyStateText("Nothing here matches “\(trimmedQuery)”.")
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(conversations) { conversation in
                        conversationRow(conversation, isFirst: conversation.id == conversations.first?.id)
                    }
                    if matching.isEmpty {
                        EmptyStateText(emptyMessage)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listSectionSeparator(.hidden, edges: .top)
        .listStyle(.plain)
        .searchable(
            text: $store.searchQuery,
            placement: .automatic,
            prompt: "Search"
        )
        .scrollDismissesKeyboard(.interactively)
        // Debounced by `.task(id:)` itself: every keystroke cancels the
        // previous run mid-sleep, so only the pause after typing reaches the
        // hub. A cancelled sleep must RETURN rather than fall through — that
        // is the difference between one request and one per letter.
        .task(id: trimmedQuery) {
            if isHubSearching {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            await store.runSearch()
            guard !Task.isCancelled else { return }
            completedSearchQuery = trimmedQuery
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .background(Tokens.Palette.messageCanvas)
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { selection = .settings } label: {
                    AvatarView(name: store.me?.name ?? "?", size: 30, person: store.me)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Profile and Settings")
                .accessibilityIdentifier("home-settings")
            }
            ToolbarItem(placement: .topBarTrailing) { workspaceMenu }
            if #available(iOS 26.0, *) {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { composeButton }
            } else {
                ToolbarItem(placement: .bottomBar) { composeButton }
            }
        }
        .sheet(isPresented: $isComposing) {
            NewConversationView().environment(store)
        }
        .sheet(isPresented: $isEditingPins) { HomePinsSheet() }
        .sheet(isPresented: $isCustomizingShortcuts) { HomeShortcutsSheet().environment(store) }
        .alert("Pin limit reached", isPresented: $hasReachedPinLimit) {
            Button("OK", role: .cancel) { }
        } message: { Text("You can pin up to nine conversations. Unpin one to add another.") }
        // On the list, not the row: a dialog attached to a row (its content or a
        // background) never presents once the swipe closes, so it names the chat instead.
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete.map { store.displayName(for: $0) } ?? "")\u{201D}?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { conversation in
            Button("Delete", role: .destructive) {
                Task { await store.deleteGroup(conversationId: conversation.id) }
            }
        } message: { _ in
            Text("This conversation will be hidden for everyone in it.")
        }
        // A row that has gone (deleted elsewhere) takes its pending delete with it.
        .onChange(of: store.conversations.map(\.id)) { _, ids in
            if let pending = pendingDelete, !ids.contains(pending.id) { pendingDelete = nil }
        }
        .refreshable { await store.refresh() }
    }

    private var workspaceMenu: some View {
        Menu {
            Section {
                Menu("Filter messages", systemImage: "line.3.horizontal.decrease") {
                    Picker("Filter messages", selection: $filter) {
                        ForEach(ConversationFilter.allCases, id: \.self) { item in
                            Text(item == .all ? "All Messages" : item.rawValue).tag(item)
                        }
                    }
                }
                Button("Edit Pins", systemImage: "pin") { isEditingPins = true }
                Button("Favorite Shortcuts", systemImage: "slider.horizontal.3") { isCustomizingShortcuts = true }
            }
            if store.activeCall != nil {
                Section {
                    Button("Leave call", role: .destructive) { Task { await store.leaveCall() } }
                }
            }
        } label: {
            Image(systemName: filter == .all ? "ellipsis" : "line.3.horizontal.decrease")
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("Workspace")
        .accessibilityValue(filter == .all ? "All messages" : "Showing \(filter.rawValue)")
    }

    private var emptyMessage: String {
        switch filter {
        case .all: "No conversations yet."
        case .unread: "No unread messages."
        case .drafts: "No drafts."
        }
    }

    private var composeButton: some View {
        Button { isComposing = true } label: {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Tokens.Palette.ink)
        }
        .accessibilityLabel("New conversation")
    }

    @ViewBuilder
    private func conversationRow(_ conversation: Conversation, isFirst: Bool) -> some View {
        // Equatable on the fields the row draws: a read receipt or a change in
        // another conversation re-runs this list's body, but a row whose own
        // inputs are unchanged skips its body. It still observes the store for
        // what it reads (its draft, the roster, the typing state).
        ConversationRow(conversation: conversation)
            .equatable()
            .tag(AppStore.Destination.conversation(conversation.id))
            .listRowInsets(EdgeInsets(
                top: 12, leading: 9, bottom: 12, trailing: 16
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(isFirst ? .hidden : .visible, edges: .top)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                unreadButton(conversation)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteButton(conversation)
            }
            .contextMenu {
                ConversationMenuItems(conversation: conversation, hasReachedPinLimit: $hasReachedPinLimit)
            }
    }

    @ViewBuilder
    private func unreadButton(_ conversation: Conversation) -> some View {
        Button {
            store.markUnread(conversationId: conversation.id)
        } label: {
            Label("Unread", systemImage: "envelope.badge")
        }
        .tint(Tokens.Palette.accent)
    }

    /// Delete is freeze-and-hide and only groups can be left, so a DM
    /// and the standing rooms offer nothing to swipe away. It never runs from
    /// the swipe itself: no full swipe, and the button only raises the dialog.
    @ViewBuilder
    private func deleteButton(_ conversation: Conversation) -> some View {
        if conversation.kind == "group", !conversation.isStandingRoom {
            Button(role: .destructive) {
                pendingDelete = conversation
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// One hub search hit, read the way Messages reads one: the thread it belongs
/// to is named above the matching line, with the day on the trailing edge.
/// Tapping opens the thread and jumps the transcript to the message — the
/// same `openSearchResult` the Mac's sidebar calls.
private struct MessageSearchResultRow: View {
    @Environment(AppStore.self) private var store
    let message: Message
    let query: String

    private var conversation: Conversation? {
        store.conversation(message.conversationId)
    }

    private var threadName: String {
        conversation.map { store.displayName(for: $0) } ?? "Conversation"
    }

    private var line: String {
        let fullText = store.plainText(message.previewText)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let body: String
        if let match = fullText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]),
           fullText.distance(from: fullText.startIndex, to: match.lowerBound) > 60 {
            let start = fullText.index(match.lowerBound, offsetBy: -30)
            body = "…" + fullText[start...]
        } else {
            body = fullText
        }
        guard !message.isSystem, !body.isEmpty else { return body }
        let who = message.senderPersonId == store.me?.id ? "You" : message.senderName
        return "\(who): \(body)"
    }

    var body: some View {
        Button {
            Task {
                await store.openSearchResult(
                    conversationId: message.conversationId, messageId: message.id
                )
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if let conversation {
                    ClusterAvatarView(conversation: conversation, size: 46)
                } else {
                    AvatarView(name: message.senderName, size: 46)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.x2) {
                        Text(threadName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Tokens.Palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(RelativeStamp.list(message.transcriptDate))
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                    }
                    Text(highlightedLine)
                        .font(.subheadline)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(
            top: 12, leading: 27, bottom: 12, trailing: 16
        ))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("home-search-result-\(message.id)")
    }

    private var highlightedLine: AttributedString {
        var text = AttributedString(line)
        var remaining = text.startIndex..<text.endIndex
        while let range = text[remaining].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .subheadline.weight(.semibold)
            text[range].foregroundColor = Tokens.Palette.ink
            remaining = range.upperBound..<text.endIndex
        }
        return text
    }
}

/// One thread, laid out the way Messages lays one out: unread dot in the
/// leading gutter, the cluster avatar, two lines of name-and-preview, and
/// the time on the trailing edge.
private struct ConversationRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let conversation: Conversation

    private var isUnread: Bool { conversation.unreadCount > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(isUnread ? Tokens.Palette.accent : .clear)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            ClusterAvatarView(conversation: conversation, size: 46)

            VStack(alignment: .leading, spacing: 2) {
                if dynamicTypeSize.isAccessibilitySize {
                    title.lineLimit(2)
                    timestamp
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        title.lineLimit(1)
                        timestamp
                    }
                }
                previewLabel
                    .font(.subheadline)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }
        }
        .contentShape(Rectangle())
    }

    private var title: some View {
        Text(store.displayName(for: conversation))
            .font(.body.weight(.semibold))
            .foregroundStyle(Tokens.Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timestamp: some View {
        HStack(spacing: 6) {
            Text(timeLabel)
                .font(.subheadline)
                .foregroundStyle(Tokens.Palette.inkTertiary)
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tokens.Palette.inkTertiary.opacity(0.6))
                .accessibilityHidden(true)
        }
    }

    private var previewLabel: Text {
        // This conversation's own draft: a keystroke in another chat does not
        // re-render this row.
        let draft = store.draftText(for: conversation.id).trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            return Text("\(Text("Draft:").foregroundStyle(Tokens.Palette.danger)) \(draft)")
        }
        let attachments = store.drafts(in: conversation.id)
        if let first = attachments.first {
            let summary = attachments.count == 1 ? first.fileName : "\(attachments.count) attachments"
            return Text("\(Text("Draft:").foregroundStyle(Tokens.Palette.danger)) \(summary)")
        }
        return Text(preview)
    }

    private var preview: String {
        guard let message = conversation.lastMessage else { return "No messages yet" }
        // A group says who spoke, the way Messages does; a DM does not need to.
        let isGroup = conversation.kind == "group"
        let body = store.plainText(message.previewText).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard isGroup, !message.isSystem, !body.isEmpty else { return body }
        let who = message.senderPersonId == store.me?.id ? "You" : message.senderName
        return "\(who): \(body)"
    }

    private var timeLabel: String {
        guard let created = conversation.lastMessage?.transcriptDate else { return "" }
        return RelativeStamp.list(created)
    }
}

/// Pin, unpin, reorder, mark unread: the actions a conversation
/// offers from its long press and from a pinned avatar. A view of its own, so
/// the pinned grid carries no closure for SwiftUI to fail to compare; it reads
/// the preferences and the store itself.
struct ConversationMenuItems: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    let conversation: Conversation
    @Binding var hasReachedPinLimit: Bool

    var body: some View {
        let isPinned = preferences.isPinned(conversation.id)
        Button {
            if isPinned { preferences.unpin(conversation.id) }
            else if !preferences.pin(conversation.id) { hasReachedPinLimit = true }
        } label: {
            Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
        }
        if isPinned {
            Button("Move earlier", systemImage: "arrow.left") { preferences.movePin(conversation.id, by: -1) }
                .disabled(preferences.pinnedIDs.first == conversation.id)
            Button("Move later", systemImage: "arrow.right") { preferences.movePin(conversation.id, by: 1) }
                .disabled(preferences.pinnedIDs.last == conversation.id)
        }
        Button {
            store.markUnread(conversationId: conversation.id)
        } label: {
            Label("Mark as Unread", systemImage: "envelope.badge")
        }
    }
}

extension Conversation {
    /// What a home-list row or a pinned avatar draws. `readMarks` and `createdAt`
    /// are not drawn, so a read receipt compares equal.
    func hasSameHomeAppearance(as other: Conversation) -> Bool {
        id == other.id && kind == other.kind && title == other.title
            && memberIds == other.memberIds && lastMessage == other.lastMessage
            && unreadCount == other.unreadCount && roomSlug == other.roomSlug
            && avatarId == other.avatarId
    }
}

/// Compared on the conversation's drawn fields (see `hasSameHomeAppearance`).
extension ConversationRow: Equatable {
    static func == (lhs: ConversationRow, rhs: ConversationRow) -> Bool {
        lhs.conversation.hasSameHomeAppearance(as: rhs.conversation)
    }
}
