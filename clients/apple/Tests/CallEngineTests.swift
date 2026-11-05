import AVFoundation
import XCTest
import WebRTC

@testable import HQ

@MainActor
final class CallEngineTests: XCTestCase {
    private var previousScenario: String?

    override func setUp() async throws {
        previousScenario = ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
        setenv("HQ_UI_SCENARIO", "call", 1)
    }

    override func tearDown() async throws {
        if let previousScenario { setenv("HQ_UI_SCENARIO", previousScenario, 1) }
        else { unsetenv("HQ_UI_SCENARIO") }
    }

    private var joined: HQClient.JoinedCall {
        HQClient.JoinedCall(call: HQSimulatorFixture().calls[0], sessionId: "audio-test", generation: 1)
    }

    private func failedEngine() async -> CallEngine {
        let engine = CallEngine()
        // The offline transport rejects media publication. Exercise the real
        // failure/retry path without a server or a live microphone.
        await engine.join(
            client: HQClient(bearer: "fixture"), joined: joined,
            isCameraOn: false, isMicrophoneOn: false
        )
        guard case .failed = engine.stage else {
            XCTFail("The offline media publication should fail")
            return engine
        }
        engine.retryAfterFailure()
        return engine
    }

    func testAudioResetRecoverySurvivesICEConnectedAndCoalescesNotifications() async throws {
        let engine = await failedEngine()
        let recovered = expectation(description: "audio recovery")
        recovered.assertForOverFulfill = true
        engine.onConnectionLost = {
            await engine.rejoin(client: HQClient(bearer: "fixture"), joined: self.joined)
            XCTAssertFalse(engine.isMicrophoneOn)
            XCTAssertFalse(engine.isCameraOn)
            await engine.leave()
            recovered.fulfill()
        }

        engine.noteAudioServicesReset()
        engine.noteAudioServicesReset()
        let factory = RTCPeerConnectionFactory()
        let peer = try XCTUnwrap(factory.peerConnection(
            with: RTCConfiguration(),
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil
        ))
        defer { peer.close() }
        engine.peerConnection(peer, didChange: RTCIceConnectionState.connected)

        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(engine.stage, .idle)
    }

    func testAudioResetDoesNotJoinAnIdleOrEndedCall() async {
        let idleEngine = CallEngine()
        let recovered = expectation(description: "no call to recover")
        recovered.isInverted = true
        idleEngine.onConnectionLost = { recovered.fulfill() }
        idleEngine.noteAudioServicesReset()
        XCTAssertEqual(idleEngine.stage, .idle)

        let engine = await failedEngine()
        engine.onConnectionLost = { recovered.fulfill() }
        engine.noteAudioServicesReset()
        await engine.leave()

        await fulfillment(of: [recovered], timeout: 1.3)
        XCTAssertEqual(engine.stage, .idle)
    }

    func testNegotiationLogKeepsTheFailingSectionAndNoCredentials() {
        let sdp = [
            "v=0", "a=group:BUNDLE 0 7", "a=fingerprint:sha-256 AA:BB",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:0", "a=ice-pwd:secret0", "a=rtpmap:111 opus/48000/2",
            "m=video 9 UDP/TLS/RTP/SAVPF 96 97", "a=mid:7", "a=ice-ufrag:user7", "a=sendonly",
            "a=rtpmap:96 H264/90000", "a=fmtp:96 profile-level-id=640c1f", "a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid",
            "a=candidate:1 1 udp 2122260223 192.168.1.2 52000 typ host",
        ].joined(separator: "\r\n")

        let summary = CallEngine.mediaSummary(of: sdp, mids: ["7"])

        // What decides why libwebrtc refused mid 7 is all there...
        XCTAssertTrue(summary.contains("a=group:BUNDLE 0 7"))
        XCTAssertTrue(summary.contains("a=fmtp:96 profile-level-id=640c1f"))
        XCTAssertTrue(summary.contains("a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid"))
        XCTAssertTrue(summary.contains("a=sendonly"))
        // ...the other sections are not, and nothing that authenticates the
        // connection or locates the machine ever reaches the log.
        XCTAssertFalse(summary.contains("opus"))
        for secret in ["secret0", "user7", "fingerprint", "192.168.1.2"] {
            XCTAssertFalse(summary.contains(secret), secret)
        }
    }

    func testRefusedSubscriptionsRetryEverySecondBeforeBackingOff() {
        let delays = (1...10).map { CallEngine.subscribeRetryDelay(afterFailures: $0) }
        XCTAssertEqual(Array(delays.prefix(4)), Array(repeating: .seconds(1), count: 4))
        XCTAssertEqual(Array(delays.dropFirst(4)), [.seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15), .seconds(15)])
        XCTAssertEqual(CallEngine.subscribeRetryDelay(afterFailures: 10_000), .seconds(15))
    }

    func testJoinedCallReadsAnOlderHubWithoutCapabilities() throws {
        let call = try JSONEncoder().encode(HQSimulatorFixture().calls[0])
        let callJSON = try XCTUnwrap(String(data: call, encoding: .utf8))
        let older = #"{"call":\#(callJSON),"session_id":"s","generation":1}"#
        let newer = #"{"call":\#(callJSON),"session_id":"s","generation":1,"capabilities":["quiet_tracks"]}"#
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(HQClient.JoinedCall.self, from: Data(older.utf8)).capabilities)
        XCTAssertEqual(
            try decoder.decode(HQClient.JoinedCall.self, from: Data(newer.utf8)).capabilities,
            ["quiet_tracks"]
        )
    }

    func testProcessedMicrophoneModesDoNotTriggerCaptureComparison() {
        XCTAssertTrue(CallEngine.areCaptureLevelsComparable(in: .standard))
        XCTAssertFalse(CallEngine.areCaptureLevelsComparable(in: .voiceIsolation))
        XCTAssertFalse(CallEngine.areCaptureLevelsComparable(in: .wideSpectrum))
    }
}
