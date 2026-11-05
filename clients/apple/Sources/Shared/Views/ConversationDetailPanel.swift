import SwiftUI

// The Codex-style trailing panel: conversation details now; files, meeting
// cards, and transcripts hang off this surface in later waves.
struct ConversationDetailPanel: View {
    @Environment(AppStore.self) private var store
    let conversationId: String
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isAddingPeople = false
    @State private var isGreenRoomOpen = false
    @State private var isPickingPhoto = false

    private var conversation: Conversation? {
        store.conversation(conversationId)
    }

    private var members: [Person] {
        conversation.map { store.conversationMembers(of: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(spacing: 6) {
                            ClusterAvatarView(conversation: conversation, size: 64)
                            Text(store.displayName(for: conversation))
                                .font(Tokens.Typography.sheetTitle)
                                .foregroundStyle(Tokens.Palette.ink)
                            Text(subtitle(for: conversation))
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.inkSecondary)
                            Button {
                                isGreenRoomOpen = true
                            } label: {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Tokens.Palette.accent)
                                    .frame(width: 44, height: 44)
                                    .background(Tokens.Palette.surfaceInput, in: Circle())
                                    .overlay(Circle().strokeBorder(Tokens.Palette.borderLight, lineWidth: 1))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(store.activeCallId != nil)
                            .help(store.liveCall(inConversation: conversationId) == nil
                                ? "Start a call" : "Join the call in this conversation")
                            .padding(.top, Tokens.Space.x2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        if conversation.kind == "group" && !conversation.isStandingRoom {
                            groupActions(for: conversation)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Members")
                                .padding(.horizontal, Tokens.Space.x2)
                                .padding(.bottom, Tokens.Space.x1)
                            ForEach(members) { person in
                                HStack(spacing: Tokens.Space.x3) {
                                    ZStack(alignment: .bottomTrailing) {
                                        if person.kind == "bot" {
                                            BotAvatarView(name: person.name, size: 28)
                                        } else {
                                            AvatarView(name: person.name, size: 28)
                                        }
                                        if store.onlinePersonIds.contains(person.id) {
                                            Circle()
                                                .fill(Tokens.Palette.live)
                                                .frame(width: 8, height: 8)
                                                .overlay(Circle().stroke(Tokens.Palette.surface, lineWidth: 1.5))
                                        }
                                    }
                                    Text(person.name)
                                        .font(Tokens.Typography.row)
                                        .foregroundStyle(Tokens.Palette.ink)
                                    if person.isAdmin {
                                        Text("admin")
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.inkSecondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Tokens.Palette.surfaceHover, in: Capsule())
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, Tokens.Space.x4)
                                .padding(.vertical, Tokens.Space.x1)
                            }
                        }
                    }
                }
                .padding(.top, Tokens.Home.desktopHeaderHeight)
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.Palette.surface)
        .sheet(isPresented: $isGreenRoomOpen) {
            GreenRoomView(
                title: conversation.map { store.displayName(for: $0) } ?? "Call",
                kind: "conversation",
                conversationId: conversationId
            )
        }
    }

    @ViewBuilder
    private func groupActions(for conversation: Conversation) -> some View {
        VStack(spacing: Tokens.Space.x2) {
            if isRenaming {
                HStack(spacing: Tokens.Space.x2) {
                    TextField("Group name", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(Tokens.Typography.row)
                        .padding(.horizontal, Tokens.Space.x3)
                        .padding(.vertical, 7)
                        .background(
                            Tokens.Palette.surfaceInput,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                        )
                    Button("Save") {
                        let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
                        Task {
                            await store.rename(
                                conversationId: conversationId,
                                title: trimmed.isEmpty ? nil : trimmed
                            )
                        }
                        isRenaming = false
                    }
                    .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                panelAction("Rename group") {
                    draftTitle = conversation.title ?? ""
                    isRenaming = true
                }
            }
            panelAction(conversation.avatarId == nil ? "Add group photo" : "Change group photo") {
                isPickingPhoto = true
            }
            if conversation.avatarId != nil {
                panelAction("Remove group photo") {
                    Task { await store.clearConversationImage(conversationId: conversationId) }
                }
            }
            panelAction("Add people") { isAddingPeople = true }
            panelAction("Leave conversation", ink: Tokens.Palette.danger) {
                Task { await store.leave(conversationId: conversationId) }
                store.isDetailPanelOpen = false
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.bottom, Tokens.Space.x3)
        .sheet(isPresented: $isAddingPeople) {
            AddPeopleSheet(conversationId: conversationId, existing: Set(conversation.memberIds))
        }
        .fileImporter(isPresented: $isPickingPhoto, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                await store.setConversationImage(conversationId: conversationId, imageData: data)
            }
        }
    }

    /// The panel's inline actions: quiet text links in the accent ink,
    /// danger for the destructive one.
    private func panelAction(
        _ title: String, ink: Color = Tokens.Palette.accent, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.row)
                .foregroundStyle(ink)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for conversation: Conversation) -> String {
        if conversation.kind == "group" {
            return "\(members.count) people"
        }
        return store.isOnline(conversation) ? "Online" : "Direct message"
    }
}

// Adding people to an existing group — the members list, minus who is already
// in it.
private struct AddPeopleSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversationId: String
    let existing: Set<String>
    @State private var selected: Set<String> = []

    private var candidates: [Person] {
        store.roster.filter { !existing.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add People")
                .font(Tokens.Typography.sheetTitle)
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.top, Tokens.Space.x4)
            if candidates.isEmpty {
                EmptyStateText("Everyone is already here.")
                    .frame(minHeight: 120)
            } else {
                List(candidates, selection: $selected) { person in
                    HStack(spacing: Tokens.Space.x3) {
                        AvatarView(name: person.name, size: 26)
                        Text(person.name)
                            .font(Tokens.Typography.row)
                    }
                    .tag(person.id)
                }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietCapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    Task {
                        await store.addMembers(conversationId: conversationId, personIds: Array(selected))
                        dismiss()
                    }
                }
                .buttonStyle(ActionCapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(Tokens.Space.x4)
        }
        .frame(width: 320)
    }
}
