import SwiftUI

// A reply's quoted original and its J-curve, and the dimmed ghosts of a
// message's superseded versions. Shared: both are Messages conventions
// (the outlined quote with its connector, "Edited" that
// unfolds its history), so they get one implementation and take their sizes
// from the tokens.

// A superseded version, dimmed the way Messages shows edit history above
// the current bubble.
struct EditRevisionBubble: View {
    let content: String
    let isOwn: Bool

    var body: some View {
        Text(content)
            .font(Tokens.Bubble.text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Tokens.Bubble.paddingHorizontal)
            .padding(.vertical, Tokens.Bubble.paddingVertical)
            .background(.quinary, in: RoundedRectangle(cornerRadius: Tokens.Bubble.radius, style: .continuous))
            .frame(maxWidth: Tokens.Bubble.maxWidth, alignment: isOwn ? .trailing : .leading)
            .padding(isOwn ? .leading : .trailing, Tokens.Bubble.farGutter)
    }
}

// The reply context, drawn the way Messages draws it: the original as a
// dimmed outlined bubble above the reply, joined to it by the little curve.
struct ReplyQuote: View {
    let reply: ReplyStub
    /// The roster a tag is matched against, so the quote reads the way the
    /// bubble it quotes does. Empty where tags do not apply (the mailbox).
    var names: [String] = []
    let isOwn: Bool
    /// Pressing the quote goes to the message it quotes — both transcripts
    /// wire this up, and each pages its own history back to the original.
    /// Nil where there is nowhere to go (the mailbox's quoted original is not
    /// a row in any transcript), and there the quote stays inert.
    var onOpenOriginal: (() -> Void)?

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 0) {
            if let onOpenOriginal {
                Button(action: onOpenOriginal) { quote }
                    .buttonStyle(.plain)
                    .help("Go to the original")
            } else {
                quote
            }
            ReplyConnector(isLeading: !isOwn)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 14, height: 10)
                .padding(isOwn ? .trailing : .leading, 4)
        }
        .padding(.top, 4)
        // The quote sits indented from the bubble's edge, so the curve reads
        // as reaching down toward the reply.
        .padding(isOwn ? .trailing : .leading, 24)
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    private var quote: some View {
        Text(MentionText.plain(reply.content, names: names))
            .font(Tokens.Bubble.quoteText)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.quaternary))
            .frame(maxWidth: Tokens.Bubble.quoteMaxWidth, alignment: isOwn ? .trailing : .leading)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

// The J-curve joining a quoted original to its reply, mirrored per side.
struct ReplyConnector: Shape {
    let isLeading: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isLeading {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY)
            )
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY)
            )
        }
        return path
    }
}
