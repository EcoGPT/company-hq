import Foundation
import os
import Security

private let keychainLog = Logger(subsystem: HQIdentity.logSubsystem, category: "keychain")

// The stored session: the device bearer plus enough identity to render
// immediately on launch. The bearer never leaves Keychain except as a header.
struct StoredSession: Codable, Sendable {
    let bearer: String
    let deviceId: String
    let person: Person
}

enum Keychain {
    private static let service = HQIdentity.bundleID
    private static var account: String { "device-session" + HQConfig.storeSuffix }

    /// Why the last save failed, if it did. A keychain write that fails
    /// silently is indistinguishable from one that worked — right up until
    /// the next launch asks for the access key again — so the status is kept
    /// and shown rather than discarded.
    private(set) static var lastFailure: String?

    /// Whether the last write actually reached the Keychain. A session that
    /// did not is a session that ends at quit.
    static var isPersisted: Bool { lastFailure == nil }

    static func load() -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                keychainLog.error("session read failed: \(status, privacy: .public)")
            }
            return nil
        }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else {
            lastFailure = "the session could not be encoded"
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update in place when a row already exists; a delete-then-add loses
        // the session for the width of the gap if the add then fails.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert.merge(attributes) { current, _ in current }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            keychainLog.error("session write failed: \(status, privacy: .public)")
            lastFailure = Self.explain(status)
            return
        }
        lastFailure = nil
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        lastFailure = nil
    }

    /// The two failures worth naming: a build with no keychain entitlement
    /// (which is a signing problem, not the user's) and a locked device.
    private static func explain(_ status: OSStatus) -> String {
        switch status {
        case errSecMissingEntitlement:
            return "this build has no keychain entitlement, so the session cannot be saved"
        case errSecInteractionNotAllowed:
            return "the device was locked when HQ tried to save the session"
        default:
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "the session could not be saved (\(reason))"
        }
    }
}
