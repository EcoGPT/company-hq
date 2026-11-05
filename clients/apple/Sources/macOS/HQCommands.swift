import SwiftUI

/// What the main window can do for the menu bar right now. `RootView` owns
/// the state these act on (the compose sheet, the sidebar rail, the details
/// panel), so it publishes closures as a focused scene value and the menu
/// only ever asks; an item with no value, or a `false` flag, is disabled.
struct HQShellActions {
    var canCompose = false
    var compose: () -> Void = {}
    var canUseSidebar = false
    var findInSidebar: () -> Void = {}
    var toggleSidebar: () -> Void = {}
    var canShowDetails = false
    var detailsAreOpen = false
    var toggleDetails: () -> Void = {}
}

private struct HQShellActionsKey: FocusedValueKey {
    typealias Value = HQShellActions
}

extension FocusedValues {
    var hqShell: HQShellActions? {
        get { self[HQShellActionsKey.self] }
        set { self[HQShellActionsKey.self] = newValue }
    }
}

/// The main window's menu bar: File ▸ New Conversation, Edit ▸ Find,
/// View ▸ Toggle Sidebar / Show Details / Agents canvas zoom, Go (every destination of the
/// sidebar grid), and Settings… in the app menu.
/// Every command routes through navigation the window already has; none
/// holds state of its own.
struct HQCommands: Commands {
    let store: AppStore
    @FocusedValue(\.hqShell) private var shell
    @FocusedValue(\.liveCanvasZoom) private var canvasZoom

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { shell?.compose() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(shell?.canCompose != true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { shell?.findInSidebar() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(shell?.canUseSidebar != true)
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { shell?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(shell?.canUseSidebar != true)
            Button(shell?.detailsAreOpen == true ? "Hide Details" : "Show Details") { shell?.toggleDetails() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(shell?.canShowDetails != true)
        }
        CommandGroup(after: .sidebar) {
            // Agents canvas: enabled only while it is on screen (the canvas publishes
            // `liveCanvasZoom`). One Zoom In, ⌘+, as in Safari and Preview; the
            // canvas's + button takes ⌘= without a second row.
            Divider()
            Button("Zoom In") { canvasZoom?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(canvasZoom?.canZoomIn != true)
            Button("Zoom Out") { canvasZoom?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(canvasZoom?.canZoomOut != true)
            Button("Fit to Width") { canvasZoom?.fit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(canvasZoom?.canFit != true)
        }
        CommandMenu("Go") {
            GoMenuItems(store: store, isEnabled: shell != nil)
        }
        CommandGroup(replacing: .appSettings) {
            SettingsItem(store: store)
        }
    }
}

/// The sidebar grid's destinations in its default order (the shipped favorites, then the rest
/// of the shortcuts), numbered ⌘1…⌘9 down the list. A person's own favorites reorder the grid
/// but never the numbers: a shortcut that moves under the fingers is worse than none.
enum HQGoDestination {
    case shortcut(HomePreferences.Shortcut)

    var id: String {
        switch self {
        case .shortcut(let shortcut): "shortcut-\(shortcut.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .shortcut(let shortcut): shortcut.title
        }
    }

    static func all() -> [HQGoDestination] {
        let available = HomePreferences.Shortcut.available
        let favorites = HomePreferences.Shortcut.defaultShortcuts
        let ordered = favorites.filter(available.contains) + available.filter { !favorites.contains($0) }
        return ordered.map(HQGoDestination.shortcut)
    }
}

private struct GoMenuItems: View {
    let store: AppStore
    let isEnabled: Bool

    var body: some View {
        let canGo = isEnabled && store.phase == .ready
        let destinations = HQGoDestination.all()
        ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
            if index < 9 {
                item(destination, canGo: canGo)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            } else {
                item(destination, canGo: canGo)
            }
        }
    }

    private func item(_ destination: HQGoDestination, canGo: Bool) -> some View {
        Button(destination.title) {
            switch destination {
            case .shortcut(let shortcut):
                store.destination = shortcut.destination
            }
        }
        .disabled(!canGo)
    }
}

private struct SettingsItem: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            store.destination = .settings
            MainWindow.open(using: openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(store.phase != .ready)
    }
}
