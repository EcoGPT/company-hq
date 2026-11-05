import SwiftUI

// Everything in a transcript that is NOT a message bubble: the quiet-stretch
// timestamp, the centered group events and their folded runs, a bot's single
// work row, the "via Claude" mark, and the live indicators a room shows while
// someone — or something — is about to speak.
//
// Shared by both clients: one rule with two implementations would give two
// behaviours. They draw entirely from the tokens, so the Mac and the phone
// get the same rows at each platform's own reading size.

// The centered gray break Messages stamps over a quiet stretch: the day
// bold, the time regular — "Today 2:14 PM", "Yesterday 9:41 AM", a weekday
// within the week, then full dates.
struct TimestampSeparator: View {
    let date: Date

    var body: some View {
        (Text(dayLabel).fontWeight(.semibold)
            + Text(" \(date.formatted(date: .omitted, time: .shortened))"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private var dayLabel: String { RelativeStamp.day(date) }
}

// The centered gray line Messages drops into the transcript when the group
// itself changes — someone added, someone leaving, a rename. The server
// composes it in the third person; whoever is looking reads themselves in
// the first: the actor sees "You added…", the subject sees "…added you".
// The 0041 attribution mark: typed-by-you and sent-by-your-tooling must
// never be indistinguishable.
struct ViaClaudeChip: View {
    var body: some View {
        Text("via Claude")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

struct GroupEventRow: View {
    @Environment(AppStore.self) private var store
    let message: Message
    var isFeed = false

    var body: some View {
        if isFeed {
            EventBubble(headline: viewerText(message, viewer: store.me))
                .id(message.id)
        } else {
            Text(viewerText(message, viewer: store.me))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .id(message.id)
        }
    }
}

// Only a real message wears a face — so an indicator
// carries none, and instead starts where the message it is promising will:
// one avatar column in, since a bot's reply always makes room for its mark.

// A bot's turn, never more than ONE row (the raw trail of
// every step was "GROSS"). Live, it says what the bot is doing right now and
// the words shimmer; finished, it is the record — "Worked for 45s" — with the
// steps it took behind the chevron.
struct WorkRow: View {
    let message: Message

    var body: some View {
        if message.isAgentJob && message.isWorking {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                EventBubble(
                    avatarName: message.senderName,
                    headline: message.agentJobHeadline(at: context.date),
                    isShimmering: true
                )
            }
            .id(message.id)
        } else if message.isWorking {
            // While it works, the mark is HERE — there is no message yet to
            // wear it. It moves down to the reply the
            // moment the reply lands, and this row keeps its place in the lane.
            EventBubble(
                avatarName: message.senderName,
                headline: "\(message.workSteps.last ?? "Working")…",
                isShimmering: true
            )
            .id(message.id)
        } else {
            EventBubble(headline: message.workHeadline, details: message.workSteps)
                .id(message.id)
        }
    }
}

// The transcript's quiet bubble: what a row that is NOT a message looks like —
// a bot's turn, and every event in the Updates feed, which is nothing but
// events and read as a centered wall. One line on the message lane, and
// whatever it stacks waits behind the chevron.
struct EventBubble: View {
    var avatarName: String?
    let headline: String
    var expandedHeadline: String?
    var details: [String] = []
    var isShimmering = false
    @State private var isExpanded = false

    var body: some View {
        // The avatar column is 28 + 6 of spacing — exactly the lane's gutter,
        // so a row that draws no face still starts on the same line.
        HStack(alignment: .top, spacing: 6) {
            if let avatarName {
                BotAvatarView(name: avatarName, size: 28)
            }
            VStack(alignment: .leading, spacing: 6) {
                if isShimmering {
                    ShimmerLabel(text: headline)
                } else if details.isEmpty {
                    line(headline)
                } else {
                    Button {
                        withAnimation(.snappy(duration: Tokens.Motion.base)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            line(isExpanded ? (expandedHeadline ?? headline) : headline)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Tokens.Palette.inkTertiary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Show less" : "Show all \(details.count + 1)")
                }
                if isExpanded, !details.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle()
                                    .fill(Tokens.Palette.inkTertiary)
                                    .frame(width: 3, height: 3)
                                Text(detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Tokens.Palette.inkTertiary)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // The cap goes OUTSIDE the background, exactly as the bubbles do
            // it: inside, the frame would stretch the bubble to 420pt of grey
            // around three words.
            .frame(maxWidth: Tokens.Bubble.maxWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, avatarName == nil ? Tokens.Bubble.avatarGutter : 0)
        .padding(.vertical, 2)
    }

    private func line(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 13))
            .foregroundStyle(Tokens.Palette.inkTertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// A stack of events one actor produced in one sitting, folded to its first
// line plus a count. The chevron unfolds the rest in place — nothing is
// hidden, only stacked.
struct GroupEventRun: View {
    @Environment(AppStore.self) private var store
    let messages: [Message]
    var isFeed = false
    @State private var isExpanded = false

    var body: some View {
        if isFeed {
            EventBubble(
                headline: summaryText(isExpanded: false),
                expandedHeadline: summaryText(isExpanded: true),
                details: messages.dropFirst().map { viewerText($0, viewer: store.me) }
            )
            .id(messages[0].id)
        } else {
            stack
        }
    }

    private var stack: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(summary)
                        .multilineTextAlignment(.center)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show less" : "Show all \(messages.count)")

            if isExpanded {
                ForEach(messages.dropFirst()) { GroupEventRow(message: $0) }
            }
        }
        // The transcript scrolls to the newest message by id, and a folded
        // run is the only view carrying the ones it stacks.
        .id(isExpanded ? messages[0].id : (messages.last?.id ?? messages[0].id))
    }

    // "Scout completed “Plan review” + 12 more" — the first event's own
    // sentence, its full stop traded for the count.
    private var summary: String { summaryText(isExpanded: isExpanded) }

    private func summaryText(isExpanded: Bool) -> String {
        let first = viewerText(messages[0], viewer: store.me)
        let stem = first.hasSuffix(".") ? String(first.dropLast()) : first
        return isExpanded ? first : "\(stem) + \(messages.count - 1) more"
    }
}

// A group event as the viewer reads it: their own actions say "You", and
// their name inside someone else's says "you".
func viewerText(_ message: Message, viewer: Person?) -> String {
    var text = message.content
    guard let me = viewer else { return text }
    if message.senderPersonId == me.id, text.hasPrefix(message.senderName) {
        text = "You" + text.dropFirst(message.senderName.count)
    } else if let range = text.range(of: me.name) {
        text = text.replacingCharacters(in: range, with: "you")
    }
    return text
}

// what the work IS deserves to be read. So the label stays, and light travels
// across it for as long as the turn runs.
struct BotActivityLine: View {
    @Environment(AppStore.self) private var store
    let conversationId: String
    let isGroup: Bool
    /// Bumped when the line's own expiry passes, so the body runs again and
    /// finds the activity gone even if the store never wrote another frame.
    @State private var expiryTick = 0

    var body: some View {
        let _ = expiryTick
        if let activity = store.botActivity(in: conversationId) {
            EventBubble(
                avatarName: activity.name,
                headline: isGroup
                    ? "\(activity.name) — \(activity.label)…" : "\(activity.label)…",
                isShimmering: true
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            // The store only checks `expiresAt` when something asks, and if
            // the clearing frame is lost nothing would: the shimmer (and its
            // animation) would run until an unrelated invalidation. Sleep to
            // the expiry and re-ask. A fresh `botState` changes the id, which
            // restarts the wait for the new deadline.
            .task(id: store.botActivityByConversation[conversationId]?.expiresAt) {
                await ExpiryWait.sleep(until: store.botActivityByConversation[conversationId]?.expiresAt)
                if !Task.isCancelled { expiryTick &+= 1 }
            }
        }
    }
}

/// Sleeps until a deadline (plus a hair, so `Date() > deadline` holds when the
/// caller wakes). Returns at once for a missing or past deadline, and early —
/// without the caller doing anything — when its task is cancelled.
enum ExpiryWait {
    static func sleep(until deadline: Date?) async {
        guard let deadline else { return }
        let seconds = deadline.timeIntervalSinceNow + 0.05
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// Apple's own "at work" idiom: the words stay legible in the quiet ink while
// a band of the full ink sweeps across them, masked to the glyphs.
struct ShimmerLabel: View {
    let text: String

    private let font = Font.system(size: 13)

    var body: some View {
        WindowVisibilityReader { isVisible in
            Text(text)
                .font(font)
                .foregroundStyle(Tokens.Palette.inkTertiary)
                .overlay {
                    // The band LEAVES the tree while the window is not being
                    // drawn: removal is the one way to end a repeatForever
                    // that cannot fail to restart — reinsertion runs onAppear
                    // again. The label underneath keeps the layout identical.
                    if isVisible {
                        ShimmerBandView(text: text, font: font, ink: Tokens.Palette.ink)
                            .accessibilityHidden(true)
                    }
                }
        }
    }
}

// iOS says it without words: a grey bubble of three dots that breathe, on the
// incoming bubble's own left edge — behind the typists' faces in a group,
// which is the one place the dots alone would not say who.
struct TypingLine: View {
    @Environment(AppStore.self) private var store
    let conversationId: String
    /// Bumped when the soonest typist's expiry passes (see `BotActivityLine`).
    @State private var expiryTick = 0

    private var isGroup: Bool {
        store.conversation(conversationId)?.kind == "group"
    }

    /// The soonest moment a typist still showing stops showing — the same
    /// `expiresAt` values `typingNames` filters on, read from the same store.
    private var nextExpiry: Date? {
        let now = Date()
        return store.typingByConversation[conversationId]?.values.filter { $0 > now }.min()
    }

    var body: some View {
        let _ = expiryTick
        let names = store.typingNames(in: conversationId)
        if !names.isEmpty {
            HStack(alignment: .center, spacing: 6) {
                // A person keeps their face here — the dots alone would not
                // say who is typing, and a group row has the column for it.
                if isGroup {
                    ForEach(names.prefix(3), id: \.self) { name in
                        AvatarView(name: name, size: 28)
                    }
                }
                TypingBubble()
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.bottom, 4)
            // Typing frames carry their own expiry, and nothing re-asks when
            // it passes. Wake at the soonest one so a lost "stopped" frame
            // cannot leave the dots breathing until relaunch; the wait
            // restarts whenever the soonest deadline changes.
            .task(id: nextExpiry) {
                await ExpiryWait.sleep(until: nextExpiry)
                if !Task.isCancelled { expiryTick &+= 1 }
            }
        }
    }
}

struct TypingBubble: View {
    var body: some View {
        WindowVisibilityReader { isVisible in
            HStack(spacing: 5) {
                // The breathing dots LEAVE the tree while the window is not
                // being drawn — a running repeatForever is not reliably
                // superseded in place (measured: the render loop kept
                // ticking), but a removed view's animation dies with it, and
                // reinsertion restarts it through onAppear. The still dots
                // keep the bubble's exact geometry.
                if isVisible {
                    BreathingDotsView()
                        .accessibilityHidden(true)
                } else {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 7, height: 7)
                            .opacity(0.35)
                            .scaleEffect(0.72)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// The @-mention picker: a small floating list of the thread's tag-able
// members, filtered live by the token being typed. One row is always
// highlighted — the first until the arrows move it — so Return or Tab always
// has something to confirm.
