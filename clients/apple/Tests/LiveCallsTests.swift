import XCTest

@testable import HQ

/// Live calls through the app's real `HQClient` and `EventSocket` against a real HQ Community
/// server: no fixtures and no mocks. The server's media relay is the fake SFU in the server's
/// `test/fake-sfu.ts`, so SDP goes back and forth but no media flows; `CallEngine` is not run.
///
/// Skipped unless all three are set, as `LiveServerTests` is (pass them through `TEST_RUNNER_`,
/// which `xcodebuild` strips before handing them to the test host):
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada
///     HQ_LIVE_KEY_B    an invite key for a member named Bo
///
/// The server needs calls turned on (`HQ_CALLS_SFU_*` pointing at the fake) and, for the
/// recording tests, its stand-in speech-to-text (`HQ_STT_PROVIDER=mock`). Every run leaves
/// ended calls in Ada and Bo's history, so run this class after `LiveServerTests`, which expects
/// none on a fresh server.
@MainActor
final class LiveCallsTests: XCTestCase {
    private struct Who {
        let response: HQClient.EnrollResponse
        var client: HQClient { HQClient(bearer: response.bearer) }
        var id: String { response.person.id }
        var name: String { response.person.name }
    }

    private struct Timeout: Error {}

    @MainActor
    private final class FrameLog {
        private(set) var frames: [ServerFrame] = []
        func record(_ frame: ServerFrame) { frames.append(frame) }

        /// Frames the app could not read, or an error the server sent back.
        var undecodable: [ServerFrame] {
            frames.filter {
                switch $0 {
                case .unknown, .serverError: return true
                default: return false
                }
            }
        }

        func wait<T>(
            _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
            _ match: (ServerFrame) -> T?
        ) async throws -> T {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                for frame in frames { if let found = match(frame) { return found } }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("no \(what) within \(Int(timeout))s", file: file, line: line)
            throw Timeout()
        }
    }

    private var keyA: String!
    private var keyB: String!
    private var previousServer: String?
    private var sockets: [EventSocket] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            let text = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let server = value("HQ_LIVE_SERVER"), let keyA = value("HQ_LIVE_KEY_A"),
              let keyB = value("HQ_LIVE_KEY_B")
        else { throw XCTSkip("HQ_LIVE_SERVER, HQ_LIVE_KEY_A and HQ_LIVE_KEY_B are not all set") }
        XCTAssertFalse(HQSimulatorFixture.isEnabled, "a live run must not be a fixture run")
        guard case .success(let normalized) = HQConfig.normalizedServer(server) else {
            throw XCTSkip("HQ_LIVE_SERVER is not a usable server address")
        }
        self.keyA = keyA
        self.keyB = keyB
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
    }

    override func tearDown() async throws {
        for socket in sockets { socket.stop() }
        sockets = []
        if keyA != nil { HQConfig.savedServer = previousServer }
    }

    // MARK: - Helpers

    private func signIn(_ key: String, _ name: String) async throws -> Who {
        Who(response: try await HQClient.enroll(key: key, personName: nil, deviceName: "LiveCallsTests \(name)"))
    }

    /// The app's event socket, connected, with every frame it decodes kept.
    private func openSocket(_ who: Who) async throws -> (EventSocket, FrameLog) {
        let log = FrameLog()
        let socket = EventSocket(bearer: who.response.bearer, onConnect: {}, onFrame: { log.record($0) })
        sockets.append(socket)
        socket.connect()
        _ = try await log.wait("hello for \(who.name)") {
            if case .hello(let device, _, _) = $0, device == who.response.deviceId { return true }
            return nil
        }
        return (socket, log)
    }

    /// An offer as WebRTC writes one before gathering: a sendonly audio and video section.
    private let offer = [
        "v=0", "o=- 4611731400430051336 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE 0 1",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0", "a=mid:0", "a=sendonly", "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2",
        "m=video 9 UDP/TLS/RTP/SAVPF 96", "c=IN IP4 0.0.0.0", "a=mid:1", "a=sendonly", "a=rtcp-mux",
        "a=rtpmap:96 VP8/90000", "",
    ].joined(separator: "\r\n")

    // MARK: - Tests

    func testAdaCallsBoWhoHearsTheRingAndDeclines() async throws {
        let ada = try await signIn(keyA, "Ada")
        let bo = try await signIn(keyB, "Bo")
        let (_, boLog) = try await openSocket(bo)
        let dm = try await ada.client.createDM(personId: bo.id)

        let joined = try await ada.client.startCall(kind: "conversation", conversationId: dm.id, meetingId: nil)
        let callId = joined.call.id
        // CallKit takes the id as a UUID, compared lower-cased.
        XCTAssertEqual(UUID(uuidString: callId)?.uuidString.lowercased(), callId)
        XCTAssertEqual(joined.capabilities, ["quiet_tracks"])
        XCTAssertEqual(joined.generation, 1)
        XCTAssertTrue(joined.call.isLive)
        XCTAssertEqual(joined.call.presentParticipants.map(\.personId), [ada.id])

        // Bo's real socket rings, and his snapshot lists it.
        let ring = try await boLog.wait("call_ring") {
            if case .callRing(let ring) = $0, ring.call.id == callId { return ring }
            return nil
        }
        XCTAssertEqual(ring.callerName, ada.name)
        XCTAssertNil(ring.conversationTitle)
        XCTAssertGreaterThan(ring.expiresDate, Date())
        let ringing = try await bo.client.calls().ringing
        XCTAssertEqual(ringing.map(\.call.id), [callId])
        let adaRinging = try await ada.client.calls().ringing
        XCTAssertTrue(adaRinging.isEmpty)

        // Declining stops it, on the socket and in the snapshot, and leaves the call alone.
        try await bo.client.declineCall(callId: callId)
        _ = try await boLog.wait("call_ring_ended") {
            if case .callRingEnded(let id) = $0, id == callId { return true }
            return nil
        }
        let afterDecline = try await bo.client.calls().ringing
        XCTAssertTrue(afterDecline.isEmpty)
        let stillOn = try await ada.client.callRoster(callId: callId)
        XCTAssertTrue(stillOn.isLive)

        try await ada.client.leaveCall(callId: callId)
        let ended = try await boLog.wait("call_ended") {
            if case .callEnded(let id, let endedAt) = $0, id == callId { return endedAt }
            return nil
        }
        XCTAssertFalse(ended.isEmpty)
        XCTAssertTrue(boLog.undecodable.isEmpty, "Bo's socket got frames the app could not read")
    }

    func testPublishSubscribeStateHeartbeatLeaveAndTheRecord() async throws {
        let ada = try await signIn(keyA, "Ada")
        let bo = try await signIn(keyB, "Bo")
        let (adaSocket, adaLog) = try await openSocket(ada)
        let (_, boLog) = try await openSocket(bo)
        let dm = try await ada.client.createDM(personId: bo.id)
        let joined = try await ada.client.startCall(kind: "conversation", conversationId: dm.id, meetingId: nil)
        let callId = joined.call.id

        // Ada publishes her mic and a camera that starts off; the answer carries her offer's mids.
        let answer = try await ada.client.publish(
            callId: callId,
            offer: .init(sdp: offer, type: "offer"),
            tracks: [(mid: "0", source: "mic", isEnabled: nil), (mid: "1", source: "cam", isEnabled: false)]
        )
        XCTAssertEqual(answer.sessionDescription.type, "answer")
        XCTAssertTrue(answer.sessionDescription.sdp.contains("a=mid:0"))
        XCTAssertTrue(answer.sessionDescription.sdp.contains("a=mid:1"))
        XCTAssertTrue(answer.refused.isEmpty)

        // The quiet camera shows only once its flag is on; untold flags stay as they were.
        var call = try await ada.client.callRoster(callId: callId)
        XCTAssertEqual(call.liveTracks(from: "mic").map(\.trackName), ["\(ada.response.deviceId)-mic"])
        XCTAssertTrue(call.liveTracks(from: "cam").isEmpty)
        call = try await ada.client.setCallState(callId: callId, changes: [.cameraOn(true)])
        XCTAssertEqual(call.liveTracks(from: "cam").map(\.trackName), ["\(ada.response.deviceId)-cam"])
        call = try await ada.client.setCallState(callId: callId, changes: [.muted(true)])
        let seat = try XCTUnwrap(call.presentParticipants.first { $0.personId == ada.id })
        XCTAssertTrue(seat.isMuted)
        XCTAssertTrue(seat.isCameraOn)

        // Bo answers, and Ada's socket sees him join.
        let boJoined = try await bo.client.startCall(kind: "conversation", conversationId: dm.id, meetingId: nil)
        XCTAssertEqual(boJoined.call.id, callId)
        XCTAssertNotEqual(boJoined.sessionId, joined.sessionId)
        _ = try await adaLog.wait("call_state with Bo in it") {
            if case .callState(let state) = $0, state.id == callId,
               state.presentParticipants.contains(where: { $0.personId == bo.id }) { return true }
            return nil
        }

        // Bo reads the roster (his heartbeat) and pulls Ada's mic; the relay's offer is answered.
        let roster = try await bo.client.callRoster(callId: callId)
        let mic = try XCTUnwrap(roster.liveTracks(from: "mic").first { $0.personId == ada.id })
        XCTAssertEqual(mic.sessionId, joined.sessionId)
        let pulled = try await bo.client.subscribe(callId: callId, tracks: [(sessionId: mic.sessionId, trackName: mic.trackName)])
        XCTAssertTrue(pulled.shouldRenegotiate)
        XCTAssertEqual(pulled.sessionDescription?.type, "offer")
        let mid = try XCTUnwrap(pulled.tracks.first?.mid)
        XCTAssertEqual(pulled.tracks.first?.trackName, mic.trackName)
        XCTAssertNil(pulled.tracks.first?.errorCode)
        XCTAssertTrue(pulled.sessionDescription?.sdp.contains("a=mid:\(mid)") == true)
        try await bo.client.renegotiate(callId: callId, answer: .init(sdp: "v=0\r\n", type: "answer"))
        // A track that is not in the roster is refused by name, not passed on.
        let stranger = try await bo.client.subscribe(
            callId: callId, tracks: [(sessionId: "elsewhere", trackName: mic.trackName)]
        )
        XCTAssertEqual(stranger.tracks.first?.errorCode, "unknown_track")
        XCTAssertFalse(stranger.shouldRenegotiate)
        try await bo.client.unsubscribe(callId: callId, mids: [mid])
        try await ada.client.unpublish(callId: callId, mids: ["1"], sources: ["cam"])
        call = try await ada.client.callRoster(callId: callId)
        XCTAssertTrue(call.liveTracks(from: "cam").isEmpty)

        // The socket heartbeat is taken without an error.
        adaSocket.send(["type": "call_heartbeat", "call_id": callId])
        _ = try await ada.client.callRoster(callId: callId)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(adaLog.undecodable.isEmpty, "Ada's socket got an error or a frame the app could not read")

        // Both leave: the call ends for both of them.
        try await bo.client.leaveCall(callId: callId)
        try await ada.client.leaveCall(callId: callId)
        for log in [adaLog, boLog] {
            _ = try await log.wait("call_ended") {
                if case .callEnded(let id, _) = $0, id == callId { return true }
                return nil
            }
        }

        // The record decodes: the ended call, nothing written down yet.
        let record = try await ada.client.callRecord(callId: callId)
        XCTAssertEqual(record.call.id, callId)
        XCTAssertFalse(record.call.isLive)
        XCTAssertTrue(record.transcript.isEmpty)
        XCTAssertTrue(record.recordings.isEmpty)
        XCTAssertNil(record.health)
        let history = try await bo.client.calls()
        XCTAssertEqual(history.calls.first { $0.id == callId }?.isLive, false)
        XCTAssertTrue(boLog.undecodable.isEmpty, "Bo's socket got frames the app could not read")
    }

    // MARK: - Recordings and transcripts
    //
    // These need the server's speech-to-text set to its stand-in (`HQ_STT_PROVIDER=mock`), which
    // answers every piece of audio with a line of text.

    /// One second of 16 kHz mono 16-bit audio in ten frames, as `MeetingTranscriber` sends it.
    private let frames: [Data] = (0..<10).map { _ in
        let samples = [Int16](repeating: 1200, count: 1600)
        return samples.withUnsafeBytes { Data($0) }
    }

    /// Ada calls Bo, who does not answer, and streams her microphone over the app's transcribe
    /// socket with the bearer header; then she hangs up, which ends the call.
    private func callWithAudio(_ ada: Who, _ bo: Who) async throws -> String {
        let dm = try await ada.client.createDM(personId: bo.id)
        let joined = try await ada.client.startCall(kind: "conversation", conversationId: dm.id, meetingId: nil)
        let callId = joined.call.id
        let url = try XCTUnwrap(HQConfig.webSocketURL(path: "/v1/calls/\(callId)/transcribe"))
        var request = URLRequest(url: url)
        request.setValue("Bearer \(ada.response.bearer)", forHTTPHeaderField: "Authorization")
        let feed = URLSession.shared.webSocketTask(with: request)
        feed.resume()
        defer { feed.cancel(with: .normalClosure, reason: nil) }
        // The feed answers the app's keepalive.
        try await feed.send(.string("ping"))
        let reply = try await feed.receive()
        guard case .string(let pong) = reply else {
            XCTFail("the feed answered a ping with something other than text")
            return callId
        }
        XCTAssertEqual(pong, "pong")
        for frame in frames { try await feed.send(.data(frame)) }
        // A ping answered after the frames means the server has taken them all.
        try await feed.send(.string("ping"))
        _ = try await feed.receive()
        try await ada.client.leaveCall(callId: callId)
        return callId
    }

    /// The record once the server has written the transcript, read as the app reads it.
    private func finishedRecord(_ who: Who, _ callId: String) async throws -> CallRecord {
        let deadline = Date().addingTimeInterval(15)
        while true {
            let record = try await who.client.callRecord(callId: callId)
            if !record.transcript.isEmpty || Date() > deadline { return record }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func testTheAudioFeedBecomesARecordingAndATranscript() async throws {
        let ada = try await signIn(keyA, "Ada")
        let bo = try await signIn(keyB, "Bo")
        let before = Date()
        let callId = try await callWithAudio(ada, bo)

        let record = try await finishedRecord(bo, callId)
        XCTAssertFalse(record.call.isLive)
        XCTAssertEqual(record.recordings.count, 1)
        let recording = try XCTUnwrap(record.recordings.first)
        XCTAssertEqual(recording.deviceId, ada.response.deviceId)
        XCTAssertEqual(recording.personId, ada.id)
        XCTAssertEqual(recording.name, ada.name)
        XCTAssertEqual(recording.seconds, 1)
        XCTAssertTrue(record.hasAudio)
        let line = try XCTUnwrap(record.transcript.first, "no transcript line from the mock speech-to-text")
        XCTAssertEqual(line.personId, ada.id)
        XCTAssertEqual(line.name, ada.name)
        XCTAssertFalse(line.text.isEmpty)
        // An absolute time, in the call.
        XCTAssertGreaterThanOrEqual(line.atMs, before.timeIntervalSince1970 * 1000 - 2000)
        XCTAssertLessThanOrEqual(line.atMs, Date().timeIntervalSince1970 * 1000)
        XCTAssertNil(record.health)
    }

    func testTheRecordingDownloadsThroughHQClient() async throws {
        let ada = try await signIn(keyA, "Ada")
        let bo = try await signIn(keyB, "Bo")
        let callId = try await callWithAudio(ada, bo)
        _ = try await finishedRecord(ada, callId)

        // Bo, in the room, downloads Ada's microphone as the record view does.
        let wav = try await bo.client.recordingData(callId: callId, deviceId: ada.response.deviceId)
        XCTAssertEqual(wav.count, 44 + 32_000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        let rate = wav[24..<28].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(rate, 16_000)
        let first = Int16(bitPattern: UInt16(wav[44]) | UInt16(wav[45]) << 8)
        XCTAssertEqual(first, 1200)
        // A device with no audio has no recording.
        do {
            _ = try await bo.client.recordingData(callId: callId, deviceId: bo.response.deviceId)
            XCTFail("a device that sent no audio has no recording")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 404)
        }
    }
}
