import SwiftUI

struct HomeWorkspaceBar: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    @Binding var selection: AppStore.Destination?
    @ScaledMetric(relativeTo: .caption) private var iconSize = Tokens.Home.shortcutDiameter
    @ScaledMetric(relativeTo: .caption) private var itemWidth = Tokens.Home.shortcutWidth

    private var shortcuts: [HomePreferences.Shortcut] {
        let available = HomePreferences.Shortcut.available
        let favorites = preferences.shortcuts.filter(available.contains)
        return favorites + available.filter { !favorites.contains($0) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(shortcuts) { shortcut in
                    // One count per shortcut per body: the Projects count walks the tasks.
                    let count = count(for: shortcut)
                    Button {
                        selection = shortcut.destination
                    } label: {
                        WorkspaceShortcutLabel(
                            title: shortcut.title,
                            symbol: shortcut.symbol,
                            color: shortcut.color, count: count
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shortcut.title)
                    .accessibilityIdentifier("home-shortcut-\(shortcut.rawValue)")
                    .accessibilityValue(count > 0 ? "\(count)" : "")
                }
            }
            .padding(.vertical, 8)
        }
        // The first circle shares the chat avatar's 27pt leading edge.
        .contentMargins(.leading, max(8, 27 - (itemWidth - min(iconSize, 56)) / 2), for: .scrollContent)
        .contentMargins(.trailing, 16, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("home-workspace-shortcuts")
    }

    private func count(for shortcut: HomePreferences.Shortcut) -> Int {
        switch shortcut {
        case .calls: store.activeCall?.presentParticipants.count ?? store.liveMeetingHeadcount
        case .tasks: store.myOpenTaskCount
        default: 0
        }
    }
}

struct HomeShortcutsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(preferences.shortcuts) { shortcut in
                        Label(shortcut.title, systemImage: shortcut.symbol)
                    }
                    .onDelete { indexes in
                        var shortcuts = preferences.shortcuts
                        shortcuts.remove(atOffsets: indexes)
                        preferences.setShortcuts(shortcuts)
                    }
                    .onMove { source, destination in
                        var shortcuts = preferences.shortcuts
                        shortcuts.move(fromOffsets: source, toOffset: destination)
                        preferences.setShortcuts(shortcuts)
                    }
                } header: { Text("Favorites") } footer: {
                    Text("Choose up to three favorites to show first. All other shortcuts remain available by scrolling. Active calls stay in the return strip above every page.")
                }
                Section("Add a shortcut") {
                    ForEach(HomePreferences.Shortcut.available
                        .filter { !preferences.shortcuts.contains($0) }) { item in
                        Button { preferences.setShortcuts(preferences.shortcuts + [item]) } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                        .disabled(preferences.shortcuts.count >= HomePreferences.maximumShortcuts)
                        .accessibilityIdentifier("add-shortcut-\(item.rawValue)")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Favorite shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
