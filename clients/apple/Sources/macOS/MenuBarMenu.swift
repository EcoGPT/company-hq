import SwiftUI

/// The menu behind HQ's menu bar icon: who is signed in, the way back to the
/// window, Settings and Quit.
struct MenuBarMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(MenuBarHeader.text(personName: store.me?.name))

        Button("Open HQ") { MainWindow.open(using: openWindow) }
            .keyboardShortcut("e", modifiers: [.command, .shift])

        Divider()

        Button("Settings…") {
            store.destination = .settings
            MainWindow.open(using: openWindow)
        }
        .disabled(store.phase != .ready)

        Button("Quit HQ") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

/// The icon is the one view that exists whether or not a window does, so what
/// HQ must do with every window closed (a launch at login has none) lives
/// here: boot the store (the socket, notifications) and hand the window opener
/// to it for incoming calls.
struct MenuBarIcon: View {
    let store: AppStore

    var body: some View {
        Image(systemName: "globe.americas.fill")
            .accessibilityLabel("HQ")
            .task { store.start() }
            .task {
                #if DEBUG
                if HQSimulatorFixture.isEnabled { return }
                #endif
                await SessionSyncAgent.keepAlive(session: { store.session })
            }
            // `initial`: the main window's own `store.start()` can set the session
            // before this view appears, and nothing would restore on that launch.
            .onChange(of: store.session?.deviceId, initial: true) { _, _ in
                #if DEBUG
                if HQSimulatorFixture.isEnabled { return }
                #endif
                let session = store.session
                Task {
                    await SessionSyncAgent.restore(
                        session, isCurrent: { store.session?.deviceId == session?.deviceId })
                }
            }
            .modifier(WindowOpenerBridge(store: store))
    }
}

/// The menu's computed header line, plain so it can be checked headless.
enum MenuBarHeader {
    static func text(personName: String?) -> String {
        guard let personName, !personName.isEmpty else { return "HQ · Not signed in" }
        return "HQ · \(personName)"
    }
}
