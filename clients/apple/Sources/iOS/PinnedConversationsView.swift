import SwiftUI

struct PinnedConversationsView: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    let conversations: [Conversation]
    @Binding var selection: AppStore.Destination?
    /// Raised by the menu's Pin action when all nine slots are taken.
    @Binding var hasReachedPinLimit: Bool

    private var columnCount: Int { dynamicTypeSize.isAccessibilitySize ? 1 : 3 }

    var body: some View {
        // There are at most nine pins. Eager rows keep List's self-sizing stable
        // while NavigationSplitView changes column widths during rotation.
        VStack(spacing: 18) {
            ForEach(Array(stride(from: 0, to: conversations.count, by: columnCount)), id: \.self) { start in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(conversations[start..<min(start + columnCount, conversations.count)])) { conversation in
                        pin(conversation).frame(maxWidth: .infinity)
                    }
                    ForEach(0..<max(0, start + columnCount - conversations.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned conversations")
        .padding(.vertical, 12)
        .animation(shouldReduceMotion ? nil : .snappy(duration: 0.25), value: preferences.pinnedIDs)
    }

    private func pin(_ conversation: Conversation) -> some View {
        Menu {
            ConversationMenuItems(conversation: conversation, hasReachedPinLimit: $hasReachedPinLimit)
        } label: {
            VStack(spacing: 8) {
                ClusterAvatarView(conversation: conversation, size: Tokens.Home.pinDiameter)
                    .overlay(alignment: .topTrailing) {
                        if conversation.unreadCount > 0 {
                            Circle().fill(Tokens.Palette.accent).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.background, lineWidth: 2))
                        }
                    }
                Text(store.displayName(for: conversation))
                    .font(.subheadline).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        } primaryAction: {
            selection = .conversation(conversation.id)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.displayName(for: conversation))
        .accessibilityValue(conversation.unreadCount > 0 ? "Pinned, unread messages" : "Pinned")
        .accessibilityIdentifier("pinned-chat-\(conversation.id)")
        .accessibilityAction(named: "Move earlier") { preferences.movePin(conversation.id, by: -1) }
        .accessibilityAction(named: "Move later") { preferences.movePin(conversation.id, by: 1) }
        .accessibilityAction(named: "Unpin") { preferences.unpin(conversation.id) }
    }
}

/// Compared on the pinned conversations' drawn fields. The bindings are
/// rebuilt on every list pass but point at the same state; what the grid reads
/// from the store and the preferences still invalidates it by observation.
extension PinnedConversationsView: Equatable {
    static func == (lhs: PinnedConversationsView, rhs: PinnedConversationsView) -> Bool {
        lhs.conversations.count == rhs.conversations.count
            && zip(lhs.conversations, rhs.conversations).allSatisfy { $0.hasSameHomeAppearance(as: $1) }
    }
}

struct HomePinsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var conversations: [Conversation] { store.conversations }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(preferences.pinnedIDs, id: \.self) { id in
                        let conversation = conversations.first { $0.id == id }
                        HStack {
                            if let conversation { ClusterAvatarView(conversation: conversation, size: 36) }
                            Text(conversation.map { store.displayName(for: $0) } ?? "Unavailable conversation")
                                .lineLimit(2)
                        }
                        .accessibilityIdentifier("edit-pin-\(id)")
                    }
                    .onDelete { indexes in
                        let ids = indexes.map { preferences.pinnedIDs[$0] }
                        for id in ids { preferences.unpin(id) }
                    }
                    .onMove { source, destination in
                        var ids = preferences.pinnedIDs
                        ids.move(fromOffsets: source, toOffset: destination)
                        preferences.setPinOrder(ids)
                    }
                } header: { Text("Pinned") } footer: {
                    Text("Pin up to nine conversations. Drag the handles to change their order.")
                }
                Section("Pin a conversation") {
                    ForEach(conversations.filter {
                        !preferences.isPinned($0.id)
                            && (query.isEmpty || store.displayName(for: $0).localizedCaseInsensitiveContains(query))
                    }) { conversation in
                        Button { preferences.pin(conversation.id) } label: {
                            HStack(spacing: 12) {
                                ClusterAvatarView(conversation: conversation, size: 36)
                                Text(store.displayName(for: conversation)).foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Image(systemName: "pin").foregroundStyle(Tokens.Palette.accent)
                            }
                        }
                        .accessibilityIdentifier("add-pin-\(conversation.id)")
                        .disabled(preferences.pinnedIDs.count >= HomePreferences.maximumPins)
                    }
                }
                .deleteDisabled(true)
                .moveDisabled(true)
            }
            .searchable(text: $query, prompt: "Find a conversation")
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Pins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}


