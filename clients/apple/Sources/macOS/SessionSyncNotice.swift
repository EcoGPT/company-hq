import AppKit
import Foundation

/// The one-time notice that coding-session sync is about to turn on. Sync
/// starts by default for anyone signed in, so before it first starts for a
/// person on this Mac it says what it uploads, to which server, who can read it,
/// and offers to stop. Nothing is uploaded until it has been answered.
///
/// A floating panel, not a modal alert: the app launched at login sits in the
/// menu bar with no window, and an alert's modal loop would take focus from
/// whatever the person is typing. The panel appears without activating the app,
/// nothing waits on it but the sync start. Only a button answers it: closing the panel
/// (the red button, ⌘W, Escape, quitting) is no answer at all, so it asks again
/// at the next launch and consent is never inferred from a dismissal.
enum SessionSyncNotice {
    static let shownKeyPrefix = "HQSessionSyncNoticeShown"
    /// The server's host (and port) as the person typed it at sign-in.
    static func host(_ baseURL: String) -> String {
        guard let components = URLComponents(string: baseURL), let host = components.host else {
            return "your server"
        }
        return host + (components.port.map { ":\($0)" } ?? "")
    }
    static func title(server: String) -> String { "Your coding conversations sync to \(host(server))" }
    static func body(server: String) -> String {
        "Your Claude Code and Codex conversations from the last 7 days, and new ones, are uploaded "
            + "as text to \(host(server)). Everyone on this server and the person who runs it can "
            + "read them. Secrets are hidden on a best-effort basis, so keep them out of prompts. "
            + "Pause stops it, here or later in Settings → Coding."
    }
    static let approvalTitle = "Allow HQ in Login Items"
    static let approval =
        "macOS needs you to allow HQ in System Settings → General → Login Items & Extensions "
        + "before sync can start."

    enum Kind: Equatable { case intro, loginItems }
    /// `.dismissed` is the panel closed by anything but one of its buttons.
    /// On the intro panel only `.ok` accepts and only `.pause` pauses; on the
    /// Login Items panel `.ok` is "Later". Every other value is no answer.
    enum Choice: Equatable { case ok, pause, openLoginItems, dismissed }

    /// Per person, server and version of the rules: a second person on this Mac, or a
    /// different server, is told too, because it is their conversations that upload, and
    /// so is everyone when the notice changes (`SessionSyncConfig.currentRules`).
    static func shownKey(
        personID: String, baseURL: String, rules: Int = SessionSyncConfig.currentRules
    ) -> String {
        shownKeyPrefix + ".v\(rules)." + baseURL + "/" + personID
    }

    static func shouldShow(
        defaults: UserDefaults, personID: String, baseURL: String,
        rules: Int = SessionSyncConfig.currentRules
    ) -> Bool {
        !defaults.bool(forKey: shownKey(personID: personID, baseURL: baseURL, rules: rules))
    }

    /// Recorded only once the person has pressed OK or Pause. Closing the
    /// panel or quitting while it is up records nothing, so it shows again on
    /// the next launch, and by then nothing has started.
    static func markShown(
        defaults: UserDefaults, personID: String, baseURL: String,
        rules: Int = SessionSyncConfig.currentRules
    ) {
        defaults.set(true, forKey: shownKey(personID: personID, baseURL: baseURL, rules: rules))
    }

    @MainActor private static var open: [Kind: NoticePanel] = [:]

    /// The panel while one is up (a test seam).
    @MainActor static func openWindow(_ kind: Kind) -> NSWindow? { open[kind]?.window }

    /// The open panel's buttons (a test seam).
    @MainActor static func openButtons(_ kind: Kind) -> [NSButton] { open[kind]?.buttons ?? [] }

    /// Shows the panel and returns the person's answer. A second call while
    /// one is up brings that panel forward and waits for the same answer
    /// instead of stacking another: it is the person asking again (Settings →
    /// Show notice), so the panel may be behind other windows.
    @MainActor
    static func present(_ kind: Kind, server: String) async -> Choice {
        if let panel = open[kind] {
            panel.bringForward()
            return await panel.answer()
        }
        let panel = NoticePanel(kind, server: server) { open[kind] = nil }
        open[kind] = panel
        return await panel.show()
    }
}

/// Escape closes the panel like its red button: no answer.
private final class EscapableNoticePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
private final class NoticePanel: NSObject, NSWindowDelegate {
    private let kind: SessionSyncNotice.Kind
    private let server: String
    private let didFinish: () -> Void
    private let panel: NSPanel
    /// What a button set. A close that no button caused leaves it `.dismissed`.
    private var chosen = SessionSyncNotice.Choice.dismissed
    private var isFinished = false
    private var waiters: [CheckedContinuation<SessionSyncNotice.Choice, Never>] = []

    init(_ kind: SessionSyncNotice.Kind, server: String, didFinish: @escaping () -> Void) {
        self.kind = kind
        self.server = server
        self.didFinish = didFinish
        panel = EscapableNoticePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        let heading = NSTextField(
            wrappingLabelWithString: kind == .intro
                ? SessionSyncNotice.title(server: server) : SessionSyncNotice.approvalTitle)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let text = NSTextField(
            wrappingLabelWithString: kind == .intro
                ? SessionSyncNotice.body(server: server) : SessionSyncNotice.approval)
        text.preferredMaxLayoutWidth = 380
        let buttons = NSStackView(views: choices.map { button($0.title, $0.choice) })
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, text, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        panel.title = "HQ"
        panel.identifier = NSUserInterfaceItemIdentifier("hq-session-sync-notice")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // On whichever Space the person is in, and over a full-screen app: a
        // panel left on another Space would never be seen, and nothing syncs
        // until it is answered.
        panel.collectionBehavior = Self.collectionBehavior
        panel.delegate = self
        panel.center()
    }

    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary,
    ]

    /// Without activating HQ: a login launch must not take focus.
    func bringForward() {
        panel.orderFrontRegardless()
    }

    var window: NSWindow { panel }

    /// The panel's buttons in order, the first being the one Return presses (a test seam).
    var buttons: [NSButton] {
        ((panel.contentView as? NSStackView)?.arrangedSubviews.last as? NSStackView)?
            .arrangedSubviews.compactMap { $0 as? NSButton } ?? []
    }

    private var choices: [(title: String, choice: SessionSyncNotice.Choice)] {
        kind == .intro
            ? [("OK", .ok), ("Pause", .pause)]
            : [("Open Login Items…", .openLoginItems), ("Later", .ok)]
    }

    private func button(_ title: String, _ choice: SessionSyncNotice.Choice) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(choose(_:)))
        if choice == choices.first?.choice { button.keyEquivalent = "\r" }
        return button
    }

    @objc private func choose(_ sender: NSButton) {
        chosen = choices.first { $0.title == sender.title }?.choice ?? .dismissed
        panel.close()
    }

    func show() async -> SessionSyncNotice.Choice {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            bringForward()
        }
    }

    func answer() async -> SessionSyncNotice.Choice {
        await withCheckedContinuation { waiters.append($0) }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isFinished else { return }
        isFinished = true
        didFinish()
        waiters.forEach { $0.resume(returning: chosen) }
        waiters = []
    }
}
