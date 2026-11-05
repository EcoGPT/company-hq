import AVFAudio
import CallKit
import Foundation
import os
import PushKit

// Ring diagnostics land in the unified log beside the call engine's, and for
// the same reason: "why didn't my phone ring" is answered from a log dump,
// never from a guess.
private let ringLog = Logger(subsystem: HQIdentity.logSubsystem, category: "callkit")

/// The phone's ring surface: every incoming HQ call reports into CallKit —
/// the native full-screen incoming-call screen, the system ringtone, the
/// lock-screen answer — whichever channel carried it. The socket's `call_ring`
/// frame lands here while the app is running. In a build signed with a team the
/// VoIP push lands here when it is not, including the background launch the push
/// itself starts. One claim per call id decides which channel rings, never a
/// guess about which one is working. A build with no team has no push, so a
/// closed app does not ring.
///
/// The Mac keeps its floating panel and its own ringtone: AppKit has no
/// CallKit, and the panel already rings over everything.
@MainActor
final class CallKitCoordinator: NSObject {
    static let shared = CallKitCoordinator()

    /// The app's one store, attached at App init. App init runs for a
    /// background VoIP launch too, where no scene (and no `.task`) ever comes.
    weak var store: AppStore?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var pushRegistry: PKPushRegistry?
    private var ringing: [String: RingContext] = [:]
    /// The call answered through CallKit that is (or is becoming) HQ's
    /// active call — ended in CallKit when HQ's own call state ends.
    private var activeCallKitCallId: String?

    private struct RingContext {
        let conversationId: String
        let uuid: UUID
        var pollTask: Task<Void, Never>?
    }

    override private init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Called by the app delegate at every launch of a team build. Making the
    /// registry is what hands over the VoIP push that started a background
    /// launch: making it later loses the ring that woke the app.
    func startPushKit() {
        guard pushRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
    }

    func isRinging(_ callId: String) -> Bool { ringing[callId] != nil }

    /// Report a ring to CallKit. The socket passes `mustReport: false` and is
    /// dropped when the call is already claimed. A VoIP push passes true: iOS
    /// stops an app that takes a VoIP push without reporting a call, so that
    /// path always reports, and the system's "already exists" answer for a call
    /// the socket rang first is harmless.
    func reportRing(
        callId: String,
        conversationId: String,
        callerName: String,
        conversationTitle: String?,
        expiresAt: Date,
        mustReport: Bool = false
    ) {
        guard let uuid = UUID(uuidString: callId) else { return }
        let isClaimed = ringing[callId] != nil || activeCallKitCallId == callId
        if isClaimed && !mustReport { return }
        if !isClaimed {
            guard expiresAt > Date() else {
                // Over before it arrived (a late push): nothing to ring, but a
                // VoIP push still owes CallKit a report, so file it and end it.
                if mustReport { reportDeadRing(uuid: uuid, callerName: callerName) }
                return
            }
            ringing[callId] = RingContext(conversationId: conversationId, uuid: uuid, pollTask: nil)
        }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName =
            conversationTitle.map { "\(callerName) · \($0)" } ?? callerName
        update.hasVideo = false
        ringLog.info("report ring call=\(callId, privacy: .public) mustReport=\(mustReport, privacy: .public)")
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    // The one benign answer: this UUID is already ringing
                    // (the other channel got here first). Anything else
                    // means the system refused the call.
                    let benign = (error as? CXErrorCodeIncomingCallError)?.code == .callUUIDAlreadyExists
                    let reason = String(describing: error)
                    let line = "report refused call=\(callId) benign=\(benign): \(reason)"
                    ringLog.error("\(line, privacy: .public)")
                    // A repeat report (the push behind the socket) failing says
                    // nothing about the ring already showing: keep that one.
                    if !benign && !isClaimed { self.forgetRing(callId) }
                    return
                }
                ringLog.info("ringing call=\(callId, privacy: .public)")
                // A repeat report keeps the watcher the first one started.
                if !isClaimed { self.watchRing(callId: callId, expiresAt: expiresAt) }
            }
        }
    }

    /// A VoIP push whose ring is already over, or could not be read: report it
    /// and end it at once, which keeps the report-every-push rule without
    /// ringing anyone.
    private func reportDeadRing(uuid: UUID, callerName: String) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
            Task { @MainActor in
                self?.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
            }
        }
    }

    /// While CallKit rings, the truth lives on the server: the ring can be
    /// answered on a Mac, declined, or the call can end. The socket's frames
    /// say so; a phone woken in the background has no socket, so the watcher
    /// asks too, and the deadline ends the ring even when the network answers
    /// nothing.
    private func watchRing(callId: String, expiresAt: Date) {
        ringing[callId]?.pollTask?.cancel()
        ringing[callId]?.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if Date() >= expiresAt {
                    await MainActor.run { self?.endRing(callId, because: .unanswered) }
                    return
                }
                let (isLive, isActive) = await MainActor.run { (self?.store?.isSocketLive ?? false, Platform.isActive) }
                try? await Task.sleep(
                    for: .seconds(RingPollPolicy.sleep(isSocketLive: isLive, isAppActive: isActive, until: expiresAt)))
                guard !Task.isCancelled else { return }
                guard let bearer = await MainActor.run(body: {
                    self?.store?.client?.bearer ?? Keychain.load()?.bearer
                }) else { continue }
                guard let snapshot = try? await HQClient(bearer: bearer).calls() else { continue }
                let stillRinging = snapshot.ringing.contains { $0.call.id == callId }
                if !stillRinging {
                    let stillLive = snapshot.calls.contains { $0.id == callId && $0.isLive }
                    await MainActor.run {
                        self?.endRing(callId, because: stillLive ? .answeredElsewhere : .remoteEnded)
                    }
                    return
                }
            }
        }
    }

    /// The hub said this ring is over (answered or declined elsewhere, or
    /// the call ended). Frame-driven — `AppStore` calls it on
    /// `call_ring_ended`.
    func endRing(_ callId: String) {
        endRing(callId, because: .answeredElsewhere)
    }

    private func endRing(_ callId: String, because reason: CXCallEndedReason) {
        guard let context = ringing[callId] else { return }
        ringLog.info(
            "ring ended call=\(callId, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        context.pollTask?.cancel()
        ringing[callId] = nil
        provider.reportCall(with: context.uuid, endedAt: nil, reason: reason)
    }

    private func forgetRing(_ callId: String) {
        ringing[callId]?.pollTask?.cancel()
        ringing[callId] = nil
    }

    /// An app-started join becomes a system call too:
    /// joining a meeting and locking the phone must persist as a live call —
    /// the lock-screen call UI, the Dynamic Island pill, and no chance of
    /// iOS squeezing the audio. The answered-incoming path already holds the
    /// session and is skipped by the claim guard.
    func noteOutgoingCall(callId: String, title: String) {
        guard activeCallKitCallId != callId, ringing[callId] == nil else { return }
        guard let uuid = UUID(uuidString: callId) else { return }
        activeCallKitCallId = callId
        // Same audio contract as an answer: the system activates the
        // session and WebRTC waits for the didActivate callback.
        CallEngine.callKitWillDrive()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: title))
        callController.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor in
                guard let self, let error else { return }
                let line = "start call refused call=\(callId): \(String(describing: error))"
                ringLog.error("\(line, privacy: .public)")
                self.activeCallKitCallId = nil
                // No system call means no didActivate is coming — hand the
                // session back to WebRTC or the joined call stays silent.
                CallEngine.callKitStartFailed()
            }
        }
    }

    /// HQ's own call state ended (left, join failed, signed out): the
    /// CallKit session must not outlive it.
    func noteCallEnded(_ callId: String) {
        if ringing[callId] != nil {
            endRing(callId, because: .remoteEnded)
            return
        }
        guard activeCallKitCallId == callId, let uuid = UUID(uuidString: callId) else { return }
        activeCallKitCallId = nil
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
    }
}

extension CallKitCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            let callId = action.callUUID.uuidString.lowercased()
            ringLog.info("answer call=\(callId, privacy: .public)")
            guard let context = self.ringing[callId], let store = self.store else {
                ringLog.error("answer failed call=\(callId, privacy: .public): no ring context")
                action.fail()
                return
            }
            context.pollTask?.cancel()
            self.ringing[callId] = nil
            self.activeCallKitCallId = callId
            // WebRTC must wait for CallKit's audio activation instead of
            // claiming the session itself — without this, a call answered
            // from the lock screen connects silent.
            CallEngine.callKitWillDrive()
            store.start()
            await store.answerCallKitRing(conversationId: context.conversationId)
            if store.activeCallId == callId {
                ringLog.info("answered and joined call=\(callId, privacy: .public)")
                action.fulfill()
            } else {
                ringLog.error("answer join failed call=\(callId, privacy: .public)")
                self.activeCallKitCallId = nil
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            let callId = action.callUUID.uuidString.lowercased()
            ringLog.info("outgoing call registered call=\(callId, privacy: .public)")
            // The engine is already joining when this action is requested;
            // reporting connected now keeps the system UI honest enough, and
            // the audio comes alive at didActivate either way.
            self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            self.provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let callId = action.callUUID.uuidString.lowercased()
            if let context = self.ringing[callId] {
                context.pollTask?.cancel()
                self.ringing[callId] = nil
                self.store?.start()
                await self.store?.declineRungCall(callId: callId)
            } else if self.activeCallKitCallId == callId {
                self.activeCallKitCallId = nil
                await self.store?.leaveCall()
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        CallEngine.callKitDidActivate(audioSession)
        let outputs = audioSession.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        ringLog.notice("audio activated outputs=\(outputs, privacy: .public) volume=\(audioSession.outputVolume)")
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        CallEngine.callKitDidDeactivate(audioSession)
        ringLog.notice("audio deactivated")
    }
}

extension CallKitCoordinator: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType
    ) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            NotificationManager.shared.voipTokenReceived(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Task { @MainActor in
            NotificationManager.shared.voipTokenReceived(nil)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let info = payload.dictionaryPayload
        // The registry delivers on the main queue (`startPushKit`), so the report
        // to CallKit is made here and now, before this method returns, as iOS
        // requires of every VoIP push.
        MainActor.assumeIsolated {
            defer { completion() }
            let ring = VoIPRing(payload: info)
            ringLog.info("voip push call=\(ring?.callId ?? "?", privacy: .public)")
            guard let ring else {
                // Unreadable, but a VoIP push still owes CallKit a report.
                reportDeadRing(uuid: UUID(), callerName: VoIPRing.callerName(in: info))
                return
            }
            reportRing(
                callId: ring.callId,
                conversationId: ring.conversationId,
                callerName: ring.callerName,
                conversationTitle: ring.conversationTitle,
                expiresAt: ring.expiresAt,
                mustReport: true
            )
        }
    }
}
