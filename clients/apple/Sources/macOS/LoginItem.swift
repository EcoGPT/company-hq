import Foundation
import ServiceManagement

/// Whether this process may touch the system (register a login item). Never for a unit-test host,
/// and never when `HQ_NO_SYSTEM_REGISTRATION` is set, so a build run from a worktree stays out of
/// the person's login items.
enum SystemRegistration {
    static func isBlocked(environment: [String: String]) -> Bool {
        environment["HQ_NO_SYSTEM_REGISTRATION"] != nil || environment["XCTestConfigurationFilePath"] != nil
    }
}

/// HQ can open itself when the Mac starts. This is the app's OWN login item
/// (`SMAppService.mainApp`). Off by default: a person turns it on from Settings
/// (or System Settings → General → Login Items), and the preference is honored
/// on every launch, so a choice either way is never changed behind their back.
@MainActor
enum LoginItem {
    private static let defaultsKey = "HQOpenAtLogin"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            apply()
        }
    }

    static func apply(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // A worktree or test build must not register itself as the login item.
        guard !SystemRegistration.isBlocked(environment: environment) else { return }
        let service = SMAppService.mainApp
        if isEnabled {
            // register() on an already-enabled service throws; the status
            // check is the guard, not an optimization.
            if service.status != .enabled { try? service.register() }
        } else if service.status == .enabled {
            try? service.unregister()
        }
    }
}
