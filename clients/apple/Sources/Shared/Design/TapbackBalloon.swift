import SwiftUI

// Tapback balloons the way Messages draws them: one balloon per emoji, blue
// when you are among its senders, with the little thought-bubble dots
// trailing toward the reactor's side. Shared, because the shape of a tapback
// is a shared rule and not a per-platform detail — only the
// glyph sizes differ, and those come from the tokens.

struct TapbackBalloon: View {
    let reaction: Reaction
    let isMine: Bool
    /// The dots trail toward the reactor's side — the side the balloon hangs
    /// off the bubble, not the bubble itself.
    let isTailLeading: Bool

    // The HA HA tapback is genuinely text, in Messages too.
    private var isTextGlyph: Bool { reaction.emoji.count > 2 }

    var body: some View {
        HStack(spacing: 3) {
            Text(reaction.emoji)
                .font(isTextGlyph ? Tokens.Tapback.textGlyph : Tokens.Tapback.emoji)
                .foregroundStyle(isMine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            if reaction.personIds.count > 1 {
                Text("\(reaction.personIds.count)")
                    .font(Tokens.Tapback.count)
                    .foregroundStyle(isMine ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background { surface(Capsule()) }
        .overlay(alignment: isTailLeading ? .bottomLeading : .bottomTrailing) {
            surface(Circle())
                .frame(width: 6, height: 6)
                .offset(x: isTailLeading ? -1 : 1, y: 4)
        }
        .overlay(alignment: isTailLeading ? .bottomLeading : .bottomTrailing) {
            surface(Circle())
                .frame(width: 3, height: 3)
                .offset(x: isTailLeading ? -5 : 5, y: 8)
        }
    }

    // Own tapbacks are blue like own bubbles; everyone else's are an opaque
    // gray that holds up over a blue bubble corner.
    @ViewBuilder
    private func surface(_ shape: some Shape) -> some View {
        if isMine {
            shape.fill(Color.blue.gradient)
        } else {
            ZStack {
                shape.fill(.background)
                shape.fill(.quinary)
                shape.stroke(.quaternary, lineWidth: 1)
            }
        }
    }
}
