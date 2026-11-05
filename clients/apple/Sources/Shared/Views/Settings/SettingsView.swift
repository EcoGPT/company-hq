import SwiftUI

// The Settings destination, reached from the gear pinned at the bottom of the
// sidebar, ⌘, and the menu bar. One page at a time behind a top tab bar, so
// only that page's cards mount and ask the hub anything; what they
// last heard lives in `SettingsModel`, draws at once on a revisit, and is
// re-read only once it is half a minute old.
// Grouped cards from the shared design system — no Form, like the iOS
// client's settings.
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    private var isAdmin: Bool { store.me?.isAdmin == true }

    /// Admin is for admins: someone demoted while on it lands on General.
    private var shown: SettingsPage {
        store.settings.page == .admin && !isAdmin ? .general : store.settings.page
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings") {
                Picker("Settings page", selection: Binding(get: { shown }, set: { store.settings.page = $0 })) {
                    ForEach(SettingsPage.visible(isAdmin: isAdmin)) { page in
                        Text(page.title).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings-tab")
            }
            .padding(.horizontal, Tokens.Space.x5)
            .padding(.top, Tokens.Space.x5)
            .padding(.bottom, Tokens.Space.x3)
            .frame(maxWidth: Tokens.Layout.pageContentWidth)
            .frame(maxWidth: .infinity)
            ScrollView {
                page
                    .padding(.horizontal, Tokens.Space.x5)
                    .padding(.top, Tokens.Space.x2)
                    .padding(.bottom, Tokens.Space.x5)
                    .frame(maxWidth: Tokens.Layout.pageContentWidth)
                    .frame(maxWidth: .infinity)
            }
            // A new page starts at its top, not at the last page's offset.
            .id(shown)
        }
        .onChange(of: isAdmin) { _, isAdmin in
            if !isAdmin, store.settings.page == .admin { store.settings.page = .general }
        }
        .navigationTitle("Settings")
        // The 28pt page title carries the name; a toolbar twin above it
        // would say it twice.
        .toolbar(removing: .title)
        .background(Tokens.Palette.surface)
    }

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x5) {
            switch shown {
            case .general:
                SessionPersistenceWarning()
                AccountCard()
                ThisMacCard()
            case .coding:
                McpKeysCard()
                SessionSyncCard()
            case .admin:
                MembersCard()
            }
        }
        .accessibilityIdentifier("settings-page-\(shown.rawValue)")
    }
}
