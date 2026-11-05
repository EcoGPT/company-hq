import Foundation
import Security
import os

/// What the app and the widget extension both derive from, with no name written down: the app's
/// bundle id (the extension's own is `<app>.widgets`) and the App Group they share.
enum WidgetIdentity {
    static let appBundleID: String = {
        let id = Bundle.main.bundleIdentifier ?? "hq"
        return id.hasSuffix(".widgets") ? String(id.dropLast(".widgets".count)) : id
    }()

    static var logSubsystem: String { appBundleID }

    /// `<bundle id>.widgets.` ahead of a widget's own name.
    static let kindPrefix = "\(appBundleID).widgets."

    /// The App Group this build was signed with, read from its own entitlements, so no team id is written
    /// anywhere in the source. Nil in a build with no team (`HQ_SIGNING_MODE = local`): it has none.
    static let appGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
                  as? [String]
        else { return nil }
        return groups.first
    }()
}

private let shelfLog = Logger(subsystem: WidgetIdentity.logSubsystem, category: "widgets")

/// What the widget extension can reach without a network: the last summary, the widget key HQ.app
/// minted for it, and the person's picture. It lives in the App Group container, which macOS opens
/// only to code signed by the same team. The key reads one summary and nothing else, so a file is
/// the right place for it; the device bearer never leaves HQ.app's Keychain.
enum WidgetShelf {
    struct Credentials: Codable, Equatable, Sendable {
        var baseURL: String
        var key: String
        var personId: String
        /// The device the key was minted for, so a different device (or a key the server has since
        /// ended with its device) is replaced, not kept. Nil only in a file from before this field.
        var deviceId: String?
    }

    /// Whether this build has a shelf at all.
    static var isAvailable: Bool { container != nil }

    /// A folder to use instead of the App Group's, for tests (a build with no team has no group).
    static var directoryOverride: URL?

    private static var container: URL? {
        if let directoryOverride { return directoryOverride }
        guard let group = WidgetIdentity.appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    private static func file(_ name: String) -> URL? {
        container?.appendingPathComponent(name)
    }

    // MARK: - Summary

    static func loadSummary() -> WidgetSummary? {
        guard let url = file("summary.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? WidgetSummary.decode(data)
    }

    /// The cached summary, only while a key is saved and the summary is that key's person's: after
    /// sign-out, or for another person, there is none.
    static func loadCurrentSummary() -> WidgetSummary? {
        guard let summary = loadSummary(), summary.belongs(to: loadCredentials()) else { return nil }
        return summary
    }

    /// Keeps the server's bytes as they came, once they decode. `key` is the widget key they were fetched
    /// with: if sign-out or a new key has replaced it since, nothing is written. Returns whether it wrote.
    @discardableResult
    static func saveSummary(_ data: Data, fetchedWith key: String) -> Bool {
        guard loadCredentials()?.key == key, let summary = try? WidgetSummary.decode(data),
              summary.belongs(to: loadCredentials()) else { return false }
        write(data, to: "summary.json")
        return true
    }

    // MARK: - Credentials

    static func loadCredentials() -> Credentials? {
        guard let url = file("credentials.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func saveCredentials(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        write(data, to: "credentials.json")
    }

    /// The server refused this key: delete it (and only it, never a newer one) so the app mints another.
    static func dropCredentials(ifKey key: String) {
        guard loadCredentials()?.key == key, let url = file("credentials.json") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Pictures

    static func avatar(personId: String, avatarId: String) -> Data? {
        guard let url = file("avatars/\(personId)-\(avatarId).jpg") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func hasAvatar(personId: String, avatarId: String) -> Bool {
        guard let url = file("avatars/\(personId)-\(avatarId).jpg") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func saveAvatar(_ data: Data, personId: String, avatarId: String) {
        write(data, to: "avatars/\(personId)-\(avatarId).jpg")
    }

    // MARK: -

    /// Sign-out: nothing of this person's stays on the desktop.
    static func clear() {
        for name in ["summary.json", "credentials.json", "avatars"] {
            if let url = file(name) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func write(_ data: Data, to name: String) {
        guard let url = file(name) else {
            shelfLog.error("no App Group container for this build")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            shelfLog.error("widget shelf write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
