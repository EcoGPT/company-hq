import AppKit
import SwiftUI

// Settings → General: who is signed in and this Mac's own behaviour.

/// The Keychain would not keep this sign-in: HQ works for this run and forgets
/// it on quit. The iPhone's Settings opens with the same warning.
struct SessionPersistenceWarning: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let problem = store.sessionPersistenceProblem {
            Label {
                Text("Signed in for this session only — \(problem).")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Palette.warning)
            }
            .padding(Tokens.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hqCard()
        }
    }
}

struct AccountCard: View {
    @Environment(AppStore.self) private var store
    @State private var isPickingAvatar = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Account")
            VStack(spacing: 0) {
                HStack(spacing: Tokens.Space.x3) {
                    if let me = store.me {
                        AvatarView(name: me.name, size: 40, person: me)
                    }
                    Text(store.me?.name ?? "—")
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.ink)
                    Spacer()
                    if store.me?.avatarId != nil {
                        Button("Remove") {
                            Task { await store.clearMyAvatar() }
                        }
                        .buttonStyle(.plain)
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .help("Remove your profile picture")
                    }
                    Button(store.me?.avatarId == nil ? "Add…" : "Change…") {
                        isPickingAvatar = true
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.accent)
                    .help("Choose a profile picture")
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x2)
                .frame(minHeight: Tokens.Layout.rowMinHeight)
                .fileImporter(isPresented: $isPickingAvatar, allowedContentTypes: [.image]) { result in
                    guard case .success(let url) = result else { return }
                    Task {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard let data = try? Data(contentsOf: url) else { return }
                        await store.setMyAvatar(imageData: data)
                    }
                }
                RowDivider()
                Button {
                    store.signOut()
                } label: {
                    Text("Sign Out")
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.danger)
                        .padding(.horizontal, Tokens.Space.x4)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.rowMinHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
            .hqCard()
        }
    }
}

// This Mac's own behavior: whether HQ starts with the computer, and whether this
// machine can actually show a notification. The notifications row exists because a
// banner the system accepts still never appears on a Mac whose owner said no at the
// prompt: the app is the only place that can say so.
struct ThisMacCard: View {
    /// Read once the card appears, not in the initial value: that runs on
    /// every parent body pass.
    @State private var isOpenAtLogin: Bool?
    @AppStorage(LinkPreviewSetting.key) private var showsLinkPreviews = true
    @State private var notifications = NotificationManager.shared.state

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("This Mac")
            VStack(spacing: 0) {
                HStack {
                    Text("Open HQ at login")
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.ink)
                    Spacer()
                    toggle(
                        Binding(
                            get: { isOpenAtLogin ?? false },
                            set: { isOpenAtLogin = $0; LoginItem.isEnabled = $0 }
                        ))
                        .disabled(isOpenAtLogin == nil)
                }
                .padding(.horizontal, Tokens.Space.x4)
                .frame(minHeight: Tokens.Layout.rowMinHeight)
                RowDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show link previews")
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text("This Mac fetches the page behind a link someone sends you.")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                    }
                    Spacer()
                    toggle($showsLinkPreviews)
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x2)
                .frame(minHeight: Tokens.Layout.rowMinHeight)
                RowDivider()
                HStack(spacing: Tokens.Space.x3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications")
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(notifications.summary)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                    }
                    Spacer()
                    if !(notifications.isPermitted && notifications.areAlertsEnabled) {
                        Button("Open Settings") { openNotificationSettings() }
                            .buttonStyle(QuietCapsuleButtonStyle())
                    }
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x3)
            }
            .hqCard()
            // The iPhone's Settings footer says the same.
            Text("HQ \(HQBuildInfo.hash) · \(HQConfig.baseURLString)")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkTertiary)
                .textSelection(.enabled)
                .padding(.horizontal, Tokens.Space.x2)
        }
        .task {
            isOpenAtLogin = LoginItem.isEnabled
            await NotificationManager.shared.refresh()
            notifications = NotificationManager.shared.state
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Tokens.Palette.accent)
            .controlSize(.small)
    }

    private func openNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
