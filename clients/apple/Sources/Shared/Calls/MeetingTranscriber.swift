import AVFoundation
import Foundation
import os

private let transcribeLog = Logger(subsystem: HQIdentity.logSubsystem, category: "transcribe")

// Streams this device's mic to HQ's transcription feed as 16 kHz mono
// linear16 for the whole of any call — a named meeting, a quick call, or a
// two-person call out of a thread. A second reader on the input device —
// WebRTC keeps its own capture; CoreAudio on macOS is fine with both.
// Transcription is best-effort everywhere: a failure here never touches
// the call itself.
@MainActor
final class MeetingTranscriber {
    private var engine: AVAudioEngine?
    private var socket: URLSessionWebSocketTask?
    private(set) var isMuted = false
    private var configObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?
    private var isActive = false
    /// What the feed reconnects to. The socket used to log its close and
    /// stay dead, which ended the transcript AND the recording — and the
    /// audio that keeps this device's seat alive — until the next rejoin.
    private var feed: (callId: String, bearer: String)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    /// The hub answers a text "ping" on every socket, so a feed that has
    /// heard nothing past `silenceLimit` is half-open: frames vanish into it
    /// and no receive ever fails to reconnect it (as with the sync socket).
    private var lastReceivedAt = Date()
    private var keepaliveTask: Task<Void, Never>?
    nonisolated static let keepaliveInterval: Duration = .seconds(15)
    nonisolated static let silenceLimit: TimeInterval = 40
    /// Peak input amplitude per tap buffer (~12×/s), muted or not — the
    /// signal behind the talking-while-muted nudge and the dead-mic hint.
    var onLevel: (@MainActor (Float) -> Void)?

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )

    func start(callId: String, bearer: String) {
        stop()
        isActive = true
        feed = (callId: callId, bearer: bearer)
        openFeed()
        startEngine(label: callId)
    }

    private func openFeed() {
        guard isActive, let feed else { return }
        guard let url = HQConfig.webSocketURL(path: "/v1/calls/\(feed.callId)/transcribe") else {
            transcribeLog.error("no transcribe URL for call \(feed.callId, privacy: .public)")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(feed.bearer)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        socket = task
        lastReceivedAt = Date()
        keepaliveTask?.cancel()
        keepaliveTask = Task { @MainActor [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepaliveInterval)
                guard !Task.isCancelled, let self, let task, self.socket === task else { return }
                if Self.isFeedSilent(lastReceivedAt: self.lastReceivedAt, now: Date()) {
                    transcribeLog.warning("audio feed silent for 40s; reconnecting")
                    // Cancelling fails the pending receive, which reconnects.
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                task.send(.string("ping")) { _ in }
            }
        }
        // The server speaks only to answer a ping, but a receive loop is
        // what keeps URLSession delivering close events instead of
        // buffering them.
        receiveLoop(task)
        // A pong is the one proof the feed actually opened; only then does
        // the reconnect backoff start over.
        task.sendPing { [weak self, weak task] error in
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                guard let self, let task, self.socket === task else { return }
                self.reconnectAttempts = 0
            }
        }
    }

    nonisolated static func isFeedSilent(lastReceivedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastReceivedAt) > silenceLimit
    }

    private func scheduleFeedReconnect() {
        guard isActive, feed != nil, reconnectTask == nil else { return }
        socket = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        let delay = min(pow(2, Double(reconnectAttempts)), 30)
        reconnectAttempts += 1
        transcribeLog.info("feed reconnecting in \(delay, format: .fixed(precision: 0), privacy: .public)s")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.openFeed()
        }
    }

    /// The level tap alone — no transcription socket. The green room uses it to
    /// prove the mic before joining.
    func startLevelMonitor() {
        stop()
        isActive = true
        startEngine(label: "monitor")
    }

    #if !os(macOS)
    /// iOS hands out the microphone through the audio session, and the
    /// default category cannot record at all. Idempotent on purpose: during a
    /// call WebRTC has already set exactly this category, and re-setting it
    /// would bounce the route mid-sentence.
    private func ensureRecordingSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return }
        try? session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try? session.setActive(true)
    }
    #endif

    // The tap and converter are bound to one input format; a fresh engine
    // rebuilds them against whatever device the route change installed.
    private func startEngine(label: String) {
        #if !os(macOS)
        ensureRecordingSession()
        #endif
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let target = Self.targetFormat,
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            transcribeLog.error("no usable input format (rate \(inputFormat.sampleRate))")
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let level = Self.peakLevel(of: buffer)
            let data = Self.convert(buffer: buffer, with: converter, to: target)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onLevel?(level)
                guard !self.isMuted, let socket = self.socket, let data else { return }
                socket.send(.data(data)) { _ in }
            }
        }
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
            let format = "rate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
            transcribeLog.info("capturing call=\(label, privacy: .public) \(format, privacy: .public)")
        } catch {
            transcribeLog.error("engine start failed: \(String(describing: error), privacy: .public)")
            input.removeTap(onBus: 0)
        }
        // The engine STOPS on an input device or route change (AirPods in
        // or out, a mic unplugged) and never restarts itself; rebuild the
        // capture once the route settles.
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            transcribeLog.warning("engine configuration changed; restarting capture")
            Task { @MainActor [weak self] in self?.scheduleEngineRestart(label: label) }
        }
    }

    private func scheduleEngineRestart(label: String) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.restartTask = nil
            self.startEngine(label: label)
        }
    }

    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
    }

    /// Keeps the mute on purpose: `start` begins with `stop`, so clearing it here unmuted a muted join.
    func stop() {
        if engine != nil { transcribeLog.info("stopped") }
        isActive = false
        restartTask?.cancel()
        restartTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        keepaliveTask?.cancel()
        keepaliveTask = nil
        feed = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            if case .failure(let error) = result {
                transcribeLog.warning("socket closed: \(String(describing: error), privacy: .public)")
                Task { @MainActor [weak self] in
                    guard let self, let task, self.socket === task else { return }
                    self.scheduleFeedReconnect()
                }
                return
            }
            guard let task else { return }
            Task { @MainActor [weak self] in
                guard let self, self.socket === task else { return }
                self.lastReceivedAt = Date()
                self.receiveLoop(task)
            }
        }
    }

    private nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = abs(channel[index])
            if sample > peak { peak = sample }
        }
        return peak
    }

    // Tap callbacks arrive on the render thread; the conversion is cheap
    // enough to run there, and only the finished bytes hop to the main actor.
    private nonisolated static func convert(
        buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat
    ) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var isConsumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if isConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            isConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
