import SQLite3
import XCTest

@testable import HQ

/// The app's real push calls, `HQClient.reportPush` and `unregisterPushToken`,
/// against a real HQ Community server: no mocks. The server has no route that
/// lists tokens (a token is the key to a person's lock screen), so each test
/// reads the server's SQLite file to see what was stored.
///
/// Skipped unless all four are set (pass them through `TEST_RUNNER_`, which
/// `xcodebuild` strips before handing them to the test host):
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada
///     HQ_LIVE_KEY_B    an invite key for a member named Bo
///     HQ_LIVE_DB       the server's database file (HQ_DB), readable by this run
///
/// The server needs no push settings: it stores tokens either way. Run it
/// against a throwaway database; each run adds devices and token rows.
@MainActor
final class LivePushTests: XCTestCase {
    private struct Live {
        let server: String
        let keyA: String
        let keyB: String
        let database: String
    }

    private struct StoredPush: Equatable {
        let token: String?
        let environment: String?
        let status: String
    }

    private struct DatabaseError: Error, CustomStringConvertible {
        let description: String
    }

    private var live: Live!
    private var previousServer: String?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            let text = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let server = value("HQ_LIVE_SERVER"), let keyA = value("HQ_LIVE_KEY_A"),
              let keyB = value("HQ_LIVE_KEY_B"), let database = value("HQ_LIVE_DB")
        else { throw XCTSkip("HQ_LIVE_SERVER, HQ_LIVE_KEY_A, HQ_LIVE_KEY_B and HQ_LIVE_DB are not all set") }
        XCTAssertFalse(HQSimulatorFixture.isEnabled, "a live run must not be a fixture run")
        guard case .success(let normalized) = HQConfig.normalizedServer(server) else {
            throw XCTSkip("HQ_LIVE_SERVER is not a usable server address")
        }
        live = Live(server: normalized, keyA: keyA, keyB: keyB, database: database)
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
    }

    override func tearDown() async throws {
        if live != nil { HQConfig.savedServer = previousServer }
    }

    // MARK: - Helpers

    private func enroll(_ key: String, _ name: String) async throws -> (client: HQClient, deviceId: String) {
        let response = try await HQClient.enroll(key: key, personName: nil, deviceName: name)
        return (HQClient(bearer: response.bearer), response.deviceId)
    }

    /// 64 lower-case hex characters, as both AppDelegates make from Apple's token.
    private func tokenHex() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// What the server holds for a device, read from its database file; nil when it has no row.
    private func stored(_ deviceId: String) throws -> StoredPush? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(live.database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw DatabaseError(description: "cannot open the server's database read-only")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT token, environment, status FROM push_tokens WHERE device_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(description: "no push_tokens table: is this a server with push?")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, deviceId, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(statement, column))
        }
        return StoredPush(token: text(0), environment: text(1), status: text(2) ?? "")
    }

    // MARK: - Tests

    /// The app reports a token after sign-in, the state changes later, and sign-out unregisters.
    func testAReportedTokenIsStoredReplacedAndClearedAtSignOut() async throws {
        let ada = try await enroll(live.keyA, "LivePushTests Ada")
        XCTAssertNil(try stored(ada.deviceId), "a new device holds nothing")

        let first = tokenHex()
        try await ada.client.reportPush(status: "authorized", token: first, voipToken: nil, environment: "development")
        XCTAssertEqual(
            try stored(ada.deviceId), StoredPush(token: first, environment: "development", status: "authorized"))

        // Apple issued a new token (a reinstall): the new one replaces the old.
        let second = tokenHex()
        try await ada.client.reportPush(status: "authorized", token: second, voipToken: nil, environment: "production")
        XCTAssertEqual(
            try stored(ada.deviceId), StoredPush(token: second, environment: "production", status: "authorized"))

        // The app reports why it has none: the status is kept and no token is.
        try await ada.client.reportPush(
            status: "error: no entitlement", token: nil, voipToken: nil, environment: "production")
        XCTAssertEqual(try stored(ada.deviceId), StoredPush(token: nil, environment: nil, status: "error: no entitlement"))

        try await ada.client.reportPush(status: "authorized", token: second, voipToken: nil, environment: "production")
        XCTAssertEqual(try stored(ada.deviceId)?.token, second)

        // Sign-out.
        try await ada.client.unregisterPushToken()
        XCTAssertNil(try stored(ada.deviceId), "unregistering leaves no row for the device")
        // Signing out again is not an error.
        try await ada.client.unregisterPushToken()
    }

    /// A phone that changed hands: the person who reports the token last holds it.
    func testATokenMovesToTheDeviceThatReportedItLast() async throws {
        let ada = try await enroll(live.keyA, "LivePushTests Ada phone")
        let bo = try await enroll(live.keyB, "LivePushTests Bo phone")
        let shared = tokenHex()

        try await ada.client.reportPush(status: "authorized", token: shared, voipToken: nil, environment: "production")
        XCTAssertEqual(try stored(ada.deviceId)?.token, shared)

        try await bo.client.reportPush(status: "authorized", token: shared, voipToken: nil, environment: "production")
        XCTAssertEqual(try stored(bo.deviceId)?.token, shared)
        XCTAssertNil(try stored(ada.deviceId)?.token, "Ada's device no longer holds a token Bo's phone reported")

        try await bo.client.unregisterPushToken()
        XCTAssertNil(try stored(bo.deviceId))
        try await ada.client.unregisterPushToken()
    }
}
