import SwiftUI
import WidgetKit

// MARK: - Board

/// HQ's own board (Projects → My tasks), as the app draws it: lists on a
/// flat fill, solid cards on them. The same tokens as `ProjectsBoard.swift`.
struct BoardView: View {
    let entry: SummaryEntry

    private static let lists: [(status: String, title: String)] = [
        ("open", "To do"), ("in_progress", "In progress"), ("blocked", "Blocked"),
    ]

    var body: some View {
        SummaryContent(entry: entry) { summary in
            HStack(alignment: .top, spacing: Board.listGap) {
                ForEach(Self.lists, id: \.status) { list in
                    let cards = summary.work.tasks.filter { $0.status == list.status }
                    BoardList(title: list.title, count: count(list.status, summary.work)) {
                        ForEach(cards) { TaskBoardCard(task: $0, me: summary.me) }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .widgetURL(WidgetLink.mine.url)
    }

    private func count(_ status: String, _ work: WidgetSummary.Work) -> Int {
        switch status {
        case "open": work.open
        case "in_progress": work.inProgress
        default: work.blocked
        }
    }
}

/// `Tokens.Projects`, restated for the extension.
enum Board {
    static let listGap: CGFloat = 10
    static let listRadius: CGFloat = 14
    static let listPadding: CGFloat = 8
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let cardPaddingH: CGFloat = 12
    static let cardPaddingV: CGFloat = 10
    static let cardFace: CGFloat = 22
    static let listTitle = Font.system(size: 13, weight: .semibold)
    static let listCount = Font.system(size: 12, weight: .medium)
    static let cardTitle = Font.system(size: 13)
    static let cardMeta = Font.system(size: 11.5)
    static let cardRef = Font.system(size: 11, design: .monospaced)
    static let cardLabel = Font.system(size: 10.5, weight: .semibold)
}

struct BoardList<Cards: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var cards: Cards

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(Board.listTitle)
                Text(count, format: .number).font(Board.listCount).monospacedDigit()
                    .foregroundStyle(Palette.inkTertiary)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .frame(minHeight: 24)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)
            FittingStack(spacing: Board.cardGap) { cards }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .padding(Board.listPadding)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(Palette.listFill, in: RoundedRectangle(cornerRadius: Board.listRadius, style: .continuous))
    }
}

/// A column of cards that shows only the cards that fit whole: a widget
/// cannot scroll, and a card cut in half reads as broken. The rest are
/// placed out of sight (the list clips), and its header still counts them.
struct FittingStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let limit = proposal.height ?? .infinity
        var height: CGFloat = 0
        for subview in subviews {
            let next = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let needed = height == 0 ? next : height + spacing + next
            if needed > limit { break }
            height = needed
        }
        return CGSize(width: width, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var isFull = false
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if !isFull, y + size.height <= bounds.maxY + 0.5 {
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
                y += size.height + spacing
            } else {
                isFull = true
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 10_000), proposal: .zero)
            }
        }
    }
}

/// A card's frame: solid on its list, no hairline, the lift of one pixel.
private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Board.cardRadius, style: .continuous)
        content
            .padding(.horizontal, Board.cardPaddingH)
            .padding(.top, Board.cardPaddingV)
            .padding(.bottom, Board.cardPaddingV - 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardFill, in: shape)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }
}

private struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Board.cardTitle)
            .lineSpacing(2)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CardRef: View {
    let ref: String?
    var body: some View {
        if let ref {
            Text(ref).font(Board.cardRef).foregroundStyle(Palette.inkTertiary).lineLimit(1).fixedSize()
        }
    }
}

/// The board a task came from: its name in a quiet tint.
private struct BoardLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(Board.cardLabel)
            .foregroundStyle(Palette.inkTertiary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.inkTertiary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A task's card: its title, its board, and a foot of its ref, comments and
/// the owner's face — the app's `TaskCard`.
struct TaskBoardCard: View {
    let task: WidgetSummary.WorkTask
    let me: WidgetSummary.Me

    var body: some View {
        Link(destination: WidgetLink.task(task.id).url) {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(text: task.title)
                if let project = task.projectName {
                    BoardLabel(name: project)
                }
                HStack(spacing: 8) {
                    CardRef(ref: task.ref)
                    if task.commentCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left").font(.system(size: 10, weight: .medium))
                            Text(task.commentCount, format: .number).monospacedDigit()
                        }
                        .font(Board.cardMeta)
                        .foregroundStyle(Palette.inkTertiary)
                    }
                    Spacer(minLength: 0)
                    Face(name: me.name, personId: me.id, avatarId: me.avatarId, size: Board.cardFace)
                }
                .frame(minHeight: 22)
            }
            .modifier(CardChrome())
        }
        .foregroundStyle(.primary)
    }
}
