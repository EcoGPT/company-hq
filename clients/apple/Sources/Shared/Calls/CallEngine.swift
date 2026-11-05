import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import Foundation
import Observation
import os
import WebRTC

// Call diagnostics land in the unified log so any teammate can hand over a
// `log show --predicate 'subsystem == "<bundle id>"'` dump after a shaky
// meeting. Ids and device names are infrastructure, not user content, so
// they log as public.
private let callLog = Logger(subsystem: HQIdentity.logSubsystem, category: "call")

// One peer connection per device, the way the SFU expects: local tracks are
// published sendonly, everyone else's arrive as receive-only transceivers the
// switchboard told us to subscribe to. The engine owns media; AppStore owns the
// call's roster and keeps this in sync with it.
@MainActor
@Observable
final class CallEngine: NSObject {
    enum Stage: Equatable {
        case idle
        case joining
        case live
        case reconnecting
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    private(set) var callId: String?
    private(set) var sessionId: String?
    /// Remote video by track name, so a tile can look up exactly its own stream.
    private(set) var remoteVideo: [String: RTCVideoTrack] = [:]
    private(set) var localVideo: RTCVideoTrack?
    private(set) var isMicrophoneOn = true
    private(set) var isCameraOn = false
    private(set) var isScreenSharing = false
    /// Devices whose audio is above the speaking floor right now.
    private(set) var speakingDeviceIds: Set<String> = []
    /// This device, above the same floor. It has to be read separately: the
    /// set above comes from inbound-rtp stats, which carry everyone except
    /// you, so your own tile was the one tile that never lit.
    private(set) var isSelfSpeaking = false
    /// A short-lived, user-facing line about a self-heal ("Microphone
    /// changed to AirPods — reconnecting…"); MeetingView toasts it.
    private(set) var transientNotice: String?
    /// Mic truth: speech detected while the mic is off, and a mic that has
    /// produced only digital silence long enough to be presumed dead.
    private(set) var isTalkingWhileMuted = false
    private(set) var isMicSilent = false

    private var factory: RTCPeerConnectionFactory
    private var shouldRebuildAudioDevice = false
    private var connection: RTCPeerConnection?
    private var client: HQClient?
    private var audioSender: RTCRtpSender?
    private var videoSender: RTCRtpSender?
    private var screenSender: RTCRtpSender?
    private var videoCapturer: RTCCameraVideoCapturer?
    /// The uniqueID of the device actually capturing, nil when capture is
    /// dead — the disconnect handler keys off it to re-acquire.
    private var activeCameraId: String?
    #if !os(macOS)
    /// Which way the phone's camera is pointing. Observable so the flip
    /// control can draw its own state.
    private(set) var isUsingFrontCamera = true
    #endif
    #if os(macOS)
    private var screenCapturer: ScreenShareCapturer?
    /// A second click while the first share is still asking for capture
    /// started a second capturer on the same source, which kept capturing
    /// after Stop.
    private var isStartingScreenShare = false
    #endif
    // Both platforms: the processor sits between the camera capturer and the
    // video source, so it needs nothing platform-specific under it — see
    // `BackgroundBlurProcessor`.
    private var backgroundBlurProcessor: BackgroundBlurProcessor?
    private(set) var isBackgroundBlurred = false
    private var videoSource: RTCVideoSource?
    private var screenSource: RTCVideoSource?
    /// Subscriptions already made, keyed by "trackName@sessionId" — the
    /// session matters: a publisher's rejoin keeps its track NAMES (they are
    /// derived from the device id) but moves them to a fresh SFU session, and
    /// a set keyed by name alone never resubscribed — the rejoiner's tile
    /// froze and their audio went silent for everyone until the call ended.
    private var subscribed: Set<String> = []
    /// Failed subscribe attempts per "trackName@sessionId", so a track the
    /// SFU answers with an error (a publish still settling after a rejoin
    /// reads as empty_track_error) is retried a few times instead of being
    /// a permanent black tile — and a genuinely dead one is given up on.
    private var subscribeFailures: [String: Int] = [:]
    private var midToTrackName: [String: String] = [:]
    /// Which subscription each receive mid belongs to, so forgetting a
    /// subscription also forgets its receiver: a publisher's rejoin keeps the
    /// track NAME, and the old receiver — still mapped to that name — went on
    /// painting its last frame over the tile.
    private var midToSubscriptionKey: [String: String] = [:]
    /// The subscription each attached remote video came from.
    private var remoteVideoKey: [String: String] = [:]
    /// Inbound video packet counts per track name at the last stats sample,
    /// and how many samples in a row they stood still — a subscription that
    /// stops delivering froze its tile until the roster happened to change.
    private var inboundVideoProgress: [String: (packets: Int, stillSamples: Int)] = [:]
    /// Resubscriptions spent per subscription on a stalled stream, capped so
    /// a publisher whose capture is dead costs two retries, not one a minute.
    private var stallResubscribes: [String: Int] = [:]
    /// Receiver track id → the HQ track name it carries, so an audio level can
    /// be traced back to a person.
    private var trackIdToTrackName: [String: String] = [:]
    private var levelTimer: Timer?
    private var levelPollCount = 0
    /// Bumped every time the peer connection is torn down. Negotiation awaits
    /// the network, and a pass begun on the old connection used to finish on
    /// the new one after a rejoin — its subscribe landing on the fresh SFU
    /// session mid-publish, and its unlock releasing the new publish's lock
    ///. Every await is followed by a check against this.
    private var connectionGeneration = 0
    /// The generation that holds the one-negotiation-at-a-time lock. A lock
    /// taken on an older connection is simply not held any more.
    private var negotiatingGeneration: Int?
    private var isNegotiating: Bool { negotiatingGeneration == connectionGeneration }
    /// Set when libwebrtc rejected a description on this connection. Its
    /// session error is sticky — every later offer and answer fails the same
    /// way — so the only repair is a new connection, and nothing negotiates
    /// on this one meanwhile.
    private var isConnectionPoisoned = false
    /// The hub understands switched-off tracks (`quiet_tracks`): the camera
    /// and screen are negotiated at join, published off, and toggled with a
    /// flag. Against an older hub the engine adds them when first turned on.
    private var hasQuietTracks = false
    /// The self-heal hook: rebuild the connection after ICE loss or an
    /// input-route change. AppStore supplies the server round trip.
    var onConnectionLost: (() async -> Void)?
    private var reconnectTask: Task<Void, Never>?
    /// Whether the pending recovery is ICE's own: only those are called off
    /// when ICE comes back. A dead seat or a poisoned connection is not fixed
    /// by the network reconnecting.
    private var isPendingRecoveryICE = false
    /// A recovery asked for while another was running. The running one is
    /// usually the rejoin that just failed, and dropping the request left
    /// the call reading "reconnecting" forever with no media.
    private var isRecoveryOwed = false
    private var reconnectAttempts = 0
    /// When ICE last reached connected on this connection. The recovery
    /// budget comes back only after a connection has held for a while: one
    /// that connects and then poisons itself again would otherwise rejoin
    /// forever instead of saying it cannot.
    private var connectedSince: Date?
    #if os(macOS)
    /// The default input and output devices this connection's audio was
    /// built on. WebRTC's audio device keeps the device it opened, so
    /// plugging in AirPods left the call playing through the speakers — or
    /// through nothing once the old device went away.
    private var connectedInputDevice: AudioObjectID?
    private var connectedOutputDevice: AudioObjectID?
    private var audioDeviceTask: Task<Void, Never>?
    private var lastAudioDeviceRebuildAt: Date?
    private var audioDeviceRebuildCount = 0
    #endif
    // True from the moment a recovery fires until its rejoin settles. The
    // scheduled task nils reconnectTask before the round trip, so without
    // this a second ICE event mid-rejoin ran a second full rejoin on the
    // same engine — two SFU sessions, and the local media publishing into
    // whichever one lost.
    private var isRecovering = false
    private var noticeTask: Task<Void, Never>?
    private var mutedLoudStreak = 0
    private var selfSpeakingUntil: Date?
    private var constrainedVideoStreak = 0
    private var clearVideoStreak = 0
    /// How far the encoder is scaling the camera down right now: 1 is full
    /// resolution, 4 is the floor. The call degrades quality under sustained
    /// constraint; it never takes the camera away.
    private var videoScaleDownBy: Double = 1
    private var lastAudibleAt: Date?
    /// The last time the input tap carried SPEECH, not merely sound. The
    /// mic-death check reads this and never `lastAudibleAt`: that one is the
    /// noise floor (peak 0.001, which a fan clears), and a room being audible
    /// is not evidence that this Mac's microphone works.
    private var lastTapSpeechAt: Date?
    private var tapSpeechStreak = 0
    /// The last time WebRTC's own capture produced sound, as its media-source
    /// stats report it. Read against `lastTapSpeechAt` — which comes from the
    /// transcriber's separate tap — this is the only honest evidence that the
    /// microphone WebRTC holds has died while the machine's mic is fine.
    private var lastCapturedAudibleAt: Date?
    private var lastMicRecoveryAt: Date?
    /// How many rejoins this call has already spent on the mic-death check.
    /// Two that do not bring the capture back prove rejoining is not the
    /// remedy, and a third is just another dropout for everyone else.
    private var micRecoveryCount = 0
    private var hasGivenUpOnMicRecovery = false
    private var liveSince: Date?
    private var lastNudgeClearedAt: Date?
    /// The last roster the store handed us, so a failed or skipped subscribe
    /// can retry on its own instead of waiting for the next roster change.
    private var latestCall: Call?
    private var latestDeviceId: String?
    private var resyncTask: Task<Void, Never>?
    /// Best-effort mic feed to the server's transcription endpoint while a meeting
    /// runs; the server does nothing with it when speech-to-text isn't configured.
    private let transcriber = MeetingTranscriber()

    override init() {
        #if os(iOS)
        CallAudioConfiguration.install()
        #endif
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        super.init()
        // Continuity Camera comes and goes with the phone that backs it, and
        // AirPods rewire the input route — both are prime "my camera/mic just
        // died" suspects, so every device change leaves a line.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let device = note.object as? AVCaptureDevice
                let isConnect = name == AVCaptureDevice.wasConnectedNotification
                let change = isConnect ? "connected" : "disconnected"
                let deviceName = device?.localizedName ?? "?"
                callLog.warning("capture device \(change, privacy: .public): \(deviceName, privacy: .public)")
                MainActor.assumeIsolated {
                    self?.handleCaptureDeviceChange(device, isConnect: isConnect)
                }
            }
        }
        observeDefaultInputChanges()
        transcriber.onLevel = { [weak self] level in self?.noteInputLevel(level) }
    }

    // Meet's signature save, both directions: mute keeps the level tap
    // flowing, so speech while muted can nudge — and an unmuted mic that
    // only ever produces digital silence is presumed dead and said so.
    private func noteInputLevel(_ level: Float) {
        guard stage == .live else { return }
        if level > 0.001 {
            lastAudibleAt = Date()
            if isMicSilent { isMicSilent = false }
        }
        // Speech, on the same leaky counter the muted nudge uses: ~1s of it at
        // the tap's ~12 buffers/s, so one slammed door does not read as a
        // person talking. Kept whether muted or not, because the mic-death
        // check runs unmuted and the nudge's own streak does not.
        if level > 0.05 {
            tapSpeechStreak = min(tapSpeechStreak + 1, 20)
        } else if tapSpeechStreak > 0 {
            tapSpeechStreak -= 1
        }
        if tapSpeechStreak >= 10 { lastTapSpeechAt = Date() }
        noteSelfSpeaking(level)
        if isMicrophoneOn {
            mutedLoudStreak = 0
            if isTalkingWhileMuted { isTalkingWhileMuted = false }
            return
        }
        if level > 0.05 {
            mutedLoudStreak += 1
        } else if mutedLoudStreak > 0 {
            mutedLoudStreak -= 1
        }
        // ~1s of speech (the tap fires ~12×/s), with a cooldown so it
        // nudges rather than nags.
        if !isTalkingWhileMuted, mutedLoudStreak >= 10 {
            let isCooledDown = lastNudgeClearedAt.map { Date().timeIntervalSince($0) > 20 } ?? true
            if isCooledDown {
                callLog.info("talking while muted")
                isTalkingWhileMuted = true
            }
        }
        if isTalkingWhileMuted, mutedLoudStreak == 0 {
            isTalkingWhileMuted = false
            lastNudgeClearedAt = Date()
        }
    }

    // Meet lights the tile of whoever is talking, and the tile that never lit
    // was your own — so there was no way to tell a live mic from a dead one
    // without asking the room. The input tap is the local equivalent of the
    // inbound levels, read at the same floor as the muted nudge, with a short
    // hangover so the stroke holds through the gaps between words instead of
    // strobing on every syllable.
    private func noteSelfSpeaking(_ level: Float) {
        guard isMicrophoneOn else {
            selfSpeakingUntil = nil
            if isSelfSpeaking { isSelfSpeaking = false }
            return
        }
        if level > 0.05 { selfSpeakingUntil = Date().addingTimeInterval(0.5) }
        let isSpeaking = selfSpeakingUntil.map { $0 > Date() } ?? false
        if isSpeaking != isSelfSpeaking { isSelfSpeaking = isSpeaking }
    }

    // The camera a tile depends on can vanish mid-call (a Continuity Camera
    // iPhone locking or walking off). Re-acquire instead of leaving a black
    // tile: on losing the active device, restart onto whatever remains; on
    // a device appearing while the camera is wanted but dead, try again.
    private func handleCaptureDeviceChange(_ device: AVCaptureDevice?, isConnect: Bool) {
        guard isCameraOn, device?.hasMediaType(.video) == true else { return }
        if isConnect {
            guard activeCameraId == nil else { return }
        } else {
            guard let lost = device?.uniqueID, lost == activeCameraId else { return }
            activeCameraId = nil
            showNotice("Camera disconnected — switching…")
        }
        Task { @MainActor [weak self] in await self?.didStartCamera() }
    }

    // WebRTC's audio device keeps the devices it opened: AirPods
    // disconnecting mid-call left the mic dead for everyone until a manual
    // rejoin (seen live), and connecting them left the call
    // playing through the speakers. This build exposes no audio-device
    // module, so a fresh audio device (a new factory, the path an iOS media
    // reset already takes) is the one way to follow the system. That is a
    // rejoin, which everyone sees, so it is spent only on a change that
    // matters: the default OUTPUT moving (the person can no longer hear the
    // room where they expect to), or the input the call opened disappearing.
    // A new default input beside a live old one is left to the mic-death
    // check in pollLevels.
    private func observeDefaultInputChanges() {
        #if os(macOS)
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main
            ) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.stage == .live else { return }
                    if selector == kAudioHardwarePropertyDefaultInputDevice {
                        let inputName = AVCaptureDevice.default(for: .audio)?.localizedName
                        callLog.warning("default input changed to \(inputName ?? "?", privacy: .public)")
                        // Give the new route a moment before the capture check
                        // can call it dead.
                        self.lastCapturedAudibleAt = Date()
                    } else {
                        callLog.warning("default output changed")
                    }
                    self.scheduleAudioDeviceCheck()
                }
            }
        }
        #else
        // iOS has no device list to watch — the session has a route, and it
        // changes when AirPods connect, the phone is unplugged, or a call
        // interrupts. Same job, same one line of notice: say what moved and
        // give the new route a moment before the mic-death check can fire.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.stage == .live else { return }
                let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                // A category change is HQ itself configuring the session, not
                // a microphone moving out from under the user.
                guard reason != .categoryChange, reason != .routeConfigurationChange else { return }
                let inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
                callLog.warning("audio route changed to \(inputName ?? "?", privacy: .public)")
                self.showNotice("Microphone changed\(inputName.map { " to \($0)" } ?? "")")
                self.lastCapturedAudibleAt = Date()
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteAudioServicesReset() }
        }
        #endif
    }

    #if os(macOS)
    /// Device changes arrive in bursts (AirPods switch input and output a
    /// moment apart, and macOS builds aggregate devices for voice processing),
    /// so the decision waits for the system to settle and then compares what
    /// the defaults are against what this connection opened.
    private func scheduleAudioDeviceCheck() {
        audioDeviceTask?.cancel()
        audioDeviceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, self.stage == .live else { return }
            self.audioDeviceTask = nil
            self.followAudioDevicesIfNeeded()
        }
    }

    private func followAudioDevicesIfNeeded() {
        let output = Self.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let hasOutputMoved = output != nil && output != connectedOutputDevice
            && !Self.isAggregateDevice(output)
        let hasInputVanished = connectedInputDevice.map { !Self.isAudioDeviceAlive($0) } ?? false
        guard hasOutputMoved || hasInputVanished else { return }
        // A device that keeps flapping must not turn into a rejoin loop:
        // one rebuild per 20s, four per call, then the route is left alone.
        let isCooledDown = lastAudioDeviceRebuildAt.map { Date().timeIntervalSince($0) > 20 } ?? true
        guard isCooledDown, audioDeviceRebuildCount < 4 else {
            callLog.warning("audio device changed again; not rebuilding (cooldown or budget)")
            return
        }
        audioDeviceRebuildCount += 1
        lastAudioDeviceRebuildAt = Date()
        let reason = hasOutputMoved ? "default output changed" : "input device disappeared"
        callLog.warning("\(reason, privacy: .public); rebuilding the call audio device")
        showNotice("Switching audio devices…")
        shouldRebuildAudioDevice = true
        // Its own budget above; a person moving between AirPods and speakers
        // must not use up the strikes that end a genuinely broken call.
        scheduleRecovery(reason: reason, after: .zero, countsAsStrike: false)
    }

    private func recordConnectedAudioDevices() {
        connectedInputDevice = Self.defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
        connectedOutputDevice = Self.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func isAudioDeviceAlive(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    /// The aggregate devices macOS assembles for voice processing come and go
    /// under a live call (`CADefaultDeviceAggregate-…`); following one would
    /// rebuild the audio for nothing.
    private static func isAggregateDevice(_ device: AudioObjectID?) -> Bool {
        guard let device else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else { return false }
        return (value as String).hasPrefix("CADefaultDeviceAggregate")
    }
    #endif

    func noteAudioServicesReset() {
        // ICE can stay connected while iOS invalidates every audio unit.
        // A new peer on the old factory would still use its dead audio device.
        shouldRebuildAudioDevice = true
        callLog.error("audio services reset; rebuilding the call audio device")
        scheduleRecovery(reason: "audio services reset", after: .seconds(1))
    }

    #if !os(macOS)
    /// WebRTC drives the audio unit but not the session category, and the
    /// default category is playback-only — without this the phone joins a
    /// call it can hear and cannot speak into. `.videoChat` picks the
    /// echo-cancelling route and keeps the speaker live, which is what a
    /// meeting on a phone held at arm's length needs; Bluetooth is allowed so
    /// AirPods work the way they do in every other call app.
    ///
    /// Configuration goes through `RTCAudioSession`'s lock: WebRTC configures
    /// the same singleton, and two writers without it race into a session
    /// that is neither what HQ asked for nor what WebRTC did.
    private func configureAudioSession(isActive: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            if isActive {
                try session.setCategory(
                    .playAndRecord,
                    mode: .videoChat,
                    options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
                )
            }
            // When CallKit answered the call, the OS owns activation: it
            // activates the session itself and tells us through the
            // provider's didActivate. Claiming it here on top of that is a
            // race WebRTC loses — the lock-screen answer connects silent.
            if !session.useManualAudio {
                try session.setActive(isActive)
            }
        } catch {
            let verb = isActive ? "activate" : "deactivate"
            let reason = String(describing: error)
            callLog.error("audio session \(verb, privacy: .public) failed: \(reason, privacy: .public)")
        }
    }

    // MARK: - CallKit's audio handoff

    /// Before a CallKit-answered join: WebRTC must wait for the system's
    /// activation callback instead of starting audio on its own clock.
    nonisolated static func callKitWillDrive() {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
        callLog.notice("audio waiting for CallKit activation")
    }

    nonisolated static func callKitDidActivate(_ audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidActivate(audioSession)
        session.isAudioEnabled = true
    }

    nonisolated static func callKitDidDeactivate(_ audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidDeactivate(audioSession)
        session.useManualAudio = false
    }

    /// CallKit refused the start action after `callKitWillDrive` armed manual
    /// audio: no didActivate is coming, so WebRTC takes the session back the
    /// classic way — the call is already joining and must not stay silent.
    nonisolated static func callKitStartFailed() {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = false
        session.isAudioEnabled = true
        session.lockForConfiguration()
        try? session.setActive(true)
        session.unlockForConfiguration()
    }
    #endif

    // MARK: - Lifecycle

    func join(
        client: HQClient,
        joined: HQClient.JoinedCall,
        isCameraOn: Bool,
        isMicrophoneOn: Bool
    ) async {
        stage = .joining
        reconnectAttempts = 0
        // A new call, not a new seat in the old one: the mic-death budget and
        // its verdict start over.
        micRecoveryCount = 0
        hasGivenUpOnMicRecovery = false
        #if os(macOS)
        audioDeviceRebuildCount = 0
        lastAudioDeviceRebuildAt = nil
        #endif
        self.isMicrophoneOn = isMicrophoneOn
        self.isCameraOn = isCameraOn
        await connect(client: client, joined: joined)
    }

    /// A fresh seat in the same call after connection loss: the peer
    /// connection is rebuilt from nothing (capture re-acquires the current
    /// default devices) while mic/camera intent carries over.
    func rejoin(client: HQClient, joined: HQClient.JoinedCall) async {
        callLog.warning("rejoin call=\(joined.call.id, privacy: .public)")
        stage = .reconnecting
        transcriber.stop()
        await teardownConnection()
        await connect(client: client, joined: joined)
    }

    /// The rejoin round trip itself failed (network still down); try again
    /// on the recovery schedule instead of stalling in .reconnecting.
    func noteRecoveryFailed() {
        scheduleRecovery(reason: "rejoin request failed", after: .seconds(2))
    }

    private func connect(client: HQClient, joined: HQClient.JoinedCall) async {
        if shouldRebuildAudioDevice {
            factory = RTCPeerConnectionFactory(
                encoderFactory: RTCDefaultVideoEncoderFactory(),
                decoderFactory: RTCDefaultVideoDecoderFactory()
            )
            shouldRebuildAudioDevice = false
        }
        #if !os(macOS)
        configureAudioSession(isActive: true)
        #endif
        self.client = client
        callId = joined.call.id
        sessionId = joined.sessionId
        hasQuietTracks = joined.capabilities?.contains("quiet_tracks") ?? false
        let joinTrace = "call=\(joined.call.id) session=\(joined.sessionId)"
            + " camera=\(isCameraOn) mic=\(isMicrophoneOn) quiet=\(hasQuietTracks) build=\(HQBuildInfo.hash)"
        callLog.info("join \(joinTrace, privacy: .public)")
        #if os(macOS)
        recordConnectedAudioDevices()
        #endif

        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])]
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            callLog.error("peer connection init failed")
            stage = .failed("Could not start the media connection.")
            return
        }
        self.connection = connection

        addAudioTrack(to: connection)
        if hasQuietTracks {
            // The camera (and on the Mac the screen) is negotiated now, while
            // the connection has nothing but its own m-sections, and published
            // switched off. Turning either on later is a flag the hub relays,
            // never a new m-section: a sendonly video section added after the
            // subscriptions failed libwebrtc's send parameters on every
            // mid-call camera and broke the whole connection.
            addCameraSender(to: connection)
            if isCameraOn, !(await didStartCamera()) {
                isCameraOn = false
            }
            videoSender?.track?.isEnabled = isCameraOn
            #if os(macOS)
            addScreenSender(to: connection)
            #endif
        } else if isCameraOn, !(await didAddCameraTrack(to: connection)) {
            // No capture, no camera: leaving the flag up showed a lit toggle
            // over a tile publishing nothing.
            isCameraOn = false
        }

        do {
            let refused = try await publishPending()
            if isCameraOn, refused.contains("cam") {
                // The room never got the track; the toggle must not claim it.
                isCameraOn = false
                videoSender?.track?.isEnabled = false
                stopCamera()
            }
            stage = .live
            startLevelPolling()
            transcriber.setMuted(!isMicrophoneOn)
            // Every call — a meeting, a quick call, a call out of a DM — is
            // transcribed and recorded. The meeting-only gate here is why a
            // two-minute call could end with nothing written down at all.
            transcriber.start(callId: joined.call.id, bearer: client.bearer)
            liveSince = Date()
            // Capture starts the call presumed alive; a fresh join has no
            // history for the mic-death check to read as silence. The tap's
            // speech stamp stays nil on purpose — that check must be earned by
            // somebody actually talking, never assumed.
            lastAudibleAt = Date()
            lastCapturedAudibleAt = Date()
            // A fresh seat starts with every state flag zeroed server-side
            // (a rejoin's generation bump resets them): say what this device
            // actually is, or a muted person reads unmuted after recovery.
            var changes: [HQClient.CallStateChange] = []
            if !isMicrophoneOn { changes.append(.muted(true)) }
            // Said either way: an older hub marks a published camera on, and
            // against it this is what turns a switched-off one back off.
            if isCameraOn || hasQuietTracks { changes.append(.cameraOn(isCameraOn)) }
            if !changes.isEmpty {
                try? await client.setCallState(callId: joined.call.id, changes: changes)
            }
            // A reset during the join must wait for negotiation to finish.
            if shouldRebuildAudioDevice {
                scheduleRecovery(reason: "audio services reset during join", after: .seconds(1))
            }
        } catch is SupersededConnection {
            // A newer connection owns the call now; it reports for itself.
            return
        } catch {
            let reason = String(describing: error)
            callLog.error("join publish failed call=\(joined.call.id, privacy: .public): \(reason, privacy: .public)")
            // A rejected description is this connection's fault, not the
            // call's: a fresh one usually negotiates cleanly, so it recovers
            // like a dropped connection instead of failing the join outright.
            if stage == .reconnecting || shouldRebuildAudioDevice || error is NegotiationFailure {
                stage = .reconnecting
                scheduleRecovery(reason: "reconnect publish failed", after: .seconds(2))
            } else {
                stage = .failed(friendlyMessage(for: error))
            }
        }
    }

    func leave() async {
        let callId = self.callId
        let client = self.client
        callLog.info("leave call=\(callId ?? "-", privacy: .public)")
        transcriber.stop()
        await teardownConnection()
        reconnectAttempts = 0
        isRecoveryOwed = false
        latestCall = nil
        latestDeviceId = nil
        self.callId = nil
        sessionId = nil
        stage = .idle
        #if !os(macOS)
        // Hand the route back: leaving a call with the session still active
        // leaves the phone in speakerphone mode for whatever plays next.
        configureAudioSession(isActive: false)
        #endif
        if let callId, let client { try? await client.leaveCall(callId: callId) }
    }

    /// Everything owned by the current peer connection, gone. Senders, the
    /// capturer, and both video sources belong to the closed connection —
    /// anything kept here feeds a dead object (a stale videoSender used to
    /// survive leave() and silently broke the camera toggle on the next
    /// call; a reused capturer would deliver frames to the old source).
    private func teardownConnection() async {
        // First, before any await below: every negotiation still in flight on
        // this connection must find it superseded the moment it resumes.
        connectionGeneration += 1
        negotiatingGeneration = nil
        isConnectionPoisoned = false
        connectedSince = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        #if os(macOS)
        audioDeviceTask?.cancel()
        audioDeviceTask = nil
        #endif
        levelTimer?.invalidate()
        levelTimer = nil
        speakingDeviceIds = []
        trackIdToTrackName = [:]
        stopCamera()
        await stopScreenShare(publish: false)
        connection?.close()
        connection = nil
        audioSender = nil
        videoSender = nil
        screenSender = nil
        videoSource = nil
        screenSource = nil
        videoCapturer = nil
        localVideo = nil
        #if os(macOS)
        backgroundBlurProcessor = nil
        #endif
        remoteVideo = [:]
        remoteVideoKey = [:]
        subscribed = []
        subscribeFailures = [:]
        midToTrackName = [:]
        midToSubscriptionKey = [:]
        inboundVideoProgress = [:]
        stallResubscribes = [:]
        // A new connection starts its mids from zero; carrying these over
        // made every rejoin publish nothing — silent mic, frozen cam.
        publishedMids = []
        resyncTask?.cancel()
        resyncTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        transientNotice = nil
        isTalkingWhileMuted = false
        isMicSilent = false
        mutedLoudStreak = 0
        isSelfSpeaking = false
        selfSpeakingUntil = nil
        constrainedVideoStreak = 0
        clearVideoStreak = 0
        videoScaleDownBy = 1
        lastAudibleAt = nil
        lastTapSpeechAt = nil
        tapSpeechStreak = 0
        lastCapturedAudibleAt = nil
        liveSince = nil
        // micRecoveryCount and hasGivenUpOnMicRecovery deliberately survive:
        // they count rejoins ACROSS connections, which is the only way to
        // notice that rejoining is not fixing the microphone.
    }

    private func showNotice(_ text: String, seconds: Double = 4) {
        transientNotice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    // MARK: - Media toggles

    func setMicrophone(on: Bool) async {
        callLog.info("mic \(on ? "on" : "off", privacy: .public)")
        isMicrophoneOn = on
        // The mic-death check only watches WebRTC's capture while the mic is
        // on, so time spent muted leaves it no evidence at all — and "this
        // capture has never made a sound" reads exactly like a dead mic. It
        // fired on the first poll after unmuting and spent a full rejoin on
        // it. Unmuting gets the same grace a route change gets.
        if on { lastCapturedAudibleAt = Date() }
        audioSender?.track?.isEnabled = on
        transcriber.setMuted(!on)
        guard let callId, let client else { return }
        do {
            try await client.setCallState(callId: callId, changes: [.muted(!on)])
        } catch {
            // The local mute is real either way (the track is disabled); what
            // failed is telling the roster. One retry, then say the icon may
            // lie instead of swallowing it.
            try? await Task.sleep(for: .milliseconds(400))
            do {
                try await client.setCallState(callId: callId, changes: [.muted(!on)])
            } catch {
                callLog.warning("mute state failed to sync: \(String(describing: error), privacy: .public)")
                showNotice("Your mute state may look wrong to others")
            }
        }
    }

    func setCamera(on: Bool) async {
        guard let connection, let callId, let client else {
            isCameraOn = on
            return
        }
        isCameraOn = on
        callLog.info("camera \(on ? "on" : "off", privacy: .public)")
        var isDelivered = !on
        if on {
            if videoSender == nil {
                if await didAddCameraTrack(to: connection) { isDelivered = await didPublishCamera() }
            } else {
                videoSender?.track?.isEnabled = true
                isDelivered = await didStartCamera()
                // A camera negotiated at join but refused then (or never
                // accepted) is not on the SFU yet: lighting it is a publish.
                if isDelivered, let sender = videoSender, !isPublished(sender) {
                    isDelivered = await didPublishCamera()
                }
            }
            if !isDelivered {
                // The toggle never lies: no capture or no publish means the
                // camera reads off, instead of a black tile only everyone
                // else can see.
                isCameraOn = false
                videoSender?.track?.isEnabled = false
                stopCamera()
            }
        } else {
            videoSender?.track?.isEnabled = false
            stopCamera()
        }
        try? await client.setCallState(callId: callId, changes: [.cameraOn(isCameraOn)])
    }

    func setBackgroundBlurred(_ blurred: Bool) {
        isBackgroundBlurred = blurred
        backgroundBlurProcessor?.setEnabled(blurred)
        callLog.info("background blur \(blurred ? "on" : "off", privacy: .public)")
    }

    /// One short retry absorbs a sporadic server error before the
    /// toggle reports failure.
    private func didPublishCamera() async -> Bool {
        do {
            let refused = try await publishPending()
            if !refused.contains("cam") { return true }
            callLog.warning("camera publish refused, retrying")
        } catch {
            let reason = String(describing: error)
            callLog.warning("camera publish failed, retrying: \(reason, privacy: .public)")
        }
        try? await Task.sleep(for: .seconds(1))
        do {
            let refused = try await publishPending()
            if !refused.contains("cam") { return true }
            callLog.error("camera publish refused")
            return false
        } catch {
            let retryReason = String(describing: error)
            callLog.error("camera publish failed: \(retryReason, privacy: .public)")
            return false
        }
    }

    #if os(macOS)
    func startScreenShare() async {
        guard let connection, !isScreenSharing, !isStartingScreenShare else { return }
        isStartingScreenShare = true
        defer { isStartingScreenShare = false }
        if hasQuietTracks, let screenSender, let source = screenSource {
            // Negotiated at join and published switched off: sharing is
            // capture plus a flag, and nobody's connection renegotiates.
            let capturer = ScreenShareCapturer(delegate: source)
            do {
                try await capturer.startCapture()
            } catch {
                callLog.error("screen capture failed: \(String(describing: error), privacy: .public)")
                return
            }
            screenCapturer = capturer
            screenSender.track?.isEnabled = true
            if !isPublished(screenSender) {
                // Refused at join: the share is a publish after all.
                let refused = try? await publishPending()
                guard let refused, !refused.contains("screen"), isPublished(screenSender) else {
                    callLog.error("screen publish failed")
                    await stopScreenShare(publish: false)
                    return
                }
            }
            isScreenSharing = true
            if let callId, let client {
                try? await client.setCallState(callId: callId, changes: [.screenSharing(true)])
            }
            return
        }
        guard screenSender == nil else { return }
        let source = factory.videoSource(forScreenCast: true)
        let capturer = ScreenShareCapturer(delegate: source)
        do {
            try await capturer.startCapture()
        } catch {
            // Screen recording permission is the usual reason; the control
            // simply stays off rather than pretending to share.
            callLog.error("screen capture failed: \(String(describing: error), privacy: .public)")
            return
        }
        screenSource = source
        screenCapturer = capturer
        let track = factory.videoTrack(with: source, trackId: "screen")
        screenSender = addLocalTrack(track, streamId: "hq-screen", to: connection)
        guard screenSender != nil else {
            callLog.error("screen sender refused — connection closed?")
            await capturer.stopCapture()
            screenCapturer = nil
            screenSource = nil
            return
        }
        do {
            let refused = try await publishPending()
            if refused.contains("screen") {
                // Accepted request, refused track — same blank stage.
                callLog.error("screen publish refused")
                await stopScreenShare(publish: false)
                return
            }
        } catch {
            // The share never reached the SFU: pretend nothing happened
            // rather than telling the room "presenting" over a blank stage.
            callLog.error("screen publish failed: \(String(describing: error), privacy: .public)")
            await stopScreenShare(publish: false)
            return
        }
        isScreenSharing = true
        if let callId, let client {
            try? await client.setCallState(callId: callId, changes: [.screenSharing(true)])
        }
    }

    func stopScreenShare(publish: Bool = true) async {
        await screenCapturer?.stopCapture()
        screenCapturer = nil
        isScreenSharing = false
        if hasQuietTracks, screenSender != nil {
            // The negotiated share stays where it is, switched off; the flag
            // takes it off everyone's roster.
            screenSender?.track?.isEnabled = false
            guard publish, let callId, let client else { return }
            try? await client.setCallState(callId: callId, changes: [.screenSharing(false)])
            return
        }
        screenSource = nil
        // The SFU closes tracks by mid, never by sender id.
        let sender = screenSender
        let screenMid = sender.flatMap { mid(for: $0) }
        if let sender {
            connection?.removeTrack(sender)
            screenSender = nil
        }
        if let screenMid { publishedMids.remove(screenMid) }
        guard publish, let callId, let client else { return }
        if sender != nil {
            try? await client.unpublish(
                callId: callId,
                mids: screenMid.map { [$0] } ?? [],
                sources: ["screen"]
            )
        }
        // Told to the room even when no sender ever existed: a share whose
        // publish failed used to leave "X is presenting" stuck on everyone's
        // stage with Stop unable to clear it.
        try? await client.setCallState(callId: callId, changes: [.screenSharing(false)])
    }

    /// The screen's sendonly section, negotiated at join with no capture
    /// behind it and the track switched off until a share starts.
    private func addScreenSender(to connection: RTCPeerConnection) {
        let source = factory.videoSource(forScreenCast: true)
        let track = factory.videoTrack(with: source, trackId: "screen")
        track.isEnabled = false
        screenSource = source
        screenSender = addLocalTrack(track, streamId: "hq-screen", to: connection)
    }
    #else
    // The phone joins screen shares but never starts one: iOS can only
    // capture the screen through a Broadcast Upload extension, which is a
    // separate process with its own bundle, entitlement, and IPC — a feature
    // of its own, not a branch of this one. Watching a Mac's share works
    // exactly as it does everywhere else, because that is just a subscribed
    // track.
    func startScreenShare() async {}

    func stopScreenShare(publish: Bool = true) async {}
    #endif

    // MARK: - Subscriptions

    /// Called whenever the roster changes: subscribe to anything new — a
    /// publisher's fresh session included — and drop video for tracks that
    /// ended or moved.
    func sync(call: Call, myDeviceId: String) async {
        latestCall = call
        latestDeviceId = myDeviceId
        guard stage == .live, !isConnectionPoisoned, let client, let callId else { return }
        let generation = connectionGeneration
        let wanted = call.tracks.filter { $0.endedAt == nil && $0.deviceId != myDeviceId }
        let wantedKeys = Set(wanted.map { subscriptionKey($0) })
        // A key that fell out of the roster is an ended track, a republish, or
        // a publisher that re-seated into a new session under the same name;
        // all of them invalidate the old subscription, so forget it — the
        // fresh pass below resubscribes against the current track. The one
        // exception is a camera or screen its owner merely switched off: the
        // hub leaves it off the roster while it is off, the subscription stays
        // valid, and the same track comes back when it is switched on.
        for key in subscribed where !wantedKeys.contains(key) && !isSwitchedOff(key, in: call) {
            forgetSubscription(key)
        }
        for name in remoteVideo.keys where remoteVideoKey[name] == nil
            && !wanted.contains(where: { $0.trackName == name }) {
            remoteVideo[name] = nil
        }
        let fresh = wanted.filter { !subscribed.contains(subscriptionKey($0)) }
        guard !fresh.isEmpty else { return }
        guard !isNegotiating else {
            // A roster change mid-negotiation must not vanish; pick it up
            // once the current pass settles.
            scheduleResync()
            return
        }
        negotiatingGeneration = generation
        defer { if negotiatingGeneration == generation { negotiatingGeneration = nil } }
        for track in fresh { subscribed.insert(subscriptionKey(track)) }
        let freshNames = fresh.map(\.trackName).joined(separator: ",")
        callLog.info("subscribe call=\(callId, privacy: .public) tracks=\(freshNames, privacy: .public)")
        do {
            let result = try await client.subscribe(
                callId: callId,
                tracks: fresh.map { (sessionId: $0.sessionId, trackName: $0.trackName) }
            )
            // The connection was replaced while the SFU answered: this answer
            // belongs to a session that no longer exists here.
            guard generation == connectionGeneration else { return }
            var erroredKeys: [String] = []
            // A requested track the answer never mentions was not subscribed;
            // an older hub drops such tracks silently, and leaving the key
            // marked kept that tile dark when the track came back.
            let answered = Set(result.tracks.compactMap(\.trackName))
            for track in fresh where !answered.contains(track.trackName) {
                erroredKeys.append(subscriptionKey(track))
            }
            for track in result.tracks {
                let requested = fresh.first { $0.trackName == track.trackName }
                if let mid = track.mid, let name = track.trackName {
                    midToTrackName[mid] = name
                    midToSubscriptionKey[mid] = requested.map { subscriptionKey($0) }
                }
                if let code = track.errorCode {
                    let trackName = track.trackName ?? "?"
                    callLog.error("subscribe track error \(trackName, privacy: .public): \(code, privacy: .public)")
                    if let requested { erroredKeys.append(subscriptionKey(requested)) }
                }
            }
            // A per-track refusal used to be logged and left marked as
            // subscribed — a permanent black tile. Most are a publish still
            // settling (the hub announces a track when the SFU accepts it,
            // which is before the publisher's connection is up), so retry on
            // the resync schedule, quickly at first and then backing off so a
            // genuinely dead track costs one call every 15s instead of
            // hammering the SFU.
            //
            // There is no giving up. Four strikes and out was worse than the
            // problem it damped: once, three people's clients each
            // spent their budget inside 8s on one rejoiner, abandoned both his
            // tracks, and left him mute and black to the room for the rest of
            // the meeting — the roster never changed again, so nothing ever
            // retried. A stuck track heals when its publisher re-seats, and
            // that changes the key, which resets this count.
            var retryDelay: Duration?
            for key in erroredKeys {
                let failures = (subscribeFailures[key] ?? 0) + 1
                subscribeFailures[key] = failures
                subscribed.remove(key)
                let backoff = Self.subscribeRetryDelay(afterFailures: failures)
                retryDelay = min(retryDelay ?? backoff, backoff)
                if failures == 8 {
                    callLog.error("\(key, privacy: .public) still refused after \(failures); backing off")
                }
            }
            if result.shouldRenegotiate, let offer = result.sessionDescription {
                try await renegotiate(with: offer, generation: generation)
            }
            attachPendingReceivers()
            if let retryDelay { scheduleResync(after: retryDelay) }
        } catch is SupersededConnection {
            return
        } catch let failure as NegotiationFailure {
            // The connection is poisoned and recovery is already on its way;
            // retrying here would only fail the same way.
            callLog.error("subscribe abandoned: \(failure.stage, privacy: .public)")
        } catch {
            guard generation == connectionGeneration else { return }
            for track in fresh { subscribed.remove(subscriptionKey(track)) }
            let reason = String(describing: error)
            callLog.error("subscribe failed \(callId, privacy: .public): \(reason, privacy: .public); resync in 2s")
            // A flaky subscribe (the SFU edge throws sporadic 5xx) must not
            // orphan a teammate's media until the next roster change: without
            // this, one bad response meant never seeing them at all.
            scheduleResync()
        }
    }

    /// A subscription whose track left the roster only because its owner
    /// switched that source off — same seat, same session, flag down.
    private func isSwitchedOff(_ key: String, in call: Call) -> Bool {
        guard hasQuietTracks, let parts = Self.subscriptionParts(key) else { return false }
        let participant = call.presentParticipants.first {
            parts.trackName == "\($0.deviceId)-cam" || parts.trackName == "\($0.deviceId)-screen"
        }
        guard let participant, participant.sessionId == parts.sessionId else { return false }
        if parts.trackName.hasSuffix("-cam") { return !participant.isCameraOn }
        return !participant.isScreenSharing
    }

    /// Everything a subscription left behind: its receive mids, and the video
    /// it attached. The old receiver kept painting its last frame into the
    /// tile until something else happened to overwrite it.
    private func forgetSubscription(_ key: String) {
        subscribed.remove(key)
        subscribeFailures[key] = nil
        stallResubscribes[key] = nil
        var mids: [String] = []
        for (mid, owner) in midToSubscriptionKey where owner == key {
            midToSubscriptionKey[mid] = nil
            midToTrackName[mid] = nil
            mids.append(mid)
        }
        if let connection {
            for transceiver in connection.transceivers where mids.contains(transceiver.mid) {
                if let trackId = transceiver.receiver.track?.trackId { trackIdToTrackName[trackId] = nil }
            }
        }
        // The SFU keeps forwarding a subscription nobody closes: every
        // resubscribe used to stack another copy of the same stream.
        if !mids.isEmpty, let client, let callId {
            Task { try? await client.unsubscribe(callId: callId, mids: mids) }
        }
        guard let name = Self.subscriptionParts(key)?.trackName else { return }
        if remoteVideoKey[name] == key {
            remoteVideo[name] = nil
            remoteVideoKey[name] = nil
            inboundVideoProgress[name] = nil
        }
    }

    private static func subscriptionParts(_ key: String) -> (trackName: String, sessionId: String)? {
        let parts = key.split(separator: "@", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return (trackName: parts[0], sessionId: parts[1])
    }

    /// Name, session and publish time: a track republished under the same
    /// session (a screen share stopped and started again on an older hub) is
    /// a new SFU track and needs a new subscription, even though its name
    /// and session match the old one.
    private func subscriptionKey(_ track: CallTrack) -> String {
        "\(track.trackName)@\(track.sessionId)@\(track.createdAt)"
    }

    /// One recovery in flight at a time, three strikes before the call is
    /// declared dead — a successful reconnect (ICE connected) resets the
    /// count, so a long meeting can survive any number of route changes.
    private func scheduleRecovery(reason: String, after delay: Duration, countsAsStrike: Bool = true) {
        guard stage == .live || stage == .reconnecting else { return }
        guard !isRecovering else {
            isRecoveryOwed = true
            return
        }
        guard reconnectTask == nil else { return }
        if countsAsStrike {
            guard reconnectAttempts < 3 else {
                callLog.error("recovery exhausted (\(reason, privacy: .public))")
                stage = .failed("The connection dropped.")
                return
            }
            reconnectAttempts += 1
        }
        let attempt = reconnectAttempts
        isPendingRecoveryICE = reason.hasPrefix("ice ")
        callLog.warning("recovery scheduled (\(reason, privacy: .public)) attempt=\(attempt)")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.isRecovering = true
            self.isRecoveryOwed = false
            await self.onConnectionLost?()
            self.isRecovering = false
            if self.shouldRebuildAudioDevice {
                self.scheduleRecovery(reason: "audio services reset during recovery", after: .seconds(1))
            } else if self.isRecoveryOwed {
                self.isRecoveryOwed = false
                self.scheduleRecovery(reason: "recovery failed", after: .seconds(2))
            }
        }
    }

    /// libwebrtc refused a description on this connection. Its session error
    /// sticks — every later offer and answer fails the same way, which is how
    /// one camera toggle used to take down a person's whole call for minutes
    /// — so nothing negotiates here again; a fresh connection does.
    private func markConnectionPoisoned(_ what: String) {
        guard !isConnectionPoisoned else { return }
        isConnectionPoisoned = true
        callLog.error("negotiation failed (\(what, privacy: .public)); rebuilding the connection")
        if stage == .live { stage = .reconnecting }
        scheduleRecovery(reason: "negotiation failed", after: .zero)
    }

    /// The roster says this device is no longer in the call — swept, or
    /// evicted after its socket dropped — while the media here still runs.
    /// The room cannot see or hear this person any more, and nothing else
    /// would tell them: take the seat back.
    func noteSeatLost() {
        // A frame written before our own join can arrive after it; a seat
        // only counts as lost once the connection has had a moment to be seen.
        guard stage == .live, let liveSince, Date().timeIntervalSince(liveSince) > 10 else { return }
        callLog.error("this device's seat is gone from the roster; rejoining")
        showNotice("You dropped out of the call — rejoining…")
        stage = .reconnecting
        scheduleRecovery(reason: "seat lost", after: .zero)
    }

    /// A person asked for another try after recovery gave up: the strike
    /// counter resets and the stage reads honest while the rejoin runs.
    func retryAfterFailure() {
        guard case .failed = stage else { return }
        reconnectAttempts = 0
        stage = .reconnecting
    }

    /// Every second for the first few tries, then 2s, 4s, 8s and a 15s floor
    /// forever. The common refusal is a publisher whose connection is still
    /// coming up after a join or rejoin, which settles within seconds — the
    /// old 2/4/8/15 ladder turned that into up to 15s of a black tile for
    /// everyone each time anyone rejoined. A permanently dead track still
    /// ends up as background noise.
    static func subscribeRetryDelay(afterFailures failures: Int) -> Duration {
        guard failures > 4 else { return .seconds(1) }
        // The shift is clamped, not just the result: a track refused every 15s
        // for an hour reaches a failure count that would overflow the shift.
        return .seconds(min(2 << min(failures - 5, 4), 15))
    }

    private func scheduleResync(after delay: Duration = .seconds(2)) {
        resyncTask?.cancel()
        resyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  let call = self.latestCall, let deviceId = self.latestDeviceId
            else { return }
            await self.sync(call: call, myDeviceId: deviceId)
        }
    }

    // MARK: - Negotiation

    /// Publishes every local track HQ has not accepted yet. Returns the
    /// SOURCES the SFU refused this round ("cam", "screen", ...) — a refusal
    /// is not a thrown error, but the caller's toggle must not survive it.
    @discardableResult
    private func publishPending() async throws -> Set<String> {
        guard let connection, let client, let callId else { return [] }
        let generation = connectionGeneration
        // One negotiation at a time on the connection: a publish offer
        // overlapping a subscribe renegotiation corrupts the signaling state
        // and freezes every stream already flowing (seen live: starting a
        // screen share grayed out the other person's video, on both sides).
        while isNegotiating {
            try await Task.sleep(for: .milliseconds(150))
            try ensureCurrent(generation)
        }
        try ensureCurrent(generation)
        guard !isConnectionPoisoned else { throw NegotiationFailure(stage: "connection already failed") }
        negotiatingGeneration = generation
        defer { if negotiatingGeneration == generation { negotiatingGeneration = nil } }
        // Checked under the lock: a waiter whose track was covered by the
        // publish it waited on must make no offer at all — an offer with
        // nothing to name stranded the connection in have-local-offer, and
        // every renegotiation after that threw forever.
        guard hasUnpublishedTracks() else { return [] }
        // Mids do not exist until the local description is set, so the offer has
        // to be applied before there is anything to name in the publish.
        let offer: RTCSessionDescription
        do {
            offer = try await connection.offer(for: mediaConstraints())
            try ensureCurrent(generation)
            try await connection.setLocalDescription(offer)
        } catch is SupersededConnection {
            throw SupersededConnection()
        } catch {
            try ensureCurrent(generation)
            logNegotiationFailure("publish offer", error: error, sdps: [], mids: [])
            markConnectionPoisoned("publish offer")
            throw NegotiationFailure(stage: "publish offer")
        }
        try ensureCurrent(generation)
        let pending = pendingSenders()
        guard !pending.isEmpty else {
            try await rollbackLocalOffer(on: connection)
            return []
        }
        let answer: HQClient.PublishAnswer
        do {
            answer = try await client.publish(
                callId: callId,
                offer: HQClient.SessionDescriptionWire(sdp: offer.sdp, type: "offer"),
                tracks: pending.map { (mid: $0.mid, source: $0.source, isEnabled: isEnabled(source: $0.source)) }
            )
        } catch {
            // The SFU never took these tracks: take the offer back so the
            // connection can negotiate again, and leave the mids unmarked so
            // a retry is a real publish — marking them up front made a failed
            // publish read as permanently succeeded (camera "on", nothing
            // sent, retry a no-op).
            try ensureCurrent(generation)
            try? await rollbackLocalOffer(on: connection)
            throw error
        }
        try ensureCurrent(generation)
        let refusedMids = Set(answer.refused.map(\.mid))
        let accepted = pending.filter { !refusedMids.contains($0.mid) }
        do {
            try await connection.setRemoteDescription(
                RTCSessionDescription(type: .answer, sdp: answer.sessionDescription.sdp)
            )
        } catch {
            try ensureCurrent(generation)
            logNegotiationFailure(
                "publish answer", error: error,
                sdps: [("offer", offer.sdp), ("answer", answer.sessionDescription.sdp)],
                mids: pending.map(\.mid)
            )
            // The SFU accepted these tracks and the hub advertises them, but
            // this connection will never send on them. They used to be marked
            // published anyway: the camera toggle read on, nothing went out,
            // and every other client retried a track that did not exist for
            // the rest of the meeting. Take them back off the roster, then
            // rebuild the connection.
            if !accepted.isEmpty {
                try? await client.unpublish(
                    callId: callId, mids: accepted.map(\.mid), sources: accepted.map(\.source)
                )
            }
            markConnectionPoisoned("publish answer")
            throw NegotiationFailure(stage: "publish answer")
        }
        // Marked only now that the answer is applied: a mid is published when
        // the SFU took it AND this connection agreed to send on it.
        publishedMids.formUnion(accepted.map(\.mid))
        callLog.info("published \(pending.map { "\($0.source)@\($0.mid)" }.joined(separator: ","), privacy: .public)")
        if !answer.refused.isEmpty {
            let listed = answer.refused.map { "\($0.source):\($0.errorCode)" }.joined(separator: ",")
            callLog.warning("publish refused \(listed, privacy: .public)")
        }
        return Set(answer.refused.map(\.source))
    }

    private func rollbackLocalOffer(on connection: RTCPeerConnection) async throws {
        try await connection.setLocalDescription(RTCSessionDescription(type: .rollback, sdp: ""))
    }

    /// Answers the SFU's offer for new subscriptions. Any failure here leaves
    /// the SFU's side of the session waiting for an answer that will never
    /// come, and every later subscribe fails behind it, so a failure is the
    /// connection's end, not a retry.
    private func renegotiate(with offer: HQClient.SessionDescriptionWire, generation: Int) async throws {
        guard let connection, let client, let callId else { return }
        let answer: RTCSessionDescription
        do {
            try await connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer.sdp))
            try ensureCurrent(generation)
            answer = try await connection.answer(for: mediaConstraints())
            try ensureCurrent(generation)
            try await connection.setLocalDescription(answer)
        } catch is SupersededConnection {
            throw SupersededConnection()
        } catch {
            try ensureCurrent(generation)
            logNegotiationFailure("subscribe offer", error: error, sdps: [("offer", offer.sdp)], mids: [])
            markConnectionPoisoned("subscribe offer")
            throw NegotiationFailure(stage: "subscribe offer")
        }
        try ensureCurrent(generation)
        let wire = HQClient.SessionDescriptionWire(sdp: answer.sdp, type: "answer")
        do {
            try await client.renegotiate(callId: callId, answer: wire)
        } catch {
            // One retry for the edge's sporadic 5xx; the hub never retries
            // this itself.
            try ensureCurrent(generation)
            try? await Task.sleep(for: .milliseconds(500))
            try ensureCurrent(generation)
            do {
                try await client.renegotiate(callId: callId, answer: wire)
            } catch let retryError as APIError where retryError.code == "sfu_rejected" {
                // The first attempt's failure was the edge losing the reply,
                // not the SFU refusing it: the answer already applied, and
                // the SFU refuses a second copy. Carry on.
                callLog.warning("renegotiate retry refused; the first answer applied")
            } catch {
                try ensureCurrent(generation)
                callLog.error("renegotiate failed: \(String(describing: error), privacy: .public)")
                markConnectionPoisoned("subscribe answer")
                throw NegotiationFailure(stage: "subscribe answer")
            }
        }
    }

    private func ensureCurrent(_ generation: Int) throws {
        guard generation == connectionGeneration else { throw SupersededConnection() }
    }

    private func isEnabled(source: String) -> Bool? {
        switch source {
        case "cam": return isCameraOn
        case "screen": return isScreenSharing
        default: return nil
        }
    }

    private func isPublished(_ sender: RTCRtpSender) -> Bool {
        guard let mid = mid(for: sender) else { return false }
        return publishedMids.contains(mid)
    }

    /// What libwebrtc refused, in a form a log dump can answer "why" from:
    /// the error, and for each description only the lines that decide the
    /// m-sections involved — codecs, their parameters, header extensions,
    /// direction. Never ICE credentials, fingerprints or candidates.
    private func logNegotiationFailure(
        _ what: String, error: Error, sdps: [(label: String, sdp: String)], mids: [String]
    ) {
        callLog.error("\(what, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
        for (label, sdp) in sdps {
            let summary = Self.mediaSummary(of: sdp, mids: mids)
            callLog.error("\(what, privacy: .public) \(label, privacy: .public) sdp:\n\(summary, privacy: .public)")
        }
    }

    static func mediaSummary(of sdp: String, mids: [String]) -> String {
        let keep = ["m=", "a=mid:", "a=rtpmap:", "a=fmtp:", "a=extmap:", "a=rtcp-fb:",
                    "a=sendonly", "a=recvonly", "a=sendrecv", "a=inactive", "a=group:", "a=simulcast", "a=rid:"]
        var lines: [String] = []
        var currentMid: String?
        var section: [String] = []
        func flush() {
            if mids.isEmpty || currentMid.map(mids.contains) == true { lines.append(contentsOf: section) }
            section = []
        }
        for raw in sdp.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("m=") {
                flush()
                currentMid = nil
            }
            if line.hasPrefix("a=mid:") { currentMid = String(line.dropFirst("a=mid:".count)) }
            if line.hasPrefix("a=group:") {
                lines.append(line)
            } else if keep.contains(where: line.hasPrefix) {
                section.append(line)
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// A local track HQ has not been told about yet — mid or no mid. Checked
    /// before negotiating so an offer is only made when there is news.
    private func hasUnpublishedTracks() -> Bool {
        guard let connection else { return false }
        return connection.transceivers.contains { transceiver in
            guard transceiver.direction == .sendOnly || transceiver.direction == .sendRecv else {
                return false
            }
            guard let track = transceiver.sender.track, source(of: track) != nil else { return false }
            return transceiver.mid.isEmpty || !publishedMids.contains(transceiver.mid)
        }
    }

    /// The mid of each local track we have added but not yet told HQ about.
    /// Only meaningful after setLocalDescription — that is where mids are
    /// born. A pure read: mids join `publishedMids` only once the SFU has
    /// actually accepted them.
    private func pendingSenders() -> [(mid: String, source: String)] {
        guard let connection else { return [] }
        var pending: [(mid: String, source: String)] = []
        let sending: [RTCRtpTransceiver] = connection.transceivers.filter {
            $0.direction == .sendOnly || $0.direction == .sendRecv
        }
        for transceiver in sending {
            let mid = transceiver.mid
            guard !mid.isEmpty, !publishedMids.contains(mid) else { continue }
            guard let track = transceiver.sender.track, let source = source(of: track) else { continue }
            pending.append((mid: mid, source: source))
        }
        return pending
    }

    private func source(of track: RTCMediaStreamTrack) -> String? {
        switch track.trackId {
        case "audio": return "mic"
        case "video": return "cam"
        case "screen": return "screen"
        default: return nil
        }
    }

    /// The mid a sender ended up on — what the SFU needs to close a track.
    private func mid(for sender: RTCRtpSender) -> String? {
        guard let connection else { return nil }
        let match = connection.transceivers.first { $0.sender.senderId == sender.senderId }
        guard let mid = match?.mid, !mid.isEmpty else { return nil }
        return mid
    }

    private var publishedMids: Set<String> = []

    private func mediaConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    // MARK: - Local media

    /// Every local track gets its OWN sendonly m-line. `addTrack` is the
    /// shorter call and a trap: it reuses the first transceiver with a free
    /// sender, and after the first subscribe every free transceiver is a
    /// teammate's receive slot. Turning the camera on mid-call therefore
    /// published it onto a mid the SFU had handed out for someone else's
    /// video — the camera never arrived and their tile went gray (which is
    /// also what "starting a screen share grayed out their video" was).
    /// Sendonly-per-track is what the SFU's own examples
    /// do, and what the header comment here has always claimed.
    private func addLocalTrack(
        _ track: RTCMediaStreamTrack, streamId: String, to connection: RTCPeerConnection
    ) -> RTCRtpSender? {
        let config = RTCRtpTransceiverInit()
        config.direction = .sendOnly
        config.streamIds = [streamId]
        return connection.addTransceiver(with: track, init: config)?.sender
    }

    private func addAudioTrack(to connection: RTCPeerConnection) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "audio")
        track.isEnabled = isMicrophoneOn
        audioSender = addLocalTrack(track, streamId: "hq", to: connection)
    }

    /// The camera's source, blur stage, track and sendonly section — no
    /// capture yet. With quiet tracks this runs at join, camera on or off.
    private func addCameraSender(to connection: RTCPeerConnection) {
        let source = factory.videoSource()
        videoSource = source
        let blurProcessor = BackgroundBlurProcessor(delegate: source)
        blurProcessor.setEnabled(isBackgroundBlurred)
        blurProcessor.onFailure = { [weak self] in
            Task { @MainActor in
                self?.isBackgroundBlurred = false
                self?.showNotice("Background blur stopped working")
            }
        }
        backgroundBlurProcessor = blurProcessor
        let track = factory.videoTrack(with: source, trackId: "video")
        localVideo = track
        videoSender = addLocalTrack(track, streamId: "hq", to: connection)
    }

    @discardableResult
    private func didAddCameraTrack(to connection: RTCPeerConnection) async -> Bool {
        addCameraSender(to: connection)
        guard videoSender != nil, await didStartCamera() else {
            // No capture, no track: publishing a frameless sender would show
            // everyone a black tile that claims to be a camera.
            if let sender = videoSender { connection.removeTrack(sender) }
            videoSender = nil
            videoSource = nil
            localVideo = nil
            backgroundBlurProcessor = nil
            return false
        }
        return true
    }

    @discardableResult
    private func didStartCamera() async -> Bool {
        guard let source = videoSource else { return false }
        let captureDelegate: RTCVideoCapturerDelegate = backgroundBlurProcessor ?? source
        let capturer = videoCapturer ?? RTCCameraVideoCapturer(delegate: captureDelegate)
        videoCapturer = capturer
        let devices = RTCCameraVideoCapturer.captureDevices()
        callLog.info("cameras: \(devices.map(\.localizedName).joined(separator: ","), privacy: .public)")
        #if os(macOS)
        // The user's cross-app camera choice; devices.first is often a
        // Continuity Camera iPhone that can lock or walk away mid-meeting.
        let preferred = AVCaptureDevice.userPreferredCamera
        let device = devices.first { $0.uniqueID == preferred?.uniqueID } ?? devices.first
        #else
        // A phone in a meeting is pointed at its owner until they say
        // otherwise, so the front camera leads and the flip control decides
        // from there.
        let wanted: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        let device = devices.first { $0.position == wanted } ?? devices.first
        #endif
        guard let device else {
            callLog.error("no camera device found")
            activeCameraId = nil
            return false
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // 720p is what Meet sends for a tile; anything larger is bandwidth the
        // grid never renders.
        let format = formats.min { lhs, rhs in
            let lhsWidth = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription).width
            let rhsWidth = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription).width
            return abs(Int(lhsWidth) - 1280) < abs(Int(rhsWidth) - 1280)
        }
        guard let format else {
            callLog.error("no capture format on \(device.localizedName, privacy: .public)")
            activeCameraId = nil
            return false
        }
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        do {
            try await capturer.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
            activeCameraId = device.uniqueID
            callLog.info("camera capturing on \(device.localizedName, privacy: .public)")
            return true
        } catch {
            let reason = String(describing: error)
            let cameraName = device.localizedName
            callLog.error("camera start failed on \(cameraName, privacy: .public): \(reason, privacy: .public)")
            activeCameraId = nil
            return false
        }
    }

    private func stopCamera() {
        videoCapturer?.stopCapture()
        activeCameraId = nil
    }

    #if !os(macOS)
    /// Front⇄back. The track and its transceiver stay exactly where they
    /// are — only the capture device under them changes, so nobody
    /// renegotiates and no tile blinks out.
    func flipCamera() async {
        isUsingFrontCamera.toggle()
        guard isCameraOn else { return }
        stopCamera()
        await didStartCamera()
    }
    #endif

    private func attachPendingReceivers() {
        guard let connection else { return }
        for transceiver in connection.transceivers {
            guard let name = midToTrackName[transceiver.mid] else { continue }
            guard let track = transceiver.receiver.track else { continue }
            trackIdToTrackName[track.trackId] = name
            if let video = track as? RTCVideoTrack {
                if remoteVideo[name] !== video {
                    callLog.info("attached video \(name, privacy: .public)")
                    inboundVideoProgress[name] = nil
                }
                remoteVideo[name] = video
                remoteVideoKey[name] = midToSubscriptionKey[transceiver.mid]
            }
        }
    }

    // MARK: - Who is talking

    // The mic-death check. Two independent readers hear this Mac's input: the
    // transcriber's AVAudioEngine tap, which rebuilds itself on a route
    // change, and WebRTC's own capture, which does not. Speech in the tap
    // with nothing in WebRTC's media-source level is the one fact that means
    // the capture the call is publishing is dead — and the only case worth
    // spending a rejoin on. Anything else (a route change, a quiet room) is
    // left alone, because a rejoin is what everyone else sees as a camera
    // dropping out.
    //
    // The two readers are not the same measurement and never were: the tap
    // reports the PEAK of raw input, WebRTC reports a level computed after its
    // own echo cancellation and noise suppression. Comparing them at one
    // shared floor made every quiet listener look like a dead microphone —
    // the room's noise and the speakers' echo cleared the tap's floor while
    // AEC correctly held WebRTC's at zero — and cost a rejoin every 30s for
    // the whole meeting (seen live, four people, 15 rejoins).
    // Only real speech is comparable: AEC removes the far end, never the
    // near, so a person actually talking moves BOTH readers.
    private func noteCapturedAudio(_ report: RTCStatisticsReport) {
        guard stage == .live, isMicrophoneOn else { return }
        guard Self.areCaptureLevelsComparable(in: AVCaptureDevice.activeMicrophoneMode) else {
            // A processed mode sits between the raw AVAudioEngine tap and
            // WebRTC's media-source level, so silence across those two
            // readers no longer proves capture died. Keep a grace stamp for
            // switching back to Standard.
            lastCapturedAudibleAt = Date()
            return
        }
        for statistics in report.statistics.values {
            guard statistics.type == "media-source" else { continue }
            guard statistics.values["kind"] as? String == "audio" else { continue }
            guard let level = statistics.values["audioLevel"] as? Double else { return }
            if level > 0.001 {
                lastCapturedAudibleAt = Date()
                // Capture is publishing sound, so whatever the last recovery
                // was for, it is over: the call gets its full budget back, and
                // a verdict of "rejoining will not fix this" is void — the
                // microphone that comes back can die again later.
                micRecoveryCount = 0
                hasGivenUpOnMicRecovery = false
            }
        }
        guard !hasGivenUpOnMicRecovery else { return }
        let now = Date()
        // A tap that heard actual speech seconds ago against a capture that has
        // produced nothing for far longer.
        guard let speechAt = lastTapSpeechAt, now.timeIntervalSince(speechAt) < 4 else { return }
        let capturedAgo = lastCapturedAudibleAt.map { now.timeIntervalSince($0) } ?? .infinity
        guard capturedAgo > 8 else { return }
        let isCooledDown = lastMicRecoveryAt.map { now.timeIntervalSince($0) > 30 } ?? true
        guard isCooledDown else { return }
        // Two rejoins that did not bring the capture back are proof enough
        // that a third will not either. Say so once and stop: a microphone
        // nobody can fix from here is one person's problem, while a rejoin
        // every 30s is everybody's.
        guard micRecoveryCount < 2 else {
            hasGivenUpOnMicRecovery = true
            callLog.error("captured audio still dead after \(self.micRecoveryCount) rejoins; giving up")
            showNotice("Your microphone isn't reaching the call — check your input device", seconds: 8)
            return
        }
        micRecoveryCount += 1
        lastMicRecoveryAt = now
        lastCapturedAudibleAt = now
        callLog.warning("captured audio is dead while the input tap hears speech; rejoining")
        showNotice("Microphone stopped working — reconnecting…")
        scheduleRecovery(reason: "captured audio dead", after: .milliseconds(500))
    }

    static func areCaptureLevelsComparable(
        in microphoneMode: AVCaptureDevice.MicrophoneMode
    ) -> Bool {
        microphoneMode == .standard
    }

    // Meet's most useful signal is knowing who is speaking without looking. The
    // audio level comes from the standard inbound-rtp stats; if this build does
    // not report it, nothing highlights and the grid behaves as it did before.
    private func startLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollLevels() }
        }
    }

    private func pollLevels() async {
        guard let connection else { return }
        if let connectedSince, reconnectAttempts > 0, Date().timeIntervalSince(connectedSince) > 30 {
            reconnectAttempts = 0
        }
        let report = await connection.statistics()
        guard connection === self.connection else { return }
        levelPollCount += 1
        if levelPollCount % 8 == 0 { logStats(report) }
        if isMicrophoneOn, stage == .live, let liveSince,
           Date().timeIntervalSince(liveSince) > 30 {
            let audibleAgo = lastAudibleAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let isSilent = audibleAgo > 30
            if isSilent != isMicSilent {
                isMicSilent = isSilent
                if isSilent { callLog.warning("mic silent for 30s while unmuted") }
            }
        }
        noteCapturedAudio(report)
        var speaking: Set<String> = []
        for statistics in report.statistics.values {
            guard statistics.type == "inbound-rtp" else { continue }
            guard let kind = statistics.values["kind"] as? String, kind == "audio" else { continue }
            guard let level = statistics.values["audioLevel"] as? Double, level > 0.02 else { continue }
            guard let trackId = statistics.values["trackIdentifier"] as? String,
                  let name = trackIdToTrackName[trackId]
            else { continue }
            // Track names are `${device}-${source}`; the device is the speaker.
            speaking.insert(String(name.dropLast("-mic".count)))
        }
        if speaking != speakingDeviceIds { speakingDeviceIds = speaking }
    }

    // A ~5s cadence snapshot of the RTP flows: enough to see a track stall
    // (packets stop moving), degrade (qualityLimitationReason), or the path
    // worsen (rtt) in a log dump after a shaky meeting.
    private func logStats(_ report: RTCStatisticsReport) {
        var parts: [String] = []
        var isVideoConstrained = false
        var inboundVideo: [String: Int] = [:]
        for statistics in report.statistics.values.sorted(by: { $0.id < $1.id }) {
            let values = statistics.values
            let kind = values["kind"] as? String ?? "?"
            if statistics.type == "outbound-rtp" {
                let sent = values["packetsSent"] as? Int ?? 0
                let limit = values["qualityLimitationReason"] as? String
                let suffix = limit.map { $0 == "none" ? "" : " limit=\($0)" } ?? ""
                if kind == "video", limit == "bandwidth" || limit == "cpu" {
                    isVideoConstrained = true
                }
                parts.append("out:\(kind)=\(sent)\(suffix)")
            } else if statistics.type == "inbound-rtp" {
                let received = values["packetsReceived"] as? Int ?? 0
                let lost = values["packetsLost"] as? Int ?? 0
                let trackId = values["trackIdentifier"] as? String
                let name = trackId.flatMap { trackIdToTrackName[$0] } ?? kind
                parts.append("in:\(name)=\(received) lost=\(lost)")
                if kind == "video", let trackId, let trackName = trackIdToTrackName[trackId] {
                    inboundVideo[trackName] = received
                }
            } else if statistics.type == "candidate-pair",
                      values["state"] as? String == "succeeded",
                      let rtt = values["currentRoundTripTime"] as? Double {
                parts.append("rtt=\(Int(rtt * 1000))ms")
            }
        }
        callLog.info("stats \(parts.joined(separator: " "), privacy: .public)")
        noteVideoConstraint(isVideoConstrained)
        noteInboundVideo(inboundVideo)
    }

    // A subscription can go quiet while everything around it reads healthy:
    // the publisher is in the roster with its camera on, the track is
    // attached, and no packet arrives — a frozen tile that stayed frozen
    // until the roster happened to change. Three still samples (~15s) of a
    // stream that should be flowing earn a fresh subscription, twice at most
    // per subscription: a publisher whose own capture died is theirs to fix.
    private func noteInboundVideo(_ packets: [String: Int]) {
        guard stage == .live, !isConnectionPoisoned, let call = latestCall else { return }
        var stalled: [String] = []
        for (name, count) in packets {
            let previous = inboundVideoProgress[name]
            let stillSamples = previous.map { $0.packets == count ? $0.stillSamples + 1 : 0 } ?? 0
            inboundVideoProgress[name] = (packets: count, stillSamples: stillSamples)
            guard stillSamples >= 3, let key = remoteVideoKey[name], subscribed.contains(key) else { continue }
            guard isExpectedToFlow(name, in: call) else { continue }
            stalled.append(key)
        }
        for key in stalled {
            let spent = stallResubscribes[key] ?? 0
            guard spent < 2 else { continue }
            callLog.warning("\(key, privacy: .public) delivered nothing for ~15s; resubscribing")
            forgetSubscription(key)
            stallResubscribes[key] = spent + 1
        }
        if !stalled.isEmpty { scheduleResync(after: .zero) }
    }

    private func isExpectedToFlow(_ trackName: String, in call: Call) -> Bool {
        guard let track = call.tracks.first(where: { $0.trackName == trackName && $0.endedAt == nil }),
              let publisher = call.presentParticipants.first(where: { $0.deviceId == track.deviceId })
        else { return false }
        switch track.source {
        case "cam": return publisher.isCameraOn
        case "screen": return publisher.isScreenSharing
        default: return false
        }
    }

    // Meet degrades resolution under constraint, and so do we. This used to
    // turn the camera OFF after ~15s of any bandwidth/CPU limitation — a
    // state WebRTC reports routinely while its estimator ramps — which is
    // most of what "my camera keeps turning itself off" was. Quality steps
    // down to half and then quarter resolution and climbs back on its own;
    // the camera is never taken away.
    private func noteVideoConstraint(_ isConstrained: Bool) {
        guard isCameraOn, stage == .live, videoSender != nil else {
            constrainedVideoStreak = 0
            clearVideoStreak = 0
            return
        }
        constrainedVideoStreak = isConstrained ? constrainedVideoStreak + 1 : 0
        clearVideoStreak = isConstrained ? 0 : clearVideoStreak + 1
        // The samples are ~5s apart: three constrained in a row is a real
        // squeeze, six clear ones is a path that has recovered.
        if constrainedVideoStreak >= 3, videoScaleDownBy < 4 {
            constrainedVideoStreak = 0
            setVideoScale(videoScaleDownBy * 2)
            showNotice("Video quality reduced to keep the call stable", seconds: 5)
        } else if clearVideoStreak >= 6, videoScaleDownBy > 1 {
            clearVideoStreak = 0
            setVideoScale(videoScaleDownBy / 2)
        }
    }

    private func setVideoScale(_ scale: Double) {
        guard let sender = videoSender else { return }
        videoScaleDownBy = scale
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.scaleResolutionDownBy = NSNumber(value: scale)
        }
        sender.parameters = parameters
        callLog.warning("video scaled down by \(scale, privacy: .public)")
    }

    private func friendlyMessage(for error: Error) -> String {
        if let apiError = error as? APIError, apiError.code == "not_configured" {
            return "Meetings aren't configured yet — HQ needs its Realtime credentials."
        }
        return (error as? APIError)?.localizedDescription ?? "The call could not be started."
    }
}

extension CallEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        Task { @MainActor in self.attachPendingReceivers() }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        Task { @MainActor in self.attachPendingReceivers() }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        callLog.info("ice \(iceStateName(newState), privacy: .public)")
        Task { @MainActor in
            // A connection already torn down still reports its last states;
            // a late .failed from it used to schedule a rejoin of the healthy
            // connection that replaced it.
            guard peerConnection === self.connection else { return }
            switch newState {
            case .connected, .completed:
                // Network recovery cannot repair an invalidated audio unit.
                guard !self.shouldRebuildAudioDevice else { return }
                // Neither can it repair a connection libwebrtc has poisoned.
                guard !self.isConnectionPoisoned else { return }
                if self.isPendingRecoveryICE {
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                }
                // The strike count comes back once this holds (pollLevels);
                // resetting it here let a connection that keeps breaking
                // itself right after connecting rejoin forever.
                if self.connectedSince == nil { self.connectedSince = Date() }
                if self.stage == .reconnecting, self.reconnectTask == nil, !self.isRecovering {
                    self.stage = .live
                    self.showNotice("Reconnected")
                }
            case .disconnected:
                self.connectedSince = nil
                // Usually transient, and ICE routinely repairs itself in
                // under five seconds. Rejoining sooner than that costs
                // everyone in the room a camera that blinks out and back.
                self.scheduleRecovery(reason: "ice disconnected", after: .seconds(6))
            case .failed:
                self.connectedSince = nil
                self.scheduleRecovery(reason: "ice failed", after: .milliseconds(500))
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        callLog.info("signaling \(signalingStateName(stateChanged), privacy: .public)")
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private func iceStateName(_ state: RTCIceConnectionState) -> String {
    switch state {
    case .checking: return "checking"
    case .closed: return "closed"
    case .completed: return "completed"
    case .connected: return "connected"
    case .disconnected: return "disconnected"
    case .failed: return "failed"
    case .new: return "new"
    default: return "state-\(state.rawValue)"
    }
}

private func signalingStateName(_ state: RTCSignalingState) -> String {
    switch state {
    case .closed: return "closed"
    case .haveLocalOffer: return "have-local-offer"
    case .haveLocalPrAnswer: return "have-local-pranswer"
    case .haveRemoteOffer: return "have-remote-offer"
    case .haveRemotePrAnswer: return "have-remote-pranswer"
    case .stable: return "stable"
    default: return "state-\(state.rawValue)"
    }
}

/// The connection this work began on was replaced while it waited; whatever
/// it was doing belongs to a session that no longer exists here.
struct SupersededConnection: Error {}

/// libwebrtc refused a description; the connection is being rebuilt.
struct NegotiationFailure: Error {
    let stage: String
}
