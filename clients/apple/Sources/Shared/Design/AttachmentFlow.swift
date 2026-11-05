import SwiftUI

// Documents in one message sit side by side and WRAP, rather than running on
// in a single row. A row of cards is rigid — 200pt each — and a rigid row is
// a minimum width the transcript hands up to the split view, which is how a
// meeting drop with a few documents in it used to push the sidebar off the
// window (see `ColumnWidth`). Wrapping makes that minimum one card wide, and
// the third document visible instead of clipped.
struct AttachmentFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = min(proposal.width ?? Tokens.Bubble.maxWidth, Tokens.Bubble.maxWidth)
        var widest: CGFloat = 0
        var total: CGFloat = 0
        for row in Self.rows(of: sizes, within: width, spacing: spacing) {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for index in row {
                rowWidth += sizes[index].width
                rowHeight = max(rowHeight, sizes[index].height)
            }
            rowWidth += spacing * CGFloat(row.count - 1)
            widest = max(widest, rowWidth)
            total += rowHeight + spacing
        }
        return CGSize(width: widest, height: max(total - spacing, 0))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in Self.rows(of: sizes, within: bounds.width, spacing: spacing) {
            var x = bounds.minX
            var rowHeight: CGFloat = 0
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
                rowHeight = max(rowHeight, sizes[index].height)
            }
            y += rowHeight + spacing
        }
    }

    /// Cards fill a row greedily; the one that would overrun starts the next.
    /// A card too wide for a whole row still gets a row to itself.
    private static func rows(
        of sizes: [CGSize], within width: CGFloat, spacing: CGFloat
    ) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let needed = current.isEmpty ? size.width : used + spacing + size.width
            if needed > width, !current.isEmpty {
                rows.append(current)
                current = [index]
                used = size.width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}
