import Foundation

// AppKit pane widths, not SwiftUI's inset content width.
enum SidebarMetrics {
    static let rail: CGFloat = 90
    static let railBelow: CGFloat = 190
    static let listDefault: CGFloat = 280
    static let listMax: CGFloat = 380

    static func listWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return listDefault }
        return min(max(width, railBelow), listMax)
    }

    enum Settlement: Equatable {
        case wait
        case ignore
        case rail
        case list(CGFloat)
    }

    static func settlement(
        width: CGFloat, availableWidth: CGFloat, hasDetails: Bool,
        isDragging: Bool, isMovingDivider: Bool
    ) -> Settlement {
        guard !isDragging, !isMovingDivider else { return .wait }
        guard width.isFinite, width >= rail - 8, availableWidth.isFinite,
              availableWidth > 0 else { return .ignore }
        if width < railBelow || (hasDetails && availableWidth - width - 321 < 360) {
            return .rail
        }
        return .list(listWidth(width))
    }
}

// Delayed layout callbacks belong to one mounted chat shell. A new mount is
// a different session even when it reuses the same RootView state storage.
struct SidebarLayoutSession {
    private(set) var generation: UInt = 0
    private(set) var isActive = false

    mutating func begin() {
        generation &+= 1
        isActive = true
    }

    mutating func end() {
        generation &+= 1
        isActive = false
    }

    func accepts(_ generation: UInt) -> Bool {
        isActive && self.generation == generation
    }
}

// The shortcut grid's height rule. The grid always drawing all 11-12
// destinations in 76pt cells took about 360pt of the list, so a default
// window left room for one conversation. When the full grid would leave
// fewer than `minimumConversationRows` rows of conversations at the list's
// current height the grid shows only its first row, with a More capsule
// under it. A click on More or Less is the person's choice and wins over the
// rule from then on. Heights are measured estimates (a 44pt circle, its
// caption and the 12pt row gap), not layout: Foundation only, so the rule
// runs headless.
enum SidebarGrid {
    static let minimumConversationRows = 6
    /// One grid row: 44pt circle, 5pt gap, a one-line caption, 12pt row gap.
    static let rowHeight: CGFloat = 75
    /// The grid's own vertical padding (8 + 8) and the list row's insets (4 + 12).
    static let chromeHeight: CGFloat = 32
    /// One pinned row: 6pt padding either side, a 44pt avatar, 5pt gap and one or
    /// two caption lines, plus the 12pt list inset.
    static let pinRowHeight: CGFloat = 92
    /// A live meeting card (56pt minimum) and its 8pt gap.
    static let meetingCardHeight: CGFloat = 64
    /// A conversation row: 44pt avatar, 6pt padding either side, and the list's own spacing.
    static let conversationRowHeight: CGFloat = 66

    /// What the person last chose with More or Less. `none` leaves the rule in charge.
    enum Choice: Int {
        case none = 0
        case expanded = 1
        case collapsed = 2
    }

    static func rows(cells: Int, columns: Int) -> Int {
        guard cells > 0 else { return 0 }
        return (cells + max(1, columns) - 1) / max(1, columns)
    }

    /// The More / Less capsule under the grid: 24pt tall and an 8pt gap above it.
    /// It exists whenever the grid has more cells than one row.
    static let controlHeight: CGFloat = 32

    /// The grid's height: every row, or the first row alone when collapsed,
    /// and the control either way.
    static func fullGridHeight(cells: Int, columns: Int, collapsed: Bool = false) -> CGFloat {
        let shown = collapsed ? min(cells, columns) : cells
        let control = cells > columns ? controlHeight : 0
        return CGFloat(rows(cells: shown, columns: columns)) * rowHeight + chromeHeight + control
    }

    /// The destinations drawn: all of them, or one full row. A destination
    /// the person is on that sits behind the control takes the row's last
    /// slot, so the grid never loses its highlight.
    static func visibleCells<T: Equatable>(_ all: [T], columns: Int, collapsed: Bool, selected: T?) -> [T] {
        guard collapsed else { return all }
        var row = Array(all.prefix(max(1, columns)))
        if let selected, !row.contains(selected), all.contains(selected) { row[row.count - 1] = selected }
        return row
    }

    /// Conversation rows that would be visible below the grid (whole unless
    /// `collapsed`), the pins and the live meeting cards.
    static func conversationRows(
        listHeight: CGFloat, cells: Int, columns: Int, pinCount: Int, meetingCards: Int,
        collapsed: Bool = false
    ) -> Int {
        let pins = CGFloat(rows(cells: pinCount, columns: columns)) * pinRowHeight
        let used = fullGridHeight(cells: cells, columns: columns, collapsed: collapsed) + pins
            + CGFloat(meetingCards) * meetingCardHeight
        return max(0, Int(((listHeight - used) / conversationRowHeight).rounded(.down)))
    }

    /// Whether the grid shows only its first row. An unmeasured list
    /// (height 0) and a grid already one row long are never collapsed.
    static func isCollapsed(
        choice: Choice, listHeight: CGFloat, cells: Int, columns: Int, pinCount: Int, meetingCards: Int
    ) -> Bool {
        guard cells > columns else { return false }
        switch choice {
        case .expanded: return false
        case .collapsed: return true
        case .none:
            guard listHeight.isFinite, listHeight > 0 else { return false }
            return conversationRows(listHeight: listHeight, cells: cells, columns: columns,
                pinCount: pinCount, meetingCards: meetingCards) < minimumConversationRows
        }
    }
}
