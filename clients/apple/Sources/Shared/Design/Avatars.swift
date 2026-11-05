import SwiftUI

// The roster's faces, shared by both clients so a thread looks the same on a
// Mac and on a phone. Pure SwiftUI on purpose — this is design-system code,
// not view-layer code, which is why it sits beside the tokens rather than in
// either app's own Views tree.

// DMs show one avatar; groups show the Messages treatment: one circle the
// size a single avatar would be, with the member bubbles nested inside its
// bounds — never a loose cluster spilling past the slot. Each member wears
// their own mark — initials or the bot mark — and DMs carry the online dot.
struct ClusterAvatarView: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation
    var size: CGFloat = 40

    /// Bubble diameters and center offsets as fractions of the circle, per
    /// member count (2, 3, 4+), eyeballed from Messages; every bubble's
    /// extent stays inside the backing circle.
    private static let layouts: [[(d: CGFloat, x: CGFloat, y: CGFloat)]] = [
        [(0.60, -0.10, -0.11), (0.36, 0.21, 0.21)],
        [(0.52, -0.14, 0.00), (0.34, 0.20, -0.21), (0.34, 0.20, 0.21)],
        [(0.50, -0.13, -0.06), (0.30, 0.21, -0.26), (0.32, 0.26, 0.09), (0.30, -0.01, 0.30)],
    ]

    var body: some View {
        let members = store.displayMembers(of: conversation)
        if let image = AvatarImageCache.shared.image(
            kind: .conversations, ownerId: conversation.id,
            avatarId: conversation.avatarId, client: store.client, size: size
        ) {
            Image(platform: image)
        } else if store.isUpdatesRoom(conversation) {
            // The team feed wears its own mark — a member cluster would just
            // be the whole company.
            ZStack {
                Circle().fill(Color.indigo.gradient)
                Image(systemName: "megaphone.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        } else if conversation.kind == "group" && members.count >= 2 {
            let layout = Self.layouts[min(members.count, 4) - 2]
            ZStack {
                Circle().fill(.quinary)
                ForEach(layout.indices, id: \.self) { index in
                    memberAvatar(members[index], size: layout[index].d * size)
                        .offset(x: layout[index].x * size, y: layout[index].y * size)
                }
            }
            .frame(width: size, height: size)
        } else {
            ZStack(alignment: .bottomTrailing) {
                if let person = members.first {
                    memberAvatar(person, size: size)
                } else {
                    AvatarView(name: store.displayName(for: conversation), size: size)
                }
                if store.isOnline(conversation) {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }
        }
    }

    @ViewBuilder
    private func memberAvatar(_ person: Person, size: CGFloat) -> some View {
        if person.kind == "bot" {
            BotAvatarView(name: person.name, size: size)
        } else {
            AvatarView(name: person.name, size: size, person: person)
        }
    }
}

// Bots get their own mark so the roster never reads as if a person answered.
struct BotAvatarView: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Color.indigo.gradient)
            Image(systemName: "cpu")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name)
    }
}

struct AvatarView: View {
    @Environment(AppStore.self) private var store
    let name: String
    var isGroup = false
    var size: CGFloat = 40
    /// The person whose picture to show. Most call sites only hold a display
    /// name (message senders, typing, task owners are denormalized on the
    /// wire), so a nil person is resolved through the store by name.
    var person: Person?

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    var body: some View {
        let resolved = person ?? (isGroup ? nil : store.person(named: name))
        if let resolved,
           let image = AvatarImageCache.shared.image(
               kind: .people, ownerId: resolved.id,
               avatarId: resolved.avatarId, client: store.client, size: size
           ) {
            // Pre-sized and pre-masked: menu labels draw the image at its
            // native size and ignore resize/clip modifiers.
            Image(platform: image)
        } else {
            fallback
        }
    }

    private var fallback: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.65), Color(white: 0.5)],
                    startPoint: .top, endPoint: .bottom
                ))
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white)
            } else {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}
