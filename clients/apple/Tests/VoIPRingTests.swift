import XCTest

@testable import HQ

/// Keeps the body of the push report, so `HQClient`'s real request path runs
/// without a server.
private final class VoIPReportStub: URLProtocol {
    nonisolated(unsafe) private static var bodies: [Data] = []
    private static let lock = NSLock()

    static func reset() { lock.lock(); bodies = []; lock.unlock() }
    static var sent: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/v1/devices/apns-token"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        Self.lock.lock()
        Self.bodies.append(body)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A phone that refused notifications has no alert token but still rings: its
/// VoIP token goes with the build's environment, so the server knows which of
/// Apple's hosts to send it to.
@MainActor
final class VoIPReportTests: XCTestCase {
    private var previousServer: String?

    override func setUp() async throws {
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = "https://hq.example.test"
        VoIPReportStub.reset()
        URLProtocol.registerClass(VoIPReportStub.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(VoIPReportStub.self)
        HQConfig.savedServer = previousServer
    }

    private func body() throws -> [String: Any] {
        let data = try XCTUnwrap(VoIPReportStub.sent.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAVoIPTokenWithNoAlertTokenCarriesTheEnvironment() async throws {
        try await HQClient(bearer: "b").reportPush(
            status: "denied", token: nil, voipToken: "ff00", environment: "development"
        )
        let sent = try body()
        XCTAssertEqual(Set(sent.keys), ["environment", "status", "voip_token"])
        XCTAssertEqual(sent["environment"] as? String, "development")
        XCTAssertEqual(sent["voip_token"] as? String, "ff00")
    }

    func testNoTokenAtAllSendsNoEnvironment() async throws {
        try await HQClient(bearer: "b").reportPush(
            status: "denied", token: nil, voipToken: nil, environment: "production"
        )
        XCTAssertEqual(try body().keys.sorted(), ["status"])
    }
}

/// The VoIP push payload the server sends (docs/push.md, "Rings"), read into a
/// ring for CallKit. The phone must report every VoIP push, so what cannot be
/// read is nil and gets a report that ends at once.
final class VoIPRingTests: XCTestCase {
    private let callId = "0192f7a0-1b2c-7d3e-8f40-5a6b7c8d9e0f"

    /// Exactly what the server puts on the wire, decoded the way PushKit hands
    /// it over: a JSON object with `null` for a direct message's title.
    private func payload(_ json: String) throws -> [AnyHashable: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
    }

    func testTheServersPayloadIsARing() throws {
        let info = try payload("""
            {"call_id":"\(callId)","caller_name":"Ada","conversation_id":"c-1",\
            "conversation_title":"Launch","expires_at":"2030-01-02T03:04:05.678Z"}
            """)
        let ring = try XCTUnwrap(VoIPRing(payload: info))
        XCTAssertEqual(ring.callId, callId)
        XCTAssertEqual(ring.uuid, UUID(uuidString: callId))
        XCTAssertEqual(ring.conversationId, "c-1")
        XCTAssertEqual(ring.callerName, "Ada")
        XCTAssertEqual(ring.conversationTitle, "Launch")
        XCTAssertEqual(ring.expiresAt.timeIntervalSince1970, 1_893_553_445.678, accuracy: 0.001)
    }

    func testADirectMessageHasNoRoomTitle() throws {
        let info = try payload("""
            {"call_id":"\(callId)","caller_name":"Ada","conversation_id":"c-1",\
            "conversation_title":null,"expires_at":"2030-01-02T03:04:05.678Z"}
            """)
        XCTAssertNil(try XCTUnwrap(VoIPRing(payload: info)).conversationTitle)
        let blank: [AnyHashable: Any] = ["call_id": callId, "conversation_id": "c-1", "conversation_title": "  "]
        XCTAssertNil(try XCTUnwrap(VoIPRing(payload: blank)).conversationTitle)
    }

    func testANamelessCallerIsSomeone() throws {
        let missing: [AnyHashable: Any] = ["call_id": callId, "conversation_id": "c-1"]
        let empty: [AnyHashable: Any] = ["call_id": callId, "conversation_id": "c-1", "caller_name": " "]
        XCTAssertEqual(try XCTUnwrap(VoIPRing(payload: missing)).callerName, "Someone")
        XCTAssertEqual(try XCTUnwrap(VoIPRing(payload: empty)).callerName, "Someone")
        XCTAssertEqual(VoIPRing.callerName(in: [:]), "Someone")
        XCTAssertEqual(VoIPRing.callerName(in: ["caller_name": "Bo"]), "Bo")
    }

    func testNoExpiryRingsForTheDefaultTime() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let ring = try XCTUnwrap(VoIPRing(payload: ["call_id": callId, "conversation_id": "c-1"], now: now))
        XCTAssertEqual(ring.expiresAt, now.addingTimeInterval(45))
    }

    /// CallKit keys a call by UUID, and the answer joins the room: without
    /// either there is no ring, only the report iOS requires.
    func testAPushWithNoUsableCallOrRoomIsNotARing() {
        XCTAssertNil(VoIPRing(payload: ["conversation_id": "c-1"]))
        XCTAssertNil(VoIPRing(payload: ["call_id": "not-a-uuid", "conversation_id": "c-1"]))
        XCTAssertNil(VoIPRing(payload: ["call_id": callId]))
        XCTAssertNil(VoIPRing(payload: ["call_id": callId, "conversation_id": ""]))
        XCTAssertNil(VoIPRing(payload: ["call_id": 42, "conversation_id": "c-1"]))
    }
}
