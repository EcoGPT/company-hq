import Foundation
import os

// Sync diagnostics land in the unified log beside the call ones, so the same
// `log show --predicate 'subsystem == "<bundle id>"'` dump answers "why did
// this Mac miss messages". Error text and attempt counts are infrastructure,
// not user content, so they log as public; the hub records its own half of
// every drop in the ops tape.
private let syncLog = Logger(subsystem: HQIdentity.logSubsystem, category: "sync")

// One WebSocket per device. Reconnects with backoff; every (re)connect sends a
// sync from the last seen message id so nothing is lost across gaps.
@MainActor
final class EventSocket {
    /// True only after a frame has actually arrived on the current task —
    /// the banner authority: while live, the local path owns notifications
    /// and remote pushes stay silent.
    private(set) var isLive = false
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnect = EventSocketReconnectPolicy()
    /// One frame can carry up to 500 hydrated tasks or a full sync batch; the
    /// 1 MiB default fails the receive on a big one and drops the socket.
    private static let maximumMessageSize = 16 << 20
    private var isStopped = false
    /// The last time anything arrived on the current task. The hub answers
    /// every ping, so a socket that has heard nothing across two and a half
    /// ping intervals is half-open: sends vanish into it — call heartbeats
    /// included — and no error ever surfaces to trigger a reconnect.
    private(set) var lastReceivedAt = Date()
    /// When the current connection attempt started, and whether the socket is
    /// between attempts, waiting out its backoff. The phone's foreground check
    /// reads both to leave a handshake or a backoff of its own alone.
    private(set) var attemptStartedAt: Date?
    private(set) var isWaitingToRetry = false
    private let bearer: String
    private let onFrame: (ServerFrame) -> Void
    private let onConnect: () -> Void

    init(bearer: String, onConnect: @escaping () -> Void, onFrame: @escaping (ServerFrame) -> Void) {
        self.bearer = bearer
        self.onConnect = onConnect
        self.onFrame = onFrame
    }

    func connect() {
        guard !isStopped, let url = HQConfig.webSocketURL else { return }
        syncLog.info("socket connecting, attempt \(self.reconnect.attempts, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        self.task = task
        isLive = false
        isWaitingToRetry = false
        attemptStartedAt = Date()
        reconnect.attemptStarted()
        lastReceivedAt = Date()
        task.resume()
        // onConnect waits for the first frame, or for the first failure of a streak (see
        // EventSocketReconnectPolicy): a socket that cannot open must not run the full refresh on every retry.
        receiveLoop(on: task)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let task = self.task else { return }
                if Date().timeIntervalSince(self.lastReceivedAt) > 75 {
                    syncLog.warning("socket silent for 75s; reconnecting")
                    // Cancelling fails the pending receive, which is the one
                    // path that reconnects.
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                task.send(.string("ping")) { error in
                    guard let error else { return }
                    syncLog.warning("ping send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stop() {
        isStopped = true
        isLive = false
        isWaitingToRetry = false
        pingTimer?.invalidate()
        task?.cancel(with: .normalClosure, reason: nil)
    }

    func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8)
        else {
            syncLog.error("frame dropped: not JSON-encodable")
            return
        }
        task?.send(.string(text)) { error in
            guard let error else { return }
            syncLog.warning("frame send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What one received message turns into. Built in the URLSession callback,
    /// off the main actor: the text is parsed there, once, and only the value
    /// crosses to main. `frame` is nil for a pong or a binary message, which
    /// prove the connection without carrying anything.
    private struct Received: Sendable {
        let frame: ServerFrame?
    }

    private nonisolated static func received(_ message: URLSessionWebSocketTask.Message) -> Received {
        guard case .string(let text) = message, text != "pong" else { return Received(frame: nil) }
        return Received(frame: ServerFrame.decode(Data(text.utf8)))
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            // Runs on URLSession's queue. Decode here; the receive is re-armed
            // only after the main-actor turn below, so frames reach onFrame in
            // the order they arrived.
            let outcome = result.map(Self.received)
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch outcome {
                case .success(let received):
                    // A frame in flight when stop() ran must not fire onConnect.
                    guard !self.isStopped else { return }
                    let isFirstFrame = !self.isLive
                    self.isLive = true
                    self.lastReceivedAt = Date()
                    if isFirstFrame {
                        // The socket is open: only now is it worth a refresh.
                        // The backoff is not reset here; a socket earns that by
                        // staying up (see scheduleReconnect).
                        self.reconnect.wentLive(at: Date())
                        self.onConnect()
                    }
                    if let frame = received.frame { self.onFrame(frame) }
                    self.receiveLoop(on: task)
                case .failure(let error):
                    // The one place every drop surfaces — this error was
                    // discarded for months and left reconnect loops invisible.
                    syncLog.warning(
                        "socket dropped: \(error.localizedDescription, privacy: .public)"
                    )
                    self.isLive = false
                    // An HTTP answer to the upgrade (a 401 for a revoked bearer
                    // included) is the hub speaking; no answer is a path that
                    // is not up yet, and does not earn the streak's refresh.
                    self.scheduleReconnect(
                        reachedServer: (task.response as? HTTPURLResponse) != nil,
                        timedOut: (error as? URLError)?.code == .timedOut
                    )
                }
            }
        }
    }

    private func scheduleReconnect(reachedServer: Bool, timedOut: Bool = false) {
        guard !isStopped else { return }
        pingTimer?.invalidate()
        task = nil
        // Jittered 0.5x-1.5x so a hub deploy, which drops every device at
        // once, is not answered by every device in the same second.
        let next = reconnect.dropped(
            at: Date(), jitter: Double.random(in: 0.5...1.5), reachedServer: reachedServer, timedOut: timedOut
        )
        isWaitingToRetry = true
        syncLog.info(
            "reconnecting in \(next.delay, format: .fixed(precision: 1), privacy: .public)s, attempt \(self.reconnect.attempts, privacy: .public)"
        )
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(next.delay))
            self.connect()
        }
        // Once per failure streak, after the dead task is cleared: the refresh answers a revoked
        // bearer's 401 with a sign-out, and loads over REST while the socket will not open.
        if next.refresh { onConnect() }
    }
}
