import SwiftUI

@main
struct HQApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        // Attached HERE, not in a scene: a ring arrives over the socket
        // whether or not a scene is up yet, and answering it needs the
        // store anyway.
        CallKitCoordinator.shared.store = store
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                #if DEBUG && targetEnvironment(simulator)
                .preferredColorScheme(fixtureAppearance)
                #endif
                .onOpenURL { store.openLink($0) }
                // .task, not .onAppear: the keychain read is the first thing
                // that happens and it must not block scene setup.
                .task { store.start() }
                .tint(Tokens.Palette.accent)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    private var fixtureAppearance: ColorScheme? {
        guard HQSimulatorFixture.isEnabled else { return nil }
        switch ProcessInfo.processInfo.environment["HQ_UI_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    #endif
}
