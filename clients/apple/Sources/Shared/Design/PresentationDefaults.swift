import Foundation

/// UI fixtures must not change the signed-in person's window preferences.
enum PresentationDefaults {
    static let current: UserDefaults = {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled {
            let name = "\(HQIdentity.bundleID).ui-fixture"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }
        #endif
        return .standard
    }()
}
