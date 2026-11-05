import SwiftUI

/// Messages' To: sheet — pick people, optionally name the group, start.
/// Selection ADDS rather than replaces (as on the Mac), and the suggestions
/// lead with whoever HQ heard from most recently.
struct NewConversationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [Person] = []
    @State private var title = ""
    @State private var query = ""

    private var isGroup: Bool { picked.count > 1 }

    /// Everyone but me, recents first — the order a compose sheet should
    /// offer, not the alphabet.
    private var suggestions: [Person] {
        let recentIds = store.conversations
            .compactMap(\.lastMessage?.senderPersonId)
        var rank: [String: Int] = [:]
        for (index, id) in recentIds.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return store.roster
            .filter { $0.id != store.me?.id && !picked.contains($0) }
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted {
                (rank[$0.id] ?? Int.max, $0.name) < (rank[$1.id] ?? Int.max, $1.name)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tokenField
                    if isGroup {
                        TextField("Group name (optional)", text: $title)
                            .font(Tokens.Typography.row)
                    }
                }
                Section {
                    ForEach(suggestions) { person in
                        Button {
                            picked.append(person)
                            query = ""
                        } label: {
                            HStack(spacing: Tokens.Space.x3) {
                                if person.kind == "bot" {
                                    BotAvatarView(name: person.name, size: 36)
                                } else {
                                    AvatarView(name: person.name, size: 36)
                                }
                                Text(person.name)
                                    .font(Tokens.Typography.row)
                                    .foregroundStyle(Tokens.Palette.ink)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start") { start() }.disabled(picked.isEmpty)
                }
            }
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            if !picked.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Space.x2) {
                        ForEach(picked) { person in
                            Button {
                                picked.removeAll { $0.id == person.id }
                            } label: {
                                HStack(spacing: Tokens.Space.x1) {
                                    Text(person.name)
                                        .font(Tokens.Typography.caption)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .padding(.horizontal, Tokens.Space.x3)
                                .padding(.vertical, Tokens.Space.x1)
                                .background(Tokens.Palette.accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Tokens.Palette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            TextField("To:", text: $query)
                .font(Tokens.Typography.row)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
    }

    private func start() {
        let ids = picked.map(\.id)
        let name = title.trimmingCharacters(in: .whitespaces)
        dismiss()
        Task {
            if ids.count == 1, let only = ids.first {
                await store.startDM(with: only)
            } else {
                await store.createGroup(title: name.isEmpty ? nil : name, personIds: ids)
            }
        }
    }
}
