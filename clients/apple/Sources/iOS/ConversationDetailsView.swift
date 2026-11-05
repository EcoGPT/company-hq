import PhotosUI
import SwiftUI

/// Messages' Info screen: the thread's face and name, the call button, Hide
/// Alerts, the members, and — for a group nobody standing needs — rename,
/// add people, leave, delete. Same affordances as the Mac's details panel,
/// laid out as a phone's grouped sheet.
struct ConversationDetailsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation

    @State private var isGreenRoomUp = false
    @State private var isRenaming = false
    @State private var isAddingMembers = false
    @State private var renameDraft = ""
    @State private var isLeaveConfirmUp = false
    @State private var isDeleteConfirmUp = false
    @State private var photoPick: PhotosPickerItem?

    /// The sheet is handed a conversation by value, so the row that opened it
    /// is a snapshot — a new group photo or surface would not show until it
    /// was closed and opened again. Everything that can change while this is
    /// on screen reads the store's copy instead.
    private var live: Conversation {
        store.conversation(conversation.id) ?? conversation
    }

    private var members: [Person] {
        store.conversationMembers(of: live)
            .sorted { ($0.kind == "bot" ? 1 : 0, $0.name) < ($1.kind == "bot" ? 1 : 0, $1.name) }
    }

    private var isManageable: Bool {
        live.kind == "group" && !live.isStandingRoom
    }

    private var liveCall: Call? { store.liveCall(inConversation: conversation.id) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: Tokens.Space.x2) {
                        ClusterAvatarView(conversation: live, size: 84)
                        Text(store.displayName(for: live))
                            .font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(subtitle)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                        callButton
                            .padding(.top, Tokens.Space.x2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Space.x4)
                    .listRowBackground(Color.clear)
                }

                Section("\(members.count) People") {
                    ForEach(members) { person in
                        memberRow(person)
                    }
                    if isManageable {
                        Button {
                            isAddingMembers = true
                        } label: {
                            Label("Add People", systemImage: "person.badge.plus")
                                .font(Tokens.Typography.row)
                        }
                    }
                }

                if isManageable {
                    Section {
                        Button {
                            renameDraft = live.title ?? ""
                            isRenaming = true
                        } label: {
                            Label("Change Name", systemImage: "pencil")
                                .font(Tokens.Typography.row)
                        }
                        // The Mac's file importer, as the phone's library
                        // picker. The square crop and 512px cap are the store's
                        // (AvatarImagePrep), so both clients send the same bytes.
                        PhotosPicker(
                            selection: $photoPick, matching: .images, photoLibrary: .shared()
                        ) {
                            Label(
                                live.avatarId == nil ? "Add Group Photo" : "Change Group Photo",
                                systemImage: "photo"
                            )
                            .font(Tokens.Typography.row)
                        }
                        if live.avatarId != nil {
                            Button {
                                Task {
                                    await store.clearConversationImage(
                                        conversationId: conversation.id
                                    )
                                }
                            } label: {
                                Label("Remove Group Photo", systemImage: "xmark.circle")
                                    .font(Tokens.Typography.row)
                            }
                        }
                        Button(role: .destructive) {
                            isLeaveConfirmUp = true
                        } label: {
                            Label("Leave this Conversation", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(Tokens.Typography.row)
                        }
                        Button(role: .destructive) {
                            isDeleteConfirmUp = true
                        } label: {
                            Label("Delete Conversation", systemImage: "trash")
                                .font(Tokens.Typography.row)
                        }
                    } footer: {
                        Text("Deleting hides the thread for everyone. Nothing is destroyed — HQ keeps the history.")
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .onChange(of: photoPick) { _, pick in
            guard let pick else { return }
            Task {
                defer { photoPick = nil }
                guard let data = try? await pick.loadTransferable(type: Data.self) else { return }
                await store.setConversationImage(
                    conversationId: conversation.id, imageData: data
                )
            }
        }
        .sheet(isPresented: $isGreenRoomUp) {
            GreenRoomView(conversationId: conversation.id, meetingId: nil)
                .environment(store)
        }
        // The call stage is presented from the root, which sits BELOW this
        // sheet — leaving details open would bury it. Joining closes the
        // whole details stack on the way to the room.
        .onChange(of: store.activeCallId) { _, callId in
            if callId != nil { dismiss() }
        }
        .sheet(isPresented: $isAddingMembers) {
            AddMembersView(conversation: live).environment(store)
        }
        .alert("Change Name", isPresented: $isRenaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                Task {
                    await store.rename(
                        conversationId: conversation.id, title: trimmed.isEmpty ? nil : trimmed
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "You will stop receiving messages from this conversation.",
            isPresented: $isLeaveConfirmUp, titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task {
                    await store.leave(conversationId: conversation.id)
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "This conversation will be hidden for everyone in it.",
            isPresented: $isDeleteConfirmUp, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.deleteGroup(conversationId: conversation.id)
                    dismiss()
                }
            }
        }
    }

    private var callButton: some View {
        Button { isGreenRoomUp = true } label: {
            VStack(spacing: Tokens.Space.x1) {
                Image(systemName: "video.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(liveCall == nil ? Tokens.Palette.accent : Tokens.Palette.live)
                    .frame(width: 52, height: 52)
                    .hqGlass(in: Circle(), interactive: true)
                    .contentShape(Circle())
                Text(liveCall == nil ? "Call" : "Join")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(store.activeCallId != nil)
    }

    private var subtitle: String {
        if live.kind == "dm" {
            return store.isOnline(live) ? "Active now" : "Direct message"
        }
        return "\(members.count) people"
    }

    private func memberRow(_ person: Person) -> some View {
        HStack(spacing: Tokens.Space.x3) {
            if person.kind == "bot" {
                BotAvatarView(name: person.name, size: 36)
            } else {
                AvatarView(name: person.name, size: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(person.id == store.me?.id ? "\(person.name) (You)" : person.name)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.ink)
                if person.kind == "bot" {
                    Text("Bot")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                } else if store.onlinePersonIds.contains(person.id) {
                    Text("Active now")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.live)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Adding to a group: the roster, minus who is already in it.
private struct AddMembersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var picked: Set<String> = []

    private var candidates: [Person] {
        store.roster.filter { !conversation.memberIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { person in
                Button {
                    if picked.contains(person.id) {
                        picked.remove(person.id)
                    } else {
                        picked.insert(person.id)
                    }
                } label: {
                    HStack(spacing: Tokens.Space.x3) {
                        AvatarView(name: person.name, size: 34)
                        Text(person.name)
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer(minLength: 0)
                        if picked.contains(person.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Tokens.Palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        Task {
                            await store.addMembers(
                                conversationId: conversation.id, personIds: Array(picked)
                            )
                            dismiss()
                        }
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}
