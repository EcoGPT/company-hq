import AppKit
import SwiftUI

// Settings → Coding: the person's hq_mcp_v1 keys — what a Claude Code session
// authenticates with. The key shows exactly once, when it is created, and only in
// this card's own state; the setup command connects Claude Code to this server.
struct McpKeysCard: View {
    @Environment(AppStore.self) private var store
    @State private var label = ""
    @State private var minted: HQClient.MintedMcpKey?
    @State private var errorText: String?
    @State private var pendingRevoke: HQClient.McpKeySummary?

    private var activeKeys: [HQClient.McpKeySummary]? {
        store.settings.mcpKeys?.filter { $0.revokedAt == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Claude Code")
            VStack(spacing: 0) {
                ForEach(activeKeys ?? []) { key in
                    row(key)
                    RowDivider()
                }
                if let refreshError = store.settings.refreshError(.mcpKeys) {
                    SettingsErrorRow(text: refreshError, isDivided: false)
                    RowDivider()
                } else if activeKeys == nil {
                    SettingsLoadingRow()
                    RowDivider()
                }
                HStack(spacing: Tokens.Space.x3) {
                    TextField("Name, like Work Mac", text: $label)
                        .textFieldStyle(.plain)
                        .font(Tokens.Typography.row)
                    Button("Create Key") { mint() }
                        .buttonStyle(ActionCapsuleButtonStyle())
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x2)
                .frame(minHeight: Tokens.Layout.rowMinHeight)
                if let minted {
                    RowDivider()
                    mintedBlock(minted)
                }
                if let errorText {
                    SettingsErrorRow(text: errorText)
                }
            }
            .hqCard()
        }
        .task { await store.settings.loadMcpKeys(store.client) }
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

    private func row(_ key: HQClient.McpKeySummary) -> some View {
        HStack(spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.label)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(Self.keyLine(key))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            Spacer()
            Button("Revoke") { pendingRevoke = key }
            .buttonStyle(QuietCapsuleButtonStyle(
                height: Tokens.Layout.controlHeightSmall,
                ink: Tokens.Palette.danger
            ))
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x2)
        .frame(minHeight: Tokens.Layout.rowMinHeight)
    }

    private func mintedBlock(_ minted: HQClient.MintedMcpKey) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("Copy the setup now — the key never shows again.")
                .font(Tokens.Typography.captionEmphasis)
                .foregroundStyle(Tokens.Palette.warning)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    Self.claudeSetupCommand(for: minted.key), forType: .string
                )
            } label: {
                Label("Copy Claude Code Setup", systemImage: "terminal")
            }
            .buttonStyle(TintedCapsuleButtonStyle(tint: Tokens.Palette.accent))
            Text("One paste in Terminal: connects every Claude Code session on this Mac to HQ.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkTertiary)
            HStack(spacing: Tokens.Space.x2) {
                Text(minted.key)
                    .font(Tokens.Typography.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(minted.key, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(Tokens.Typography.buttonSmall)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(Tokens.Palette.surfaceHover, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Copy the bare key")
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func revoke(_ key: HQClient.McpKeySummary) {
        Task {
            do {
                try await store.client?.revokeMcpKey(id: key.id)
                errorText = nil
            } catch {
                errorText = "The key could not be revoked. Try again."
            }
            await store.settings.loadMcpKeys(store.client, force: true)
        }
    }

    private func mint() {
        Task {
            do {
                minted = try await store.client?.createMcpKey(
                    label: label.trimmingCharacters(in: .whitespaces)
                )
                label = ""
                errorText = nil
                await store.settings.loadMcpKeys(store.client, force: true)
            } catch {
                errorText = "The key could not be created. Try again."
            }
        }
    }

    /// "read, send · last used 3 min ago".
    static func keyLine(_ key: HQClient.McpKeySummary) -> String {
        var line = key.scopes
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .joined(separator: ", ")
        if let used = key.lastUsedAt {
            let date = Date(timeIntervalSince1970: Double(used) / 1000)
            line += " · last used " + date.formatted(.relative(presentation: .named))
        }
        return line
    }

    /// One paste: a user-scope `claude mcp add`, so every Claude Code session
    /// on the machine reaches this server from any directory.
    static func claudeSetupCommand(for key: String) -> String {
        "claude mcp add --scope user --transport http hq " + HQConfig.baseURLString + "/mcp"
            + " --header \"Authorization: Bearer " + key + "\""
    }
}
