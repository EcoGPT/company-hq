import Foundation
import UserNotifications

// The socket delivers to every open app and this posts the local banner; APNs
// reaches the devices with no socket (a closed Mac, a phone in a pocket) when
// the build is signed with a team (`HQ_SIGNING_MODE = team`, see the README).
// The app delegate owns the remote callbacks (they only ever land there) and
// hands the token here; the store uploads it on the device bearer. A build with
// no team never registers (`PushState.isBuilt`) and keeps the socket and local
// banners, as before push. One class serves both clients: the platform differences are
// Platform's few lines, not a second notification stack.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Set by the store: a click on a banner opens its conversation. A click
    /// that cold-starts the app lands before the store exists, so it parks
    /// until the closure arrives.
    var onOpenConversation: ((String) -> Void)? {
        didSet {
            guard let handler = onOpenConversation, let id = pendingConversationId else { return }
            pendingConversationId = nil
            handler(id)
        }
    }

    /// Set by the store: every change to this device's push state is reported
    /// to the server on the device bearer. Apple accepting a push says nothing
    /// about whether a banner appeared, so the device says so out loud.
    var onPushState: ((PushState) -> Void)? {
        didSet { onPushState?(state) }
    }

    /// Set by the store: a banner for the thread being actively read is
    /// suppressed, whichever channel carried it.
    var shouldSuppressBanner: ((String) -> Bool)?

    /// Set by the store: a ring whose call is already ringing on screen
    /// has nothing to add — the panel IS the notification. Keyed by call id.
    var shouldSuppressCallBanner: ((String) -> Bool)?

    private(set) var state = PushState()
    private var pendingConversationId: String?
    private var hasAskedApple = false
    private var reportedState: PushState?
    /// Message ids this device has already handled, whichever channel
    /// delivered them. The socket and APNs both carry every message, so the
    /// second arrival is dropped by identity, never by guessing which channel
    /// was working.
    private var handledMessageIds: [String] = []
    private var handledMessageIdSet: Set<String> = []
    /// The last message this person read in each conversation. A read can
    /// arrive from this device, another device's socket, or a background push.
    /// Keep the cursor so a late message push cannot restore an old alert.
    private var readThroughByConversation: [String: String] = [:]

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            Task { @MainActor in
                if let error { self.state.error = error.localizedDescription }
                await self.refresh()
            }
        }
    }

    /// The grant callback is not the whole truth: a teammate can deny at the
    /// prompt, or switch HQ off in System Settings long after saying yes, and
    /// the app would keep believing it can banner. Re-read the real settings
    /// at launch and every activation, and take a token the moment permission
    /// appears rather than waiting for the next launch.
    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        state.authorization = Self.label(settings.authorizationStatus)
        state.areAlertsEnabled = settings.alertSetting == .enabled
        if PushState.isBuilt, state.isPermitted, state.token == nil, !hasAskedApple {
            // Registration is per-launch; a failure reports itself and is not
            // retried until the next one.
            hasAskedApple = true
            Platform.registerForRemoteNotifications()
        }
        publish()
    }

    func deviceTokenReceived(_ token: String) {
        state.token = token
        state.error = nil
        publish()
    }

    /// The phone's PushKit (ring) token, or nil when iOS withdrew it. Reported
    /// on the same route as the alert token; the Mac never has one.
    func voipTokenReceived(_ token: String?) {
        state.voipToken = token
        publish()
    }

    func registrationFailed(_ message: String) {
        state.token = nil
        state.error = message
        publish()
    }

    /// Only a changed reading is worth a round trip; activation is frequent.
    private func publish() {
        guard state != reportedState else { return }
        reportedState = state
        onPushState?(state)
    }

    func post(title: String, body: String, conversationId: String, messageId: String) {
        #if os(iOS)
        // The Mac always posts: its `willPresent` runs whenever the app is
        // alive, so the claim below covers both channels.
        guard !Self.leavesBannerToPush(
            isActive: Platform.isActive, hasToken: state.token != nil, messageId: messageId
        ) else { return }
        #endif
        guard !isMessageRead(conversationId: conversationId, messageId: messageId),
              state.isPermitted, didClaim(messageId)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // The same grouping key the push carries as `thread-id`: without it
        // the OS files local and remote copies under two different stacks.
        content.threadIdentifier = conversationId
        content.userInfo = [
            "conversation_id": conversationId, "is_local": true, "message_id": messageId,
        ]
        // The message id is the identifier: a push for the same message that
        // beat the socket here is replaced in place, never doubled.
        let request = UNNotificationRequest(
            identifier: messageId, content: content, trigger: nil
        )
        Task {
            // The claim above only wins races INSIDE this process. On iOS the
            // system presents a push for a non-foreground app without asking
            // `willPresent`, so a banner can already be on the lock screen
            // with no claim recorded: the delivered list is the only truth of
            // what the user was shown. Checked by message id, never by request
            // identifier (a delivered remote notification's identifier is the
            // system's).
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let alreadyShown = delivered.contains {
                $0.request.content.userInfo["message_id"] as? String == messageId
            }
            guard !alreadyShown,
                  !self.isMessageRead(conversationId: conversationId, messageId: messageId)
            else { return }
            try? await center.add(request)
        }
    }

    /// For the iPhone: one that is not active and holds a push token is about
    /// to get this same message as a system-presented push. Outside the
    /// foreground `willPresent` is never consulted, so the claim in `post`
    /// cannot dedupe it, and a local copy could only double it. A phone with
    /// no token has only the local banner, and a meeting reminder never comes
    /// by push.
    static func leavesBannerToPush(isActive: Bool, hasToken: Bool, messageId: String) -> Bool {
        !isActive && hasToken && !messageId.hasPrefix("meeting-")
    }

    /// Remove message alerts that this person has read. Request identifiers
    /// for remote notifications belong to the system, so first inspect each
    /// delivered payload and then remove the identifiers the system returned.
    func clearMessageNotifications(readThrough cursors: [String: String]) {
        updateReadCursors(cursors)
        Task { await removeReadMessageNotifications() }
    }

    func resetReadCursors() {
        readThroughByConversation = [:]
    }

    private func updateReadCursors(_ cursors: [String: String]) {
        for (conversationId, messageId) in cursors {
            if let current = readThroughByConversation[conversationId], current >= messageId {
                continue
            }
            readThroughByConversation[conversationId] = messageId
        }
    }

    private func removeReadMessageNotifications() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let identifiers = Self.messageNotificationIdentifiers(
            in: delivered.map(\.request), readThrough: readThroughByConversation
        )
        if !identifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    static func messageNotificationIdentifiers(
        in requests: [UNNotificationRequest], readThrough cursors: [String: String]
    ) -> [String] {
        requests.compactMap { request in
            let info = request.content.userInfo
            guard info["call_id"] == nil,
                  let conversationId = info["conversation_id"] as? String,
                  let messageId = info["message_id"] as? String,
                  let readThrough = cursors[conversationId],
                  messageId <= readThrough
            else { return nil }
            return request.identifier
        }
    }

    /// A remote push handed to the app delegate. While backgrounded the system
    /// presents it itself, without consulting `willPresent`, so claiming it
    /// here means the socket's copy loses instead of doubling what is already
    /// on screen. While active it is left unclaimed: `willPresent` decides, and
    /// a claim here first would silence both copies. A read-sync push
    /// (`read_through_message_id`) moves the read cursor and clears the banners
    /// it covers instead.
    func noteRemoteDelivery(userInfo: [AnyHashable: Any], isActive: Bool) async {
        if let conversationId = userInfo["conversation_id"] as? String,
           let messageId = userInfo["read_through_message_id"] as? String {
            updateReadCursors([conversationId: messageId])
            await removeReadMessageNotifications()
            return
        }
        guard !isActive, let messageId = userInfo["message_id"] as? String else { return }
        _ = didClaim(messageId)
    }

    private func isMessageRead(conversationId: String, messageId: String) -> Bool {
        guard let readThrough = readThroughByConversation[conversationId] else { return false }
        return messageId <= readThrough
    }

    /// True when this call is the one that claimed the message id: the other
    /// channel's copy loses. Bounded: a banner racing a day-old message is not
    /// a case worth remembering.
    func didClaim(_ messageId: String) -> Bool {
        guard !handledMessageIdSet.contains(messageId) else { return false }
        handledMessageIdSet.insert(messageId)
        handledMessageIds.append(messageId)
        if handledMessageIds.count > 400 {
            handledMessageIdSet.remove(handledMessageIds.removeFirst())
        }
        return true
    }

    private static func label(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        case .provisional: return "provisional"
        default: return "unknown"
        }
    }

    /// Banners show even while the app is frontmost — except for the one
    /// thread the user is actively reading, whose transcript already shows
    /// the message.
    ///
    /// Both delegate methods stay on the main actor DELIBERATELY. Marked
    /// `nonisolated async`, their bridged ObjC completion fires on whatever
    /// executor the method resumed on — and UIKit runs its state-restoration
    /// snapshot inside that completion, asserts it is off the main thread,
    /// and aborts. That crash ate every notification tap on iOS: the app
    /// died mid-activation and the tap appeared to do nothing at all.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        presentation(for: notification.request.content.userInfo)
    }

    /// What `willPresent` answers for a payload (split out so it can be tested
    /// without a `UNNotification`).
    func presentation(for info: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
        if info["call_id"] == nil,
           let conversationId = info["conversation_id"] as? String,
           let messageId = info["message_id"] as? String,
           isMessageRead(conversationId: conversationId, messageId: messageId) {
            return []
        }
        let isLocal = info["is_local"] as? Bool ?? false
        if !isLocal, let messageId = info["message_id"] as? String {
            // The socket already bannered this one (or deliberately did not).
            if !didClaim(messageId) { return [] }
        }
        if let callId = info["call_id"] as? String {
            // A ring is answerable in its own panel; a second banner behind
            // it is noise.
            let isRinging = shouldSuppressCallBanner?(callId) ?? false
            return isRinging ? [] : [.banner, .sound]
        }
        if let id = info["conversation_id"] as? String {
            if shouldSuppressBanner?(id) ?? false { return [] }
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["conversation_id"] as? String else { return }
        if let handler = onOpenConversation {
            handler(id)
        } else {
            pendingConversationId = id
        }
    }
}

/// What this device can actually do with a notification: the Settings row, and
/// what is reported to the server so an admin can answer "why is this device
/// silent" without asking over someone's shoulder.
struct PushState: Equatable, Sendable {
    var authorization = "not_determined"
    var areAlertsEnabled = false
    var token: String?
    /// The PushKit (ring) token, iOS only, in a build signed with a team. It
    /// rides the same report as `voip_token`. Not part of `wire`: a phone that
    /// can banner but not ring is still "authorized".
    var voipToken: String?
    var error: String?

    /// True in a build signed with a team (`HQ_SIGNING_MODE = team` defines
    /// `HQ_PUSH`). Any other build never asks Apple for a token and never
    /// reports push to the server: it behaves as if push did not exist.
    #if HQ_PUSH
    static let isBuilt = true
    #else
    static let isBuilt = false
    #endif

    var isPermitted: Bool { authorization == "authorized" || authorization == "provisional" }

    /// The one short string the server stores: first failing rung wins.
    var wire: String {
        if let error { return "error: \(error.prefix(100))" }
        if !isPermitted { return authorization }
        if !areAlertsEnabled { return "alerts_off" }
        if token == nil { return "no_token" }
        return "authorized"
    }

    #if os(macOS)
    private static let settingsAppName = "System Settings"
    #else
    private static let settingsAppName = "Settings"
    #endif

    /// The same thing as a sentence, for the Settings row.
    var summary: String {
        switch wire {
        case "alerts_off":
            return "Allowed, but banners are turned off in \(Self.settingsAppName)."
        case "authorized":
            // Focus swallows a delivered banner and reports nothing to us:
            // it is the one cause this row cannot see, so it names it.
            return "On — registered for push. If banners still don't appear, "
                + "check Focus / Do Not Disturb."
        case "denied":
            return "Turned off for HQ. Notifications will never appear until it is allowed."
        case "no_token":
            guard Self.isBuilt else {
                return "On — banners appear while HQ is running. If they still don't, "
                    + "check Focus / Do Not Disturb."
            }
            return "Banners appear while HQ is running. Apple has not issued a push token yet."
        case "not_determined":
            return "Not answered yet — HQ asks once per launch."
        default:
            guard let error else { return wire }
            return isPermitted && Self.isBuilt
                ? "Banners appear while HQ is running. Push is off: \(error)"
                : "Notifications failed: \(error)"
        }
    }
}

/// A ring carried by a VoIP push (PushKit, iPhone only), read from the keys the
/// server sends: `call_id`, `conversation_id`, `caller_name`,
/// `conversation_title` and `expires_at` (docs/push.md). Nil when the push
/// names no call CallKit can key (a UUID) or no room: iOS still requires a
/// report for it, so the phone files one and ends it at once.
struct VoIPRing: Equatable {
    let callId: String
    let uuid: UUID
    let conversationId: String
    let callerName: String
    let conversationTitle: String?
    let expiresAt: Date

    /// A push with no `expires_at` rings this long, as the server's own rings do.
    static let defaultRingSeconds: TimeInterval = 45

    init?(payload: [AnyHashable: Any], now: Date = Date()) {
        guard let callId = payload["call_id"] as? String, let uuid = UUID(uuidString: callId),
              let conversationId = payload["conversation_id"] as? String, !conversationId.isEmpty
        else { return nil }
        self.callId = callId
        self.uuid = uuid
        self.conversationId = conversationId
        callerName = Self.callerName(in: payload)
        let title = (payload["conversation_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        conversationTitle = title.isEmpty ? nil : title
        expiresAt = (payload["expires_at"] as? String).map(ISO8601.parse)
            ?? now.addingTimeInterval(Self.defaultRingSeconds)
    }

    /// Who is calling, for a ring or for a push that could not be read: what
    /// CallKit shows, even for the instant before an unreadable one is ended.
    static func callerName(in payload: [AnyHashable: Any]) -> String {
        let name = (payload["caller_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Someone" : name
    }
}
