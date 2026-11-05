import PhotosUI
import SwiftUI
import UIKit

/// Account, this device's notification standing, and — for an admin — the
/// team's members and key minting.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var isSignOutConfirmUp = false

    private var isAdmin: Bool { store.me?.isAdmin ?? false }

    var body: some View {
        List {
            ProfileSection()

            if let problem = store.sessionPersistenceProblem {
                Section {
                    Label {
                        Text("Signed in for this session only — \(problem).")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Tokens.Palette.warning)
                    }
                }
            }

            ThisDeviceSection()

            McpKeysSection()

            if isAdmin {
                MembersSection()
                ServiceAccountsSection()
                MintKeySection()
            }

            Section {
                Button("Sign Out") { isSignOutConfirmUp = true }
                    .font(Tokens.Typography.row)
            } footer: {
                Text("HQ \(HQBuildInfo.hash) · \(HQConfig.baseURLString)")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of HQ on this \(Platform.deviceKind)?",
            isPresented: $isSignOutConfirmUp, titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { store.signOut() }
        }
    }
}

private struct ProfileSection: View {
    @Environment(AppStore.self) private var store
    @State private var avatarPick: PhotosPickerItem?
    private var isAdmin: Bool { store.me?.isAdmin ?? false }

    var body: some View {
        Section("Account") {
            HStack(spacing: Tokens.Space.x3) {
                AvatarView(name: store.me?.name ?? "?", size: 46, person: store.me)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.me?.name ?? "Signed in")
                        .font(Tokens.Typography.rowEmphasis)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text(isAdmin ? "Admin" : "Team member")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                }
            }
            .padding(.vertical, Tokens.Space.x1)
            // The Mac's Account card as a phone row: the photo library
            // rather than a file importer, and the same center crop and
            // 512px cap on the way up — AvatarImagePrep, inside the store,
            // so both clients send identical bytes.
            PhotosPicker(
                selection: $avatarPick, matching: .images, photoLibrary: .shared()
            ) {
                Label(
                    store.me?.avatarId == nil ? "Add Photo" : "Change Photo",
                    systemImage: "person.crop.circle"
                )
                .font(Tokens.Typography.row)
            }
            if store.me?.avatarId != nil {
                Button(role: .destructive) {
                    Task { await store.clearMyAvatar() }
                } label: {
                    Label("Remove Photo", systemImage: "person.crop.circle.badge.xmark")
                        .font(Tokens.Typography.row)
                }
            }
        }
        .onChange(of: avatarPick) { _, pick in
            guard let pick else { return }
            Task {
                defer { avatarPick = nil }
                guard let data = try? await pick.loadTransferable(type: Data.self) else {
                    return
                }
                await store.setMyAvatar(imageData: data)
            }
        }
    }
}

/// What this phone can actually do with a notification, said out loud. The
/// one cause it cannot see is Focus, so the healthy row names it rather than
/// leaving someone to wonder.
private struct ThisDeviceSection: View {
    @State private var notifications = NotificationManager.shared.state
    @AppStorage(LinkPreviewSetting.key) private var showsLinkPreviews = true

    private var isHealthy: Bool { notifications.isPermitted && notifications.areAlertsEnabled }

    var body: some View {
        Section("This \(Platform.deviceKind)") {
            VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                HStack(spacing: Tokens.Space.x2) {
                    Circle()
                        .fill(isHealthy ? Tokens.Palette.live : Tokens.Palette.danger)
                        .frame(width: 8, height: 8)
                    Text("Notifications")
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.ink)
                    Spacer(minLength: 0)
                }
                Text(notifications.summary)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isHealthy {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                    .font(Tokens.Typography.buttonSmall)
                    .padding(.top, Tokens.Space.x1)
                }
            }
            .padding(.vertical, Tokens.Space.x1)
            Toggle(isOn: $showsLinkPreviews) {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    Text("Show link previews")
                        .font(Tokens.Typography.row)
                    Text("This \(Platform.deviceKind) fetches the page behind a link someone sends you.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                }
            }
        }
        .task {
            await NotificationManager.shared.refresh()
            notifications = NotificationManager.shared.state
        }
    }
}

/// The person's `hq_mcp_v1` keys: what a Claude Code session authenticates
/// with. A new key shows exactly once, here, with the setup command.
private struct McpKeysSection: View {
    @Environment(AppStore.self) private var store
    @State private var keys: [HQClient.McpKeySummary]?
    @State private var label = ""
    @State private var minted: HQClient.MintedMcpKey?
    @State private var errorText: String?
    @State private var pendingRevoke: HQClient.McpKeySummary?

    var body: some View {
        Section {
            ForEach((keys ?? []).filter { $0.revokedAt == nil }) { key in
                HStack(spacing: Tokens.Space.x3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.label)
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(key.scopes.split(whereSeparator: { $0 == "," || $0 == " " }).joined(separator: ", "))
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                    }
                    Spacer(minLength: 0)
                    Button("Revoke", role: .destructive) { pendingRevoke = key }
                        .font(Tokens.Typography.buttonSmall)
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Name, like Work laptop", text: $label)
                    .font(Tokens.Typography.row)
                Button("Create") { mint() }
                    .font(Tokens.Typography.buttonSmall)
                    .buttonStyle(.borderless)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let minted {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    Text("Copy the setup now — the key never shows again.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.warning)
                    Button("Copy Claude Code Setup") {
                        Platform.copyToClipboard(
                            "claude mcp add --scope user --transport http hq " + HQConfig.baseURLString + "/mcp"
                                + " --header \"Authorization: Bearer " + minted.key + "\"")
                    }
                    .font(Tokens.Typography.buttonSmall)
                    .buttonStyle(.borderless)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.danger)
            }
        } header: {
            Text("Claude Code Keys")
        }
        .task { await load() }
        .confirmationDialog(
            "Revoke \(pendingRevoke?.label ?? "this key")?",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let key = pendingRevoke { revoke(key) }
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: {
            Text("Any Claude Code session using it stops reaching HQ. This can't be undone.")
        }
    }

    private func load() async {
        guard let client = store.client else { return }
        do {
            keys = try await client.mcpKeys()
            errorText = nil
        } catch { errorText = "The keys could not be loaded." }
    }

    private func mint() {
        Task {
            do {
                minted = try await store.client?.createMcpKey(label: label.trimmingCharacters(in: .whitespaces))
                label = ""
                errorText = nil
                await load()
            } catch { errorText = "The key could not be created. Try again." }
        }
    }

    private func revoke(_ key: HQClient.McpKeySummary) {
        Task {
            do {
                try await store.client?.revokeMcpKey(id: key.id)
                errorText = nil
            } catch { errorText = "The key could not be revoked. Try again." }
            await load()
        }
    }
}

/// Everyone on the team, their role, and the two verbs an admin has over a
/// seat — the phone's half of the Mac's Members card. Removing is freezing:
/// the row survives because every transcript reads its author out of it, so
/// destroying it would take their messages with it. The list answers who is
/// HERE, so a removed member leaves it and the undo sits behind one line at
/// the bottom.
private struct MembersSection: View {
    @Environment(AppStore.self) private var store
    @State private var isShowingRemoved = false
    @State private var pendingRemoval: Person?
    @State private var errorText: String?

    var body: some View {
        Section {
            ForEach(isShowingRemoved ? store.roster + store.removedMembers : store.roster) { person in
                HStack(spacing: Tokens.Space.x3) {
                    AvatarView(name: person.name, size: 30, person: person)
                        .opacity(person.isRemoved ? 0.45 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.id == store.me?.id ? "\(person.name) (you)" : person.name)
                            .font(Tokens.Typography.row)
                            .foregroundStyle(
                                person.isRemoved ? Tokens.Palette.inkTertiary : Tokens.Palette.ink
                            )
                        Text(subtitle(person))
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                    }
                    Spacer(minLength: 0)
                    // Your own seat is the one an admin cannot touch — it is
                    // what stops the team being left with no admin at all.
                    if person.id != store.me?.id { menu(person) }
                }
            }
            if !store.removedMembers.isEmpty {
                Button {
                    isShowingRemoved.toggle()
                } label: {
                    HStack {
                        Text(store.removedMembers.count == 1
                            ? "1 removed member"
                            : "\(store.removedMembers.count) removed members")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                        Spacer(minLength: 0)
                        Text(isShowingRemoved ? "Hide" : "Show")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.accent)
                    }
                }
                .buttonStyle(.plain)
            }
            if let errorText {
                Text(errorText)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.danger)
            }
        } header: {
            Text("Members")
        } footer: {
            Text("Removing someone ends their access immediately. Everything they wrote stays, and the seat can be restored here.")
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this member") from HQ?",
            isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove them", role: .destructive) {
                if let person = pendingRemoval {
                    act { try await store.removeMember(personId: person.id) }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Their devices and keys stop working immediately.")
        }
    }

    private func subtitle(_ person: Person) -> String {
        if let removedAt = person.removedAt {
            return "Removed \(RelativeStamp.day(ISO8601.parse(removedAt)))"
        }
        return person.isAdmin ? "Admin" : "Member"
    }

    private func menu(_ person: Person) -> some View {
        Menu {
            if person.isRemoved {
                Button("Restore to HQ") {
                    act { try await store.restoreMember(personId: person.id) }
                }
            } else {
                Button(person.isAdmin ? "Change to Member" : "Make Admin") {
                    act { try await store.setRole(personId: person.id, isAdmin: !person.isAdmin) }
                }
                Button("Remove from HQ…", role: .destructive) { pendingRemoval = person }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Tokens.Typography.buttonSmall)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }
    }

    /// One place for what the server refused, so a rule the UI cannot express
    /// arrives as words rather than as nothing happening.
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

/// Machines that hold a bearer, such as a CI job. Listed so an
/// admin can see they exist, and apart from the people because they are
/// retired by rotating a secret, not by demoting a teammate.
private struct ServiceAccountsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if !store.serviceAccounts.isEmpty {
            Section {
                ForEach(store.serviceAccounts) { account in
                    HStack(spacing: Tokens.Space.x3) {
                        Image(systemName: "gearshape.2")
                            .font(Tokens.Typography.buttonSmall)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.name)
                                .font(Tokens.Typography.row)
                                .foregroundStyle(Tokens.Palette.ink)
                            Text(account.isAdmin ? "Machine · admin bearer" : "Machine")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.inkTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } header: {
                Text("Service Accounts")
            } footer: {
                Text("Not people — machines holding a bearer. Retire one by rotating its secret and revoking its device, never from here.")
            }
        }
    }
}

/// Inviting a teammate from a phone: the server makes the key and returns it once.
private struct MintKeySection: View {
    @Environment(AppStore.self) private var store
    @State private var personName = ""
    @State private var mintedKey: String?
    @State private var isWorking = false
    @State private var errorText: String?

    private var canMint: Bool {
        !personName.trimmingCharacters(in: .whitespaces).isEmpty && mintedKey == nil && !isWorking
    }

    var body: some View {
        Section {
            TextField("Their name", text: $personName)
                .font(Tokens.Typography.row)
                .textContentType(.name)
            if let mintedKey {
                HStack {
                    Text(mintedKey)
                        .font(Tokens.Typography.row)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { Platform.copyToClipboard(mintedKey) }
                        .font(Tokens.Typography.buttonSmall)
                        .buttonStyle(.borderless)
                }
            } else {
                HStack {
                    Spacer()
                    Button(isWorking ? "Creating…" : "Create Key") { mint() }
                        .font(Tokens.Typography.buttonSmall)
                        .buttonStyle(.borderless)
                        .disabled(!canMint)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        } header: {
            Text("Invite a Teammate")
        } footer: {
            Text("Share this key with them. It adds their devices for 7 days.")
        }
        // An edited name is no longer the one the key was made for.
        .onChange(of: personName) { mintedKey = nil }
    }

    private func mint() {
        isWorking = true
        errorText = nil
        let name = personName.trimmingCharacters(in: .whitespaces)
        Task {
            defer { isWorking = false }
            do {
                mintedKey = try await store.client?.mintKey(personName: name).key
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
