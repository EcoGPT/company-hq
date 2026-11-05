import SwiftUI

struct DesktopWorkspaceBar: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    var isRail = false
    /// The expanded grid's column count, worked out by the sidebar from its
    /// live width (`columnCount(availableWidth:itemWidth:)`). An adaptive grid
    /// inside a sidebar List row is measured against a stale proposal and
    /// collapses to one column, so the count comes from the pane itself. Only
    /// this integer crosses in, never the raw width: a drag re-runs the bar
    /// when a column appears, not on every pixel.
    var columnCount = 1
    /// What the grid's height rule needs (`SidebarGrid`): the list's visible
    /// height, and the live meeting cards and pins that share it. An unmeasured
    /// list (0) leaves the grid whole.
    var listHeight: CGFloat = 0
    var meetingCards = 0
    var pinCount = 0
    // The person's last More / Less. Mac only, and shared by every window.
    @AppStorage("sidebarGridChoice", store: PresentationDefaults.current)
    private var gridChoice = SidebarGrid.Choice.none.rawValue

    /// One destination of the grid, in the order it is drawn.
    private enum Cell: Hashable {
        case shortcut(HomePreferences.Shortcut)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.columnSpacing), count: columnCount)
    }

    static let columnSpacing: CGFloat = 4

    /// The expanded grid's column count. `DesktopPinnedChats` uses the same
    /// count and spacing, so each pin sits under a shortcut column.
    static func columnCount(availableWidth: CGFloat, itemWidth: CGFloat) -> Int {
        // Row insets (4 + 4) and the sidebar list's own row padding.
        let usable = availableWidth - 28
        return max(1, Int((usable + columnSpacing) / (itemWidth + columnSpacing)))
    }

    private var available: [HomePreferences.Shortcut] {
        HomePreferences.Shortcut.available
    }

    private var shortcuts: [HomePreferences.Shortcut] {
        preferences.shortcuts.filter(available.contains) + available.filter { !preferences.shortcuts.contains($0) }
    }

    private var allCells: [Cell] {
        shortcuts.map(Cell.shortcut)
    }

    /// How many destinations the grid draws: every available shortcut (a
    /// favorite only reorders them). The sidebar uses it to tell when a
    /// height change flips the grid's collapse rule.
    static var cellCount: Int {
        HomePreferences.Shortcut.available.count
    }

    private var isCollapsed: Bool {
        !isRail && SidebarGrid.isCollapsed(
            choice: SidebarGrid.Choice(rawValue: gridChoice) ?? .none, listHeight: listHeight,
            cells: allCells.count, columns: columnCount, pinCount: pinCount, meetingCards: meetingCards)
    }

    /// The shortcut the person is on, if any.
    private var selectedCell: Cell? {
        shortcuts.first { store.destination == $0.destination }.map(Cell.shortcut)
    }

    /// Collapsed: one full row, the selected destination swapped into its
    /// last slot if it sits behind the control. Expanded: every destination.
    private var cells: [Cell] {
        if isRail { return allCells }
        return SidebarGrid.visibleCells(allCells, columns: columnCount, collapsed: isCollapsed, selected: selectedCell)
    }

    /// More / Less exists whenever the grid has more than one row to show.
    private var hasControl: Bool { !isRail && allCells.count > columnCount }

    /// Immediate, like every sidebar change: no animation.
    private func setGrid(expanded: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            gridChoice = (expanded ? SidebarGrid.Choice.expanded : .collapsed).rawValue
        }
    }

    var body: some View {
        Group {
            if isRail {
                VStack(spacing: 10) { controls }
            } else {
                VStack(spacing: 8) {
                    LazyVGrid(columns: columns,
                              alignment: .leading, spacing: 12) {
                        controls
                    }
                    if hasControl { gridToggle(expanded: isCollapsed) }
                }
                .padding(.vertical, 8)
                .contextMenu {
                    Menu("Favorite Shortcuts") {
                        ForEach(available) { shortcut in
                            Toggle(shortcut.title, isOn: Binding(
                                get: { preferences.shortcuts.contains(shortcut) },
                                set: { enabled in
                                    preferences.setShortcuts(enabled ? preferences.shortcuts + [shortcut]
                                        : preferences.shortcuts.filter { $0 != shortcut })
                                }
                            ))
                            .disabled(!preferences.shortcuts.contains(shortcut)
                                      && preferences.shortcuts.count >= HomePreferences.maximumShortcuts)
                        }
                    }
                }
            }
        }
        .hqGlassContainer()
        // The grid changes height in one frame: nothing in it animates, whether
        // the person clicked More or the height rule moved it.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder private var controls: some View {
        ForEach(cells, id: \.self) { cell in
            switch cell {
            case .shortcut(let shortcut): shortcutButton(shortcut)
            }
        }
    }

    /// More / Less: a small centred glass capsule under the grid, in the
    /// shortcuts' glass and caption style. `expanded` is what a click does.
    private func gridToggle(expanded: Bool) -> some View {
        Button { setGrid(expanded: expanded) } label: {
            HStack(spacing: 4) {
                Text(expanded ? "More" : "Less")
                    .font(.caption)
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .hqGlass(in: Capsule(), tint: Color.secondary.opacity(0.22), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(expanded ? "Show all shortcuts" : "Show fewer shortcuts")
        .accessibilityLabel(expanded ? "More shortcuts" : "Fewer shortcuts")
        .accessibilityIdentifier(expanded ? "desktop-grid-more" : "desktop-grid-less")
    }

    private func shortcutButton(_ shortcut: HomePreferences.Shortcut) -> some View {
        // One count per shortcut per body: the Projects count walks the tasks.
        let count = count(for: shortcut)
        return Button {
            store.destination = shortcut.destination
        } label: {
            WorkspaceShortcutLabel(
                title: shortcut.title,
                symbol: shortcut.symbol,
                color: shortcut.color, count: count, isCompact: isRail,
                isSelected: store.destination == shortcut.destination
            )
        }
        .buttonStyle(.plain)
        .help(shortcut.title)
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(count > 0 ? "\(count)" : "")
        .accessibilityIdentifier("desktop-\(shortcut.rawValue)")
    }

    private func count(for shortcut: HomePreferences.Shortcut) -> Int {
        switch shortcut {
        case .calls: store.activeCall?.presentParticipants.count ?? store.liveMeetingHeadcount
        case .tasks: store.myOpenTaskCount
        default: 0
        }
    }
}

struct DesktopPinnedChats: View {
    @Environment(AppStore.self) private var store
    @Environment(HomePreferences.self) private var preferences
    let conversations: [Conversation]
    /// The column count `DesktopWorkspaceBar` gets, so the pins take its columns.
    let columns: Int
    @ScaledMetric(relativeTo: .caption) private var avatarScale = Tokens.Home.desktopPinDiameter
    @ScaledMetric(relativeTo: .caption) private var itemWidth = Tokens.Home.shortcutWidth

    // Capped where the shortcut circles cap, so pins never outgrow them.
    private var avatarSize: CGFloat { min(avatarScale, 56) }
    private var unreadDot: CGFloat { (avatarSize * 0.22).rounded() }

    var body: some View {
        // Eager rows keep avatar placement stable during sidebar resizing.
        // Each row splits the width the way the shortcut grid's flexible
        // columns do, and each pin is a shortcut-wide cell.
        VStack(spacing: 0) {
            ForEach(0..<((conversations.count + columns - 1) / columns), id: \.self) { row in
                HStack(alignment: .top, spacing: DesktopWorkspaceBar.columnSpacing) {
                    ForEach(Array(conversations.dropFirst(row * columns).prefix(columns))) { conversation in
                        Button { store.openConversation(conversation.id) } label: {
                            VStack(spacing: 5) {
                                ClusterAvatarView(conversation: conversation, size: avatarSize)
                                    .overlay(alignment: .topTrailing) {
                                        if conversation.unreadCount > 0 {
                                            Circle().fill(Tokens.Palette.accent).frame(width: unreadDot, height: unreadDot)
                                                .overlay(Circle().stroke(.background, lineWidth: 2))
                                        }
                                    }
                                Text(store.displayName(for: conversation))
                                    .font(.caption)
                                    .foregroundStyle(store.selectedConversationId == conversation.id ? .white : Color.primary)
                                    .lineLimit(2).multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 6)
                            .frame(width: itemWidth)
                            .background {
                                if store.selectedConversationId == conversation.id {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tokens.Palette.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(store.displayName(for: conversation))
                        .accessibilityLabel("Pinned \(store.displayName(for: conversation))")
                        .modifier(ConversationDropTarget(conversationId: conversation.id))
                        .contextMenu {
                            Button("Unpin Conversation", systemImage: "pin.slash") { preferences.unpin(conversation.id) }
                            Button("Move Earlier", systemImage: "arrow.left") { preferences.movePin(conversation.id, by: -1) }
                                .disabled(preferences.pinnedIDs.first == conversation.id)
                            Button("Move Later", systemImage: "arrow.right") { preferences.movePin(conversation.id, by: 1) }
                                .disabled(preferences.pinnedIDs.last == conversation.id)
                            Divider()
                            Button("Mark as Unread", systemImage: "envelope.badge") {
                                store.markUnread(conversationId: conversation.id)
                            }
                        }
                        // Placed as the grid places a shortcut: at its column's
                        // leading edge, overhanging a column narrower than the cell.
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(0..<max(0, columns - conversations.dropFirst(row * columns).prefix(columns).count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
            }
        }
    }
}
