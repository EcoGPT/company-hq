import SwiftUI

@main
struct HQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    #if DEBUG
    @State private var isPreviewDark = false
    #endif

    private var fixtureAppearance: ColorScheme? {
        #if DEBUG
        if HQSimulatorFixture.isEnabled {
            return isPreviewDark || ProcessInfo.processInfo.environment["HQ_UI_APPEARANCE"] == "dark" ? .dark : .light
        }
        // A live launch can ask for an appearance too (a screenshot is the same in light or dark).
        switch ProcessInfo.processInfo.environment["HQ_UI_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: break
        }
        #endif
        return nil
    }

    #if DEBUG
    private func resizePreview(width: CGFloat, height: CGFloat) {
        guard HQSimulatorFixture.isEnabled,
              let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("hq-main") == true }) else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }
    #endif

    var body: some Scene {
        WindowGroup(id: "hq-main") {
            RootView()
                .environment(store)
                // A coding thread's copied link, a task's link, or a desktop widget's row.
                .onOpenURL { url in
                    if let link = WidgetLink(url: url) { store.open(link) } else { store.openLink(url) }
                }
                .preferredColorScheme(fixtureAppearance)
                .windowToolbarFullScreenVisibility(.visible)
                // .task, not .onAppear: the keychain read must not run inside
                // window restoration — SecItemCopyMatching can block on a
                // permission prompt before any window exists.
                .task { store.start() }
                .modifier(WindowOpenerBridge(store: store))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 700)
        .commands {
            HQCommands(store: store)
            #if DEBUG
            CommandGroup(after: .help) {
                if HQSimulatorFixture.isEnabled {
                    Menu("UI Preview") {
                        ForEach(["chat", "history", "composer", "call", "tasks", "files", "meetings", "settings", "settings-general", "settings-coding", "settings-admin", "enrollment"], id: \.self) { scenario in
                            Button(scenario.capitalized) { store.showFixtureScenario(scenario) }
                        }
                        Divider()
                        Button("Add Incoming Message") { store.addFixtureIncomingMessage() }
                        Menu("Window Size") {
                            Button("Minimum Call · 720 × 480") { resizePreview(width: 720, height: 480) }
                            Button("Compact · 860 × 560") { resizePreview(width: 860, height: 560) }
                            Button("Standard · 1080 × 700") { resizePreview(width: 1080, height: 700) }
                            Button("Wide · 1440 × 900") { resizePreview(width: 1440, height: 900) }
                            Button("Narrow Sidebar · 200") { RootView.setFixtureSidebarWidth(200) }
                            Button("Standard Sidebar · 280") { RootView.setFixtureSidebarWidth(280) }
                        }
                        Toggle("Dark Appearance", isOn: $isPreviewDark)
                        Menu("Response Mode") {
                            ForEach(["ready", "empty", "error", "detail-error", "detail-history", "html"], id: \.self) { mode in
                                Button(mode.capitalized) {
                                    HQFixtureProtocol.contentMode = mode
                                }
                            }
                        }
                    }
                }
            }
            #endif
        }

        // HQ's always-on home: with every window closed it is all there is.
        MenuBarExtra {
            MenuBarMenu()
                .environment(store)
        } label: {
            MenuBarIcon(store: store)
        }

        // The meeting gets its own window so chat keeps working next to it,
        // and so it can go full screen the way a call should.
        Window("Meeting", id: "hq-meeting") {
            MeetingView()
                .environment(store)
                .windowFullScreenBehavior(.enabled)
        }
        .windowManagerRole(.principal)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
    }
}

// The one place a scene-owned `openWindow` can be handed to the store, so
// code outside the scene graph — the ring's AppKit panel — can still open
// the meeting stage.
struct WindowOpenerBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let store: AppStore

    func body(content: Content) -> some View {
        content.onAppear {
            store.openWindowAction = { id in
                // Answering a ring must land ON the call, not behind whatever
                // app the ring panel floated over.
                if id == "hq-meeting" {
                    MeetingWindow.spotlight(using: openWindow)
                } else {
                    openWindow(id: id)
                }
            }
        }
    }
}

@MainActor
enum MainWindow {
    static func open(using openWindow: OpenWindowAction) {
        MenuBarLifecycle.showDock()
        NSApp.unhide(nil)
        let mainWindows = NSApp.windows.filter {
            $0.identifier?.rawValue.hasPrefix("hq-main") == true
        }
        if let window = mainWindows.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            // Front the window even while activation is still pending.
            window.orderFrontRegardless()
        } else {
            openWindow(id: "hq-main")
        }
        // Cooperative activation can defer a background request; insist for a
        // beat so opening always lands HQ in the active view.
        Task {
            for _ in 0..<10 {
                NSApp.activate()
                if NSApp.isActive { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
