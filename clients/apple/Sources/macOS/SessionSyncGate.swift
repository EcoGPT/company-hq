import Foundation

/// The rules about when this process may touch the system (register a login item,
/// start or stop the helper), as pure functions so a test can state them. The
/// environment is passed in; nothing here reads it.
enum SessionSyncGate {
    /// Whether `DEBUG` was compiled in.
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// `HQ_NO_SYSTEM_REGISTRATION`: this run must not register, retire, launch or
    /// kill anything that belongs to the installed app. A unit-test host is the
    /// same: `xcodebuild` does not hand its environment to the app it hosts the
    /// tests in, so the flag alone would let a test run retire the installed helper
    /// and start one from the build folder.
    static func isSystemTouchBlocked(environment: [String: String]) -> Bool {
        environment["HQ_NO_SYSTEM_REGISTRATION"] != nil || environment["XCTestConfigurationFilePath"] != nil
    }

    /// Whether this process may register the login item. Never when the system must
    /// not be touched; and a Debug build (DerivedData, a worktree) only when
    /// `HQ_ALLOW_SYSTEM_REGISTRATION=1` says the person means it.
    static func isRegistrationAllowed(environment: [String: String], isDebugBuild: Bool) -> Bool {
        if isSystemTouchBlocked(environment: environment) { return false }
        if isDebugBuild { return environment["HQ_ALLOW_SYSTEM_REGISTRATION"] == "1" }
        return true
    }
}
