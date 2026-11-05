import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// The marks, stamps and verbs every list of work shares on both clients —
// a task's checkbox, an alert's dot, how old something is, and the one menu
// of task verbs. The Projects boards draw their cards from these.

// MARK: - Marks

/// What sits in the mark column. A task is its checkbox, an alert one still
/// dot in its severity's colour, a project a ring of how much of it is done,
/// and anything else a small symbol. Nothing here ever animates.
enum ListMark: Hashable {
    /// "open", "in_progress", "blocked" or "done".
    case task(status: String)
    /// Red critical, orange warning, green once resolved — a static dot. The
    /// tier is words in the row's subtitle, not a chip in the mark.
    case alert(severity: String, isActive: Bool)
    case project(done: Int, total: Int)
    /// A navigation row's glyph (My tasks).
    case symbol(name: String, tint: Color)
}

/// The mark column's geometry, one per platform, so every row's title starts
/// at the same x.
enum ListGeometry {
    #if os(macOS)
        static let markWidth: CGFloat = 16
        static let box: CGFloat = 14
        static let dot: CGFloat = 9
        static let ring: CGFloat = 14
        static let rowPaddingVertical: CGFloat = 7
        static let quietFont = Tokens.Typography.meta
        static let headerFont = Tokens.Typography.cardTitle
    #else
        static let markWidth: CGFloat = 20
        static let box: CGFloat = 20
        static let dot: CGFloat = 11
        static let ring: CGFloat = 18
        static let rowPaddingVertical: CGFloat = 10
        /// Footnote, not subheadline: beside a Claim capsule a phone row has
        /// about 200 pt for its words, and "Needs a reply · 22 min" has to fit
        /// on the one line without an ellipsis.
        static let quietFont = Font.footnote
        static let headerFont = Tokens.Typography.meta
    #endif
    /// Where a divider between two rows starts: under the title, not the mark.
    static let dividerInset: CGFloat = Tokens.Space.x4 + markWidth + Tokens.Space.x3
}

struct ListMarkView: View {
    let mark: ListMark
    /// A task's box; the card dialog draws it larger than a list does.
    var box: CGFloat = ListGeometry.box

    var body: some View {
        Group {
            switch mark {
            case .task(let status):
                taskBox(status)
            case .alert(let severity, let isActive):
                Circle()
                    .fill(Self.alertTint(severity: severity, isActive: isActive))
                    .frame(width: ListGeometry.dot, height: ListGeometry.dot)
            case .project(let done, let total):
                ZStack {
                    Circle().strokeBorder(Tokens.Palette.border, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: total > 0 ? CGFloat(done) / CGFloat(total) : 0)
                        .stroke(Tokens.Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1)
                }
                .frame(width: ListGeometry.ring, height: ListGeometry.ring)
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.system(size: ListGeometry.box * 0.9, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(minWidth: ListGeometry.markWidth)
        .accessibilityLabel(Self.label(for: mark))
    }

    static func alertTint(severity: String, isActive: Bool) -> Color {
        if !isActive { return Tokens.Palette.live }
        return severity == "critical" ? Tokens.Palette.danger : Tokens.Palette.warning
    }

    static func label(for mark: ListMark) -> String {
        switch mark {
        case .task(let status):
            switch status {
            case "done": return "Done"
            case "in_progress": return "In progress"
            case "blocked": return "Blocked"
            default: return "Open"
            }
        case .alert(let severity, let isActive):
            return isActive ? (severity == "critical" ? "Critical" : "Warning") : "Resolved"
        case .project(let done, let total):
            return "\(done) of \(total) done"
        case .symbol:
            return ""
        }
    }

    /// The checkbox: empty when open, half-filled with the accent while
    /// somebody is on it, a red bar while blocked, solid ink with a tick
    /// when done.
    @ViewBuilder
    private func taskBox(_ status: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: box * 0.25, style: .continuous)
        ZStack {
            if status == "done" {
                shape.fill(Tokens.Palette.ink)
                Image(systemName: "checkmark")
                    .font(.system(size: box * 0.6, weight: .bold))
                    .foregroundStyle(Tokens.Palette.actionInk)
            } else if status == "in_progress" {
                shape.strokeBorder(Tokens.Palette.accent, lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Tokens.Palette.accent)
                    .frame(width: (box - 5) / 2, height: box - 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2.5)
            } else if status == "blocked" {
                shape.strokeBorder(Tokens.Palette.danger, lineWidth: 1.5)
                Capsule().fill(Tokens.Palette.danger).frame(width: box * 0.4, height: 1.7)
            } else {
                shape.strokeBorder(Tokens.Palette.inkTertiary, lineWidth: 1.5)
            }
        }
        .frame(width: box, height: box)
    }
}

// MARK: - Sections

/// A section's name with its count beside it — the Status page's header.
struct ListSectionHeader: View {
    let title: String
    var count: Int?
    var tint: Color = Tokens.Palette.inkTertiary
    /// The header opens something — a project page — and says so.
    var hasChevron = false

    init(
        _ title: String, count: Int? = nil, tint: Color = Tokens.Palette.inkTertiary,
        hasChevron: Bool = false
    ) {
        self.title = title
        self.count = count
        self.tint = tint
        self.hasChevron = hasChevron
    }

    var body: some View {
        HStack(spacing: Tokens.Space.x2) {
            Text(title)
                .font(ListGeometry.headerFont)
                .foregroundStyle(headerInk)
                .lineLimit(1)
            if let count, count > 0 {
                Text(count, format: .number)
                    .font(Tokens.Typography.captionEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, Tokens.Chip.paddingHorizontal)
                    .padding(.vertical, Tokens.Chip.paddingVertical)
                    .background(tint.opacity(Tokens.Chip.tintOpacity), in: Capsule())
            }
            if hasChevron {
                Image(systemName: "chevron.right")
                    .font(Tokens.Typography.captionEmphasis)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerInk: Color {
        #if os(macOS)
            Tokens.Palette.ink
        #else
            Tokens.Palette.inkSecondary
        #endif
    }
}

// MARK: - Stamps

/// How old something is, in words. One helper, so no two lists
/// round an age differently.
enum ListStamp {
    /// How long something has been running, with the unit in words — "22
    /// min", "2 h", "3 d". Read under pressure, so it says more than a letter.
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    /// "Sep 18" — the shortest thing that still says which day.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "2:10 PM" — the time a thing finished today.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Task verbs

/// Every verb a task row has that is not the checkbox, in one menu: the long
/// press on the phone, the right click on the Mac. The page supplies the
/// writes, so the planning workspace keeps its own save path and error line.
struct TaskVerbsMenu: ViewModifier {
    @Environment(AppStore.self) private var store
    let task: TeamTask
    let onStatus: (String) -> Void
    let onAssign: (String) -> Void
    let onDelete: () -> Void
    /// A list that keeps its own order (a board's working lists) passes
    /// these; nil at an end, and both nil where order is not the user's.
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    /// A board's lists, for "Move To ▸" — the drag's equivalent. Given
    /// them, the menu moves the card instead of toggling its status.
    var moveTargets: [String] = []
    var onMoveTo: ((String) -> Void)?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let onMoveTo, !moveTargets.isEmpty {
                Menu("Move To") {
                    ForEach(moveTargets, id: \.self) { list in
                        Button(ProjectsModel.statusTitle(list)) { onMoveTo(list) }
                    }
                }
            } else {
                statusButtons
            }
            if onMoveUp != nil || onMoveDown != nil {
                Divider()
                Button("Move Up") { onMoveUp?() }.disabled(onMoveUp == nil)
                Button("Move Down") { onMoveDown?() }.disabled(onMoveDown == nil)
            }
            Divider()
            menuTail
        }
    }

    @ViewBuilder private var statusButtons: some View {
        Button(task.isOpen ? "Mark Done" : "Reopen") { onStatus(task.isOpen ? "done" : "open") }
        if task.isOpen {
            Button(task.status == "in_progress" ? "Clear In Progress" : "Mark In Progress") {
                onStatus(task.status == "in_progress" ? "open" : "in_progress")
            }
            Button(task.status == "blocked" ? "Clear Blocked" : "Mark Blocked") {
                onStatus(task.status == "blocked" ? "open" : "blocked")
            }
        }
    }

    @ViewBuilder private var menuTail: some View {
        Menu("Assign To") {
            ForEach(store.roster) { person in
                Button(person.id == store.me?.id ? "\(person.name) (you)" : person.name) {
                    onAssign(person.id)
                }
            }
        }
        if let origin = task.originConversationId {
            Button("Open Thread") { store.openConversation(origin) }
        }
        Button("Copy Title") { Self.copy(task.title) }
        if task.ownerPersonId == store.me?.id || store.me?.isAdmin == true {
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private static func copy(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    func taskVerbs(
        _ task: TeamTask, onStatus: @escaping (String) -> Void,
        onAssign: @escaping (String) -> Void, onDelete: @escaping () -> Void,
        onMoveUp: (() -> Void)? = nil, onMoveDown: (() -> Void)? = nil,
        moveTargets: [String] = [], onMoveTo: ((String) -> Void)? = nil
    ) -> some View {
        modifier(
            TaskVerbsMenu(
                task: task, onStatus: onStatus, onAssign: onAssign, onDelete: onDelete, onMoveUp: onMoveUp,
                onMoveDown: onMoveDown, moveTargets: moveTargets, onMoveTo: onMoveTo))
    }
}

// MARK: - Chips

/// The one chip a row is allowed: 11pt, its own tint behind it, at the one
/// chip geometry both clients share (`Tokens.Chip`). Shared since the
/// Projects board (a PR's state) draws it on the phone too.
struct BoardChip: View {
    let text: String
    var tint: Color = Tokens.Palette.inkSecondary

    var body: some View {
        Text(text)
            .font(Tokens.Typography.captionEmphasis)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Chip.paddingHorizontal)
            .padding(.vertical, Tokens.Chip.paddingVertical)
            .background(tint.opacity(Tokens.Chip.tintOpacity), in: Capsule())
    }
}
