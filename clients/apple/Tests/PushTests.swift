import XCTest
import UserNotifications
@testable import HQ

/// Answers the push route on the shared session and keeps what it was sent, so
/// `HQClient`'s real request path runs without a server.
private final class PushRouteStub: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let authorization: String?
        let contentType: String?
        let body: Data?
    }

    nonisolated(unsafe) private static var seen: [Seen] = []
    nonisolated(unsafe) private static var status = 200
    private static let lock = NSLock()

    static func reset(status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        seen = []
        self.status = status
    }

    static var requests: [Seen] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/v1/devices/apns-token"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        Self.lock.lock()
        Self.seen.append(Seen(
            method: request.httpMethod ?? "", path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body
        ))
        let status = Self.status
        Self.lock.unlock()
        let payload = status == 200 ? #"{"ok":true}"# : #"{"error":"not_found"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// What the app reports to the server about push, and how it treats a push
/// against the same message on the socket.
@MainActor
final class PushTests: XCTestCase {
    private var previousServer: String?

    override func setUp() async throws {
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = "https://hq.example.test"
        PushRouteStub.reset()
        URLProtocol.registerClass(PushRouteStub.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(PushRouteStub.self)
        HQConfig.savedServer = previousServer
    }

    private func sentBody(_ index: Int = 0) throws -> [String: Any] {
        let data = try XCTUnwrap(PushRouteStub.requests[index].body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Status mapping

    func testAGrantedDeviceWithAnAlertSettingAndATokenIsAuthorized() {
        let state = PushState(authorization: "authorized", areAlertsEnabled: true, token: "ab12")
        XCTAssertEqual(state.wire, "authorized")
        XCTAssertTrue(state.summary.hasPrefix("On"))
    }

    func testADeniedDeviceReportsDenied() {
        let state = PushState(authorization: "denied")
        XCTAssertEqual(state.wire, "denied")
        XCTAssertFalse(state.isPermitted)
    }

    func testARegistrationFailureReportsTheErrorAndWinsOverEverythingElse() {
        // A build with no team: permission is granted, Apple refuses a token.
        let state = PushState(
            authorization: "authorized", areAlertsEnabled: true, token: nil,
            error: "no valid “aps-environment” entitlement string found for application"
        )
        XCTAssertTrue(state.wire.hasPrefix("error: no valid"))
    }

    func testALocalBuildHasNoPushAndSaysWhatItSaidBefore() {
        // The test build is the default `local` mode, which never defines HQ_PUSH.
        XCTAssertFalse(PushState.isBuilt)
        let granted = PushState(authorization: "authorized", areAlertsEnabled: true)
        XCTAssertEqual(
            granted.summary,
            "On — banners appear while HQ is running. If they still don't, check Focus / Do Not Disturb."
        )
    }

    func testAnErrorIsCutAtOneHundredCharacters() {
        let state = PushState(error: String(repeating: "x", count: 300))
        XCTAssertEqual(state.wire, "error: " + String(repeating: "x", count: 100))
    }

    func testTheOtherRungsInOrder() {
        XCTAssertEqual(PushState().wire, "not_determined")
        XCTAssertEqual(PushState(authorization: "authorized", areAlertsEnabled: false, token: "ab").wire, "alerts_off")
        XCTAssertEqual(PushState(authorization: "authorized", areAlertsEnabled: true, token: nil).wire, "no_token")
        XCTAssertEqual(PushState(authorization: "provisional", areAlertsEnabled: true, token: "ab").wire, "authorized")
    }

    // MARK: - The report

    func testAReportWithATokenSendsEnvironmentStatusTokenAndVoipToken() async throws {
        try await HQClient(bearer: "device-bearer").reportPush(
            status: "authorized", token: "ab12cd", voipToken: "ff00", environment: "development"
        )
        let request = try XCTUnwrap(PushRouteStub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/devices/apns-token")
        XCTAssertEqual(request.authorization, "Bearer device-bearer")
        XCTAssertEqual(request.contentType, "application/json")
        let body = try sentBody()
        XCTAssertEqual(Set(body.keys), ["environment", "status", "token", "voip_token"])
        XCTAssertEqual(body["environment"] as? String, "development")
        XCTAssertEqual(body["status"] as? String, "authorized")
        XCTAssertEqual(body["token"] as? String, "ab12cd")
        XCTAssertEqual(body["voip_token"] as? String, "ff00")
    }

    func testAReportWithNoTokenSendsOnlyTheStatus() async throws {
        try await HQClient(bearer: "b").reportPush(
            status: "denied", token: nil, voipToken: nil, environment: "production"
        )
        XCTAssertEqual(try sentBody().keys.sorted(), ["status"])
        XCTAssertEqual(try sentBody()["status"] as? String, "denied")
    }

    func testUnregisteringIsADeleteWithNoBody() async throws {
        try await HQClient(bearer: "b").unregisterPushToken()
        let request = try XCTUnwrap(PushRouteStub.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/v1/devices/apns-token")
        XCTAssertNil(request.body)
    }

    func testAServerWithoutPushAnswers404AndTheStoreSwallowsIt() async throws {
        PushRouteStub.reset(status: 404)
        do {
            try await HQClient(bearer: "b").reportPush(
                status: "authorized", token: "ab", voipToken: nil, environment: "development"
            )
            XCTFail("a 404 must throw to the caller")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 404)
        }
    }

    #if DEBUG
    func testADebugBuildReportsTheSandboxEnvironment() {
        XCTAssertEqual(AppStore.apnsEnvironment, "development")
    }
    #endif

    // MARK: - A push against the socket's copy

    func testThePushCopyOfAMessageTheSocketAlreadyBanneredIsDropped() {
        let manager = NotificationManager()
        XCTAssertTrue(manager.didClaim("m1"), "the socket's local banner claims first")
        let push: [AnyHashable: Any] = ["conversation_id": "c1", "message_id": "m1"]
        XCTAssertEqual(manager.presentation(for: push), [])
    }

    func testThePushCopyShowsWhenItIsFirstAndTheSocketCopyThenLoses() {
        let manager = NotificationManager()
        let push: [AnyHashable: Any] = ["conversation_id": "c1", "message_id": "m2"]
        XCTAssertEqual(manager.presentation(for: push), [.banner, .sound])
        XCTAssertFalse(manager.didClaim("m2"), "the socket's local copy loses")
        XCTAssertEqual(manager.presentation(for: push), [], "a second push for it is dropped too")
    }

    func testABackgroundedPushIsClaimedSoTheSocketCopyLoses() async {
        let manager = NotificationManager()
        await manager.noteRemoteDelivery(userInfo: ["conversation_id": "c1", "message_id": "m3"], isActive: false)
        XCTAssertFalse(manager.didClaim("m3"))
        XCTAssertTrue(manager.didClaim("m4"), "another message is untouched")
    }

    func testAForegroundPushIsLeftForWillPresentSoItStillShows() async {
        // iOS can hand an active app the push before `willPresent`; a claim
        // there would silence both the push and the socket copy.
        let manager = NotificationManager()
        let push: [AnyHashable: Any] = ["conversation_id": "c1", "message_id": "m8"]
        await manager.noteRemoteDelivery(userInfo: push, isActive: true)
        XCTAssertEqual(manager.presentation(for: push), [.banner, .sound])
    }

    // MARK: - A backgrounded iPhone

    func testABackgroundedPhoneWithATokenLeavesMessagesToPush() {
        XCTAssertTrue(NotificationManager.leavesBannerToPush(isActive: false, hasToken: true, messageId: "m1"))
    }

    func testAPhoneWithNoTokenOrInTheForegroundPostsItsOwnBanner() {
        XCTAssertFalse(NotificationManager.leavesBannerToPush(isActive: false, hasToken: false, messageId: "m1"))
        XCTAssertFalse(NotificationManager.leavesBannerToPush(isActive: true, hasToken: true, messageId: "m1"))
    }

    func testAMeetingReminderAlwaysPostsBecauseItNeverComesByPush() {
        XCTAssertFalse(
            NotificationManager.leavesBannerToPush(isActive: false, hasToken: true, messageId: "meeting-7")
        )
    }

    func testALocalBannerIsNotDedupedAgainstItself() {
        let manager = NotificationManager()
        let local: [AnyHashable: Any] = ["conversation_id": "c1", "message_id": "m5", "is_local": true]
        XCTAssertEqual(manager.presentation(for: local), [.banner, .sound])
        XCTAssertEqual(manager.presentation(for: local), [.banner, .sound])
    }

    func testAMessageAtOrBeforeTheReadCursorShowsNothing() async {
        let manager = NotificationManager()
        await manager.noteRemoteDelivery(
            userInfo: ["conversation_id": "c1", "read_through_message_id": "m10"], isActive: false
        )
        XCTAssertEqual(manager.presentation(for: ["conversation_id": "c1", "message_id": "m09"]), [])
        XCTAssertEqual(manager.presentation(for: ["conversation_id": "c1", "message_id": "m10"]), [])
        XCTAssertEqual(manager.presentation(for: ["conversation_id": "c1", "message_id": "m11"]), [.banner, .sound])
        XCTAssertEqual(
            manager.presentation(for: ["conversation_id": "c2", "message_id": "m09"]), [.banner, .sound],
            "the cursor is per conversation"
        )
    }

    func testThePushForTheThreadOnScreenShowsNoBanner() {
        let manager = NotificationManager()
        manager.shouldSuppressBanner = { $0 == "c1" }
        XCTAssertEqual(manager.presentation(for: ["conversation_id": "c1", "message_id": "m6"]), [])
        XCTAssertEqual(manager.presentation(for: ["conversation_id": "c2", "message_id": "m7"]), [.banner, .sound])
    }

    // MARK: - What a push is worth

    func testAReadSyncPushReadsOnlyTheConversationListAndAnyOtherPushRefreshes() async {
        setenv("HQ_UI_SCENARIO", "chat", 1)
        defer { unsetenv("HQ_UI_SCENARIO") }
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()

        let beforeReadSync = HubRequestCount.value
        await store.handleRemotePush(isReadSync: true)
        let readSyncRequests = HubRequestCount.value - beforeReadSync
        XCTAssertEqual(readSyncRequests, 1, "a read-sync push reads the conversation list and nothing else")

        let beforeMessage = HubRequestCount.value
        await store.handleRemotePush(isReadSync: false)
        let messageRequests = HubRequestCount.value - beforeMessage
        XCTAssertGreaterThan(messageRequests, readSyncRequests, "any other push also reads the roster and calls")
    }
}
