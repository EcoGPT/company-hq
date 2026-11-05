import AppKit
import SwiftUI

// Settings → Admin, admins only: the people with access.

// Everyone on the team, their role, and the two verbs an admin has over a
// seat. Removing is freezing: the row survives so every message, task
// and meeting they touched still names them — every transcript reads its
// author out of that row, so destroying it would take their messages with it.
// What the list shows is who is HERE, so a removed member leaves it entirely;
// the undo lives behind one line at the bottom rather than in everyone's way.
// Inviting someone is the list's last row.
struct MembersCard: View {
    @Environment(AppStore.self) private var store
    @State private var isShowingRemoved = false
    @State private var pendingRemoval: Person?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Members")
            VStack(spacing: 0) {
                ForEach(Array(store.roster.enumerated()), id: \.element.id) { index, person in
                    if index > 0 { RowDivider() }
                    row(person)
                }
                if !store.removedMembers.isEmpty {
                    RowDivider()
                    removedDisclosure
                    if isShowingRemoved {
                        ForEach(store.removedMembers) { person in
                            RowDivider()
                            row(person)
                        }
                    }
                }
                RowDivider()
                InviteTeammateRows()
                if let errorText {
                    SettingsErrorRow(text: errorText)
                }
            }
            .hqCard()
            if !store.serviceAccounts.isEmpty { serviceAccounts }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this member") from HQ?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove them", role: .destructive) {
                if let person = pendingRemoval { act { try await store.removeMember(personId: person.id) } }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(
                "Their devices and keys stop working immediately. Everything they "
                    + "wrote stays, and you can put the seat back from here."
            )
        }
    }

    private func row(_ person: Person) -> some View {
        HStack(spacing: Tokens.Space.x3) {
            AvatarView(name: person.name, size: 28, person: person)
                .opacity(person.isRemoved ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.id == store.me?.id ? "\(person.name) (you)" : person.name)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(person.isRemoved ? Tokens.Palette.inkTertiary : Tokens.Palette.ink)
                Text(subtitle(person))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            Spacer()
            // Your own seat is the one an admin cannot touch — it is what
            // stops the company being left with no admin at all.
            if person.id != store.me?.id { menu(person) }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x2)
        .frame(minHeight: Tokens.Layout.rowMinHeight)
    }

    /// The one line the removed get: a count, and a way back. Closed by
    /// default, because the question this card answers is who is here.
    private var removedDisclosure: some View {
        Button {
            isShowingRemoved.toggle()
        } label: {
            HStack(spacing: Tokens.Space.x2) {
                Text(store.removedMembers.count == 1
                    ? "1 removed member"
                    : "\(store.removedMembers.count) removed members")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
                Spacer()
                Text(isShowingRemoved ? "Hide" : "Show")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    /// Machines that hold a bearer, such as a CI job. Listed so
    /// an admin can see they exist, and apart from the people because they are
    /// administered by rotating a secret, not by demoting a teammate.
    private var serviceAccounts: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Service Accounts")
            VStack(spacing: 0) {
                ForEach(Array(store.serviceAccounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { RowDivider() }
                    HStack(spacing: Tokens.Space.x3) {
                        Image(systemName: "gearshape.2")
                            .font(Tokens.Typography.buttonSmall)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .frame(width: 28, height: 28)
                            .background(Tokens.Palette.surfaceHover, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.name)
                                .font(Tokens.Typography.row)
                                .foregroundStyle(Tokens.Palette.ink)
                            Text(account.isAdmin ? "Machine · admin bearer" : "Machine")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.inkTertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Tokens.Space.x4)
                    .padding(.vertical, Tokens.Space.x2)
                    .frame(minHeight: Tokens.Layout.rowMinHeight)
                }
            }
            .hqCard()
            Text("Machines with HQ access. Retire one by rotating its secret.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkTertiary)
                .padding(.horizontal, Tokens.Space.x2)
        }
    }

    private func subtitle(_ person: Person) -> String {
        if let removedAt = person.removedAt {
            return "Removed \(RelativeStamp.day(ISO8601.parse(removedAt)))"
        }
        return person.isAdmin ? "Admin" : "Member"
    }

    private func menu(_ person: Person) -> some View {
        SettingsRowMenu(label: "Actions for \(person.name)") {
            if person.isRemoved {
                Button("Restore to HQ") {
                    act { try await store.restoreMember(personId: person.id) }
                }
            } else {
                Button(person.isAdmin ? "Change to Member" : "Make Admin") {
                    act { try await store.setRole(personId: person.id, isAdmin: !person.isAdmin) }
                }
                Divider()
                Button("Remove from HQ…", role: .destructive) { pendingRemoval = person }
            }
        }
    }

    /// One place for what the hub refused, so a rule the UI cannot express —
    /// "not yourself", a seat already frozen — arrives as words, not silence.
    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                errorText = nil
            } catch let error as APIError {
                errorText = Self.message(for: error.code)
            } catch {
                errorText = "HQ could not apply that change."
            }
        }
    }

    private static func message(for code: String) -> String {
        switch code {
        case "already_removed": "They have already been removed."
        case "forbidden": "Only an admin can change members."
        case "not_removed": "They are already a member."
        case "not_yourself": "You cannot change your own seat."
        case "person_not_found": "HQ no longer has that member."
        case "person_removed": "Restore them before changing their role."
        default: "HQ could not apply that change."
        }
    }
}

// "Invite a Teammate": the server makes a key for the name given here and
// returns it once. The key adds that person's devices for 7 days; the name
// becomes their display name.
private struct InviteTeammateRows: View {
    @Environment(AppStore.self) private var store
    @State private var isOpen = false
    @State private var personName = ""
    /// The key the server returned, shown until the form closes.
    @State private var mintedKey: String?
    @State private var errorText: String?

    var body: some View {
        Group {
            if isOpen {
                form
            } else {
                Button {
                    isOpen = true
                } label: {
                    Label("Invite a Teammate…", systemImage: "plus")
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.accent)
                        .padding(.horizontal, Tokens.Space.x4)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.rowMinHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        // An edited name is no longer the one the key was made for.
        .onChange(of: personName) { mintedKey = nil }
    }

    @ViewBuilder private var form: some View {
        TextField("Teammate's name", text: $personName)
            .textFieldStyle(.plain)
            .font(Tokens.Typography.row)
            .padding(.horizontal, Tokens.Space.x4)
            .frame(minHeight: Tokens.Layout.rowMinHeight)
        if let errorText {
            SettingsErrorRow(text: errorText)
        }
        if let mintedKey {
            RowDivider()
            Text(mintedKey)
                .font(Tokens.Typography.row)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Share this key with them. It adds their devices for 7 days.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.live)
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.bottom, Tokens.Space.x2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        RowDivider()
        HStack(spacing: Tokens.Space.x2) {
            Button(mintedKey == nil ? "Cancel" : "Done") {
                isOpen = false
                errorText = nil
                personName = ""
                mintedKey = nil
            }
            .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
            Spacer()
            if let mintedKey {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mintedKey, forType: .string)
                }
                .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
            } else {
                Button("Create Key") { mint() }
                    .buttonStyle(ActionCapsuleButtonStyle())
                    .disabled(personName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
    }

    private func mint() {
        errorText = nil
        mintedKey = nil
        let name = personName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                mintedKey = try await store.client?.mintKey(personName: name).key
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
