import SwiftUI

// The Messages compose sheet: a To: field that collects people as accent
// tokens, over a suggestion list ordered by who you actually talk to.
// Clicking a row ADDS it; clicking a picked row removes it; nothing is
// selected until you choose.
struct NewConversationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [Person] = []
    @State private var query = ""
    @State private var title = ""
    @FocusState private var isFieldFocused: Bool

    // People from the most recent conversations first, then the rest of the
    // roster — the sheet opens onto who you actually talk to.
    private var recommended: [Person] {
        AppStore.recommendedRecipients(
            conversations: store.conversations, people: store.people, meId: store.me?.id)
    }

    private var bots: [Person] {
        // One bot is structural: retired identities — the pre-0038
        // domain trio, Meeting Notes — keep person rows for attribution but
        // never reappear in a picker.
        store.people.values
            .filter { store.isAssistant($0) }
            .sorted { $0.name < $1.name }
    }

    private func isMatch(_ person: Person) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || person.name.localizedCaseInsensitiveContains(trimmed)
    }

    private func isSelected(_ person: Person) -> Bool {
        selected.contains { $0.id == person.id }
    }

    private func toggle(_ person: Person) {
        if let index = selected.firstIndex(where: { $0.id == person.id }) {
            selected.remove(at: index)
        } else {
            selected.append(person)
        }
        query = ""
        isFieldFocused = true
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Message")
                .font(Tokens.Typography.sheetTitle)
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.top, Tokens.Space.x4)
                .padding(.bottom, Tokens.Space.x3)
            toField
            RowDivider(inset: 0)
            suggestionList
            RowDivider(inset: 0)
            bottomBar
        }
        .frame(width: 360, height: 440)
        .onAppear { isFieldFocused = true }
    }

    private var toField: some View {
        HStack(spacing: 6) {
            Text("To:")
                .font(Tokens.Typography.row)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Space.x1) {
                    ForEach(selected) { person in
                        Button {
                            toggle(person)
                        } label: {
                            Text(person.name)
                                .font(Tokens.Typography.meta)
                                .foregroundStyle(Tokens.Palette.accent)
                                .padding(.horizontal, Tokens.Space.x2)
                                .padding(.vertical, 3)
                                .background(Tokens.Palette.accent.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(person.name)")
                    }
                }
            }
            .frame(maxWidth: selected.isEmpty ? 0 : nil)
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.row)
                .focused($isFieldFocused)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x2)
    }

    private var suggestionList: some View {
        List {
            let people = recommended.filter(isMatch)
            let matchingBots = bots.filter(isMatch)
            if !people.isEmpty {
                Section {
                    ForEach(people) { person in
                        row(for: person, isBot: false)
                    }
                } header: {
                    Text("People")
                        .font(Tokens.Typography.sectionLabel)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                }
            }
            if !matchingBots.isEmpty {
                Section {
                    ForEach(matchingBots) { bot in
                        row(for: bot, isBot: true)
                    }
                } header: {
                    Text("Bots")
                        .font(Tokens.Typography.sectionLabel)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func row(for person: Person, isBot: Bool) -> some View {
        Button {
            toggle(person)
        } label: {
            HStack(spacing: Tokens.Space.x3) {
                if isBot {
                    BotAvatarView(name: person.name, size: 30)
                } else {
                    AvatarView(name: person.name, size: 30)
                }
                Text(person.name)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer()
                if isSelected(person) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Palette.accent)
                } else if store.onlinePersonIds.contains(person.id) {
                    Circle().fill(Tokens.Palette.live).frame(width: 8, height: 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(spacing: Tokens.Space.x2) {
            if selected.count > 1 {
                TextField("Group name (optional)", text: $title)
                    .textFieldStyle(.plain)
                    .font(Tokens.Typography.row)
                    .padding(.horizontal, Tokens.Space.x3)
                    .padding(.vertical, 8)
                    .background(
                        Tokens.Palette.surfaceHover,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    )
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietCapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(selected.count > 1 ? "Create Group" : "Start Chat") {
                    let ids = selected.map(\.id)
                    let groupTitle = title.trimmingCharacters(in: .whitespaces)
                    Task {
                        if ids.count == 1 {
                            await store.startDM(with: ids[0])
                        } else {
                            await store.createGroup(
                                title: groupTitle.isEmpty ? nil : groupTitle,
                                personIds: ids
                            )
                        }
                        dismiss()
                    }
                }
                .buttonStyle(ActionCapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(Tokens.Space.x4)
    }
}
