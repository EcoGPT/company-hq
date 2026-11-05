import Observation
import SwiftUI

/// Settings' pages, in tab order. Admin is for admins only.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, coding, admin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .coding: "Coding"
        case .admin: "Admin"
        }
    }

    static func visible(isAdmin: Bool) -> [Self] {
        isAdmin ? Self.allCases : Self.allCases.filter { $0 != .admin }
    }
}

/// One hub read behind a Settings card.
enum SettingsRead: Hashable {
    case mcpKeys

    /// What the error line calls it.
    var title: String {
        switch self {
        case .mcpKeys: "MCP keys"
        }
    }
}

/// What Settings' cards last heard from the hub, kept across visits so a page
/// draws at once. A revisit re-reads only answers over half a minute
/// old, so flipping between pages costs nothing. It only holds answers: it
/// computes nothing, and never holds a value revealed by Show or Copy, or a
/// key shown once at creation. `AppStore` owns it and clears it on sign-out.
@MainActor
@Observable
final class SettingsModel {
    /// How long an answer stands in for a re-read on a revisit.
    static let freshFor: TimeInterval = 30
    /// The page Settings opens on: the last one used (HIG: restore the
    /// most recently viewed pane).
    var page: SettingsPage = SettingsModel.savedPage {
        didSet { PresentationDefaults.current.set(page.rawValue, forKey: "settings-page") }
    }

    private static var savedPage: SettingsPage {
        SettingsPage(rawValue: PresentationDefaults.current.string(forKey: "settings-page") ?? "") ?? .general
    }

    var mcpKeys: [HQClient.McpKeySummary]?
    /// When each read last got an answer. Not observed: no view draws it.
    @ObservationIgnored private var answeredAt: [SettingsRead: Date] = [:]
    /// Reads whose last try failed, cleared by the next answer.
    private(set) var failed: Set<SettingsRead> = []

    /// The card's error line when its read failed: what is shown is HQ's
    /// last answer, or nothing has loaded yet.
    func refreshError(_ read: SettingsRead) -> String? {
        guard failed.contains(read) else { return nil }
        return answeredAt[read] == nil
            ? "Couldn't load the \(read.title). Open this page again to retry."
            : "Couldn't refresh the \(read.title). Showing HQ's last answer."
    }

    private func shouldRead(_ read: SettingsRead, force: Bool) -> Bool {
        force || answeredAt[read].map { Date.now.timeIntervalSince($0) >= Self.freshFor } ?? true
    }

    /// Runs one read and records how it went: `nil` when it failed. With
    /// `onNotFound`, a 404 is an answer (an older hub without the route).
    /// A read cancelled by leaving the page is not a failure.
    private func read<T>(
        _ read: SettingsRead, onNotFound: (() -> Void)? = nil, _ work: () async throws -> T
    ) async -> T? {
        do {
            let value = try await work()
            answered(read)
            return value
        } catch let error as APIError where error.status == 404 && onNotFound != nil {
            answered(read)
            onNotFound?()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            failed.insert(read)
        }
        return nil
    }

    private func answered(_ read: SettingsRead) {
        answeredAt[read] = .now
        failed.remove(read)
    }

    func reset() {
        mcpKeys = nil
        answeredAt = [:]
        failed = []
    }

    // Each loader skips a read answered under `freshFor` ago, unless `force`:
    // after a change the card made, or a person asking again.

    func loadMcpKeys(_ client: HQClient?, force: Bool = false) async {
        guard let client, shouldRead(.mcpKeys, force: force) else { return }
        if let loaded = await read(.mcpKeys, client.mcpKeys) { mcpKeys = loaded }
    }
}

/// The quiet line a card shows until its first answer arrives: never the
/// empty-state copy, which would claim there is nothing.
struct SettingsLoadingRow: View {
    var body: some View {
        Text("Loading…")
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Palette.inkTertiary)
            .padding(.horizontal, Tokens.Space.x4)
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.rowMinHeight, alignment: .leading)
    }
}

/// One ellipsis menu per row: the row's verbs behind one flat button, not a
/// glass capsule each.
struct SettingsRowMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(Tokens.Typography.buttonSmall)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .frame(width: 26, height: 26)
                .background(Tokens.Palette.surfaceHover, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// A card's error line, in the danger ink, under a hairline unless it stands
/// alone in place of the loading line.
struct SettingsErrorRow: View {
    let text: String
    var isDivided = true

    var body: some View {
        if isDivided { RowDivider() }
        Text(text)
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Palette.danger)
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
