import OSLog
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

// Dragging a card, the way Trello does it: the lifted card follows the
// pointer, its own place closes, a gap the card's height opens where it
// will land, and that list lights up. On the Mac the drag is the board's
// own (a press-and-move the card answers, drawn over the lists) — the
// system's drag session ended unreliably once its source card had moved
// lists, so a card that landed could not be picked up again. The iPhone
// keeps the system drag its long press starts. Either way the board works
// out the list and slot from the pointer and the frames every list and
// card reports: row-level destinations inside scroll views never received
// drag events (the old planning board learned that). The drag is the one
// thing on a board that moves.

private let boardDragLog = Logger(subsystem: HQIdentity.logSubsystem, category: "projects-drag")

/// The card in the air: what it is, which list it left, and its height,
/// which the gap borrows.
struct BoardDragItem: Equatable {
    let kind: BoardDragKind
    let id: String
    let list: String
    /// Its slot in the list it left, where it goes back when let go
    /// outside every list.
    var index = 0
    let size: CGSize

    var height: CGFloat { size.height }
}

/// Where the dragged card would land: a list, and its slot among the
/// list's other cards.
struct BoardDropSpot: Equatable {
    let list: String
    let index: Int
}

/// A list as the board measured it, and whether this drag may land in it.
struct BoardListFrame {
    let id: String
    let frame: CGRect
    let isAccepting: Bool
}

/// A card as the board measured it, in its list.
struct BoardCardFrame {
    let id: String
    let list: String
    let frame: CGRect
}

/// The pure part of a drop: which list the pointer is over and how many of
/// that list's other cards sit above it.
enum BoardDropMath {
    /// A pointer in the gutter between two lists belongs to the nearer one.
    static func spot(
        at point: CGPoint, lists: [BoardListFrame], cards: [BoardCardFrame], dragging: String, gutter: CGFloat
    ) -> BoardDropSpot? {
        let hits = lists.filter { list in
            point.x >= list.frame.minX - gutter / 2 && point.x <= list.frame.maxX + gutter / 2
        }
        guard
            let list = hits.min(by: { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }),
            list.isAccepting
        else { return nil }
        let above = cards.filter { card in
            card.list == list.id && card.id != dragging && card.frame.height > 0.5 && card.frame.midY < point.y
        }
        return BoardDropSpot(list: list.id, index: above.count)
    }

    /// The board scrolls sideways while the pointer rests this close to
    /// either edge of its viewport.
    static let edgeBand: CGFloat = 44

    static func edge(at point: CGPoint, width: CGFloat) -> HorizontalEdge? {
        guard width > edgeBand * 3 else { return nil }
        if point.x < edgeBand { return .leading }
        if point.x > width - edgeBand { return .trailing }
        return nil
    }
}

/// One board's drag: the card in the air, where it would land, and the
/// frames that answer "where". Frames change on every scroll, so they are
/// kept out of observation — only the lift, the spot and the edge redraw.
@MainActor @Observable
final class BoardDrag {
    nonisolated static let space = "projects-board"

    var item: BoardDragItem?
    var spot: BoardDropSpot?
    /// The viewport edge the pointer rests at, which scrolls the lists.
    var edge: HorizontalEdge?

    @ObservationIgnored var cardFrames: [String: BoardCardFrame] = [:]
    @ObservationIgnored var listFrames: [String: CGRect] = [:]
    @ObservationIgnored var accepting: [String: BoardDragKind] = [:]
    @ObservationIgnored var viewportWidth: CGFloat = 0
    @ObservationIgnored var pointer: CGPoint?
    @ObservationIgnored var scroll: ScrollGeometry?
    /// Where a drop goes; the board restates it on every draw.
    @ObservationIgnored var perform: ((BoardDragItem, BoardDropSpot) -> Void)?

    /// The Mac's lifted card: the pointer it follows, where on the card it
    /// was grabbed, and the card itself.
    var floating: CGPoint?
    @ObservationIgnored var grab: CGSize = .zero
    @ObservationIgnored var preview: AnyView?

    /// Edge scrolling waits until the pointer has been clear of both
    /// edges once, so grabbing a card near the board's edge scrolls nothing.
    @ObservationIgnored private var isEdgeArmed = false

    /// The card that just landed, and when: UIKit asks the source for its
    /// item again as the drop's data transfers, after the drop has ended,
    /// and that late ask must not lift the card a second time. The Mac's
    /// own drag starts only on a press, so a card picked straight back up
    /// lifts.
    @ObservationIgnored private var landed: (id: String, at: Date)?

    func begin(_ item: BoardDragItem) {
        #if os(iOS)
            if let landed, landed.id == item.id, Date().timeIntervalSince(landed.at) < 1.5 { return }
        #endif
        boardDragLog.notice("Lifted a \(item.list, privacy: .public) card")
        self.item = item
        spot = nil
        edge = nil
        pointer = nil
        isEdgeArmed = false
    }

    func end() {
        if let item { landed = (item.id, Date()) }
        item = nil
        spot = nil
        edge = nil
        pointer = nil
        floating = nil
        preview = nil
    }

    /// The Mac's drag, moved: the card follows and the spot re-reads. The
    /// gap is always somewhere, the way Trello's is: it starts in the card's
    /// own place and, over no list, stays where it last was — so lists never
    /// jump as the pointer crosses empty board.
    func move(to point: CGPoint) {
        floating = point
        track(point)
    }

    /// Re-reads the spot after the lists scroll beneath a pointer at rest.
    func retrack() { track(pointer) }

    /// The Mac's drag, let go: lands where the gap is, or nowhere.
    func drop(at point: CGPoint) {
        track(point)
        defer { end() }
        guard let item, let spot, let perform else { return }
        boardDragLog.notice("Dropped at \(spot.list, privacy: .public) \(spot.index)")
        perform(item, spot)
    }

    /// Re-reads the spot under the pointer: on each move, and after the
    /// lists scroll beneath a pointer at rest.
    func track(_ point: CGPoint?) {
        pointer = point
        guard let item, let point else {
            if spot != nil { spot = nil }
            if edge != nil { edge = nil }
            return
        }
        let lists = listFrames.map { id, frame in
            BoardListFrame(id: id, frame: frame, isAccepting: accepting[id] == item.kind)
        }
        // Past the viewport is the panel: no list there takes a drop.
        var next =
            viewportWidth > 0 && point.x > viewportWidth
            ? nil
            : BoardDropMath.spot(
                at: point, lists: lists, cards: Array(cardFrames.values), dragging: item.id,
                gutter: Tokens.Projects.listGap)
        if next == nil, floating != nil {
            next = spot ?? BoardDropSpot(list: item.list, index: item.index)
        }
        if next != spot { spot = next }
        var nextEdge = BoardDropMath.edge(at: point, width: viewportWidth)
        if !isEdgeArmed {
            if nextEdge == nil { isEdgeArmed = true }
            nextEdge = nil
        }
        if nextEdge != edge { edge = nextEdge }
    }
}

#if os(iOS)
/// The iPhone board's one drop destination.
@MainActor
struct BoardDropDelegate: DropDelegate {
    let drag: BoardDrag
    let perform: (BoardDragItem, BoardDropSpot) -> Void

    // swiftlint:disable:next boolean_function_naming
    func validateDrop(info: DropInfo) -> Bool { drag.item != nil }

    func dropEntered(info: DropInfo) {
        boardDragLog.debug("Drag entered the board")
        drag.track(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drag.track(info.location)
        return DropProposal(operation: drag.spot == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { drag.track(nil) }

    // swiftlint:disable:next boolean_function_naming
    func performDrop(info: DropInfo) -> Bool {
        drag.track(info.location)
        boardDragLog.notice("Dropped at \(drag.spot?.list ?? "nowhere", privacy: .public) \(drag.spot?.index ?? -1)")
        defer { drag.end() }
        guard let item = drag.item, let spot = drag.spot else { return false }
        perform(item, spot)
        return true
    }
}

#endif

// MARK: - Cards

/// A list's cards, with the drag drawn into them: the lifted card's place
/// closes, and a gap its height opens at the slot under the pointer. Cards
/// are spaced by their own foot padding, so a closed card leaves no seam.
struct BoardCardStack<Item: Identifiable, Card: View>: View where Item.ID == String {
    let list: String
    let items: [Item]
    /// What these cards drag as; nil where nothing drags.
    var kind: BoardDragKind?
    @ViewBuilder var card: (Item) -> Card
    @Environment(BoardDrag.self) private var drag: BoardDrag?

    private enum Row: Identifiable {
        /// The card, its place in `items`, and whether it is the lifted one.
        case card(Item, index: Int, isLifted: Bool)
        case gap(CGFloat)

        var id: String {
            switch self {
            case .card(let item, _, _): item.id
            case .gap: "board-drop-gap"
            }
        }
    }

    private var rows: [Row] {
        let spot = drag?.spot
        let lifted = spot == nil ? nil : drag?.item?.id
        let gap = spot.flatMap { $0.list == list ? $0.index : nil }
        let height = drag?.item?.height ?? 0
        var rows: [Row] = []
        var slot = 0
        for (index, item) in items.enumerated() {
            let isLifted = item.id == lifted
            if !isLifted {
                if slot == gap { rows.append(.gap(height)) }
                slot += 1
            }
            rows.append(.card(item, index: index, isLifted: isLifted))
        }
        if let gap, gap >= slot { rows.append(.gap(height)) }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case .card(let item, let index, let isLifted):
                    // The lifted card stays in the tree — it is the drag's
                    // source — but its place in the list closes.
                    card(item)
                        .modifier(
                            BoardCardDrag(
                                drag: drag, kind: kind, id: item.id, list: list,
                                index: index,
                                preview: { AnyView(card(item)) }))
                        .frame(height: isLifted ? 0 : nil, alignment: .top)
                        .opacity(isLifted ? 0 : 1)
                        .allowsHitTesting(!isLifted)
                        .padding(.bottom, isLifted ? 0 : Tokens.Projects.cardGap)
                        .accessibilityHidden(isLifted)
                case .gap(let height):
                    RoundedRectangle(cornerRadius: Tokens.Projects.cardRadius, style: .continuous)
                        .fill(Tokens.Projects.dropGap)
                        .frame(height: max(height, 36))
                        .padding(.bottom, Tokens.Projects.cardGap)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// Lifts a card: reports its frame to the board and starts the drag — the
/// board's own on the Mac, the system's on the iPhone, which lifts the card
/// as its long press shows it.
private struct BoardCardDrag: ViewModifier {
    let drag: BoardDrag?
    let kind: BoardDragKind?
    let id: String
    let list: String
    let index: Int
    /// The card again, for the Mac's lifted copy: a modifier's `content`
    /// draws nothing outside the modifier, so the copy is built afresh.
    let preview: () -> AnyView
    /// The card's frame as last reported. It lives only in the board's
    /// `@ObservationIgnored` storage and is read when a gesture needs it: a
    /// `@State` copy was written for every card on every scroll frame, which
    /// invalidated the whole modifier for a value only gestures read.
    private var frame: CGRect { drag?.cardFrames[id]?.frame ?? .zero }

    func body(content: Content) -> some View {
        if let drag, let kind {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardDrag.space)) } action: { frame in
                    drag.cardFrames[id] = BoardCardFrame(id: id, list: list, frame: frame)
                }
                .onDisappear {
                    // Needed since the `@State frame` went: the frame is read back
                    // from this entry, so the old list's view must not clear the
                    // entry the new list's view just wrote (a card that changed
                    // lists has a view in each list while it settles).
                    if drag.cardFrames[id]?.list == list { drag.cardFrames[id] = nil }
                }
                #if os(macOS)
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(BoardDrag.space))
                            .onChanged { value in
                                if drag.item?.id != id {
                                    drag.preview = preview()
                                    drag.grab = CGSize(
                                        width: value.startLocation.x - frame.minX,
                                        height: value.startLocation.y - frame.minY)
                                    drag.begin(item(kind))
                                    NSCursor.closedHand.push()
                                }
                                drag.move(to: value.location)
                            }
                            .onEnded { value in
                                drag.drop(at: value.location)
                                NSCursor.pop()
                            }
                    )
                    #if DEBUG
                        .task { await rehearse(drag, kind) }
                    #endif
                #else
                    .onDrag {
                        drag.begin(item(kind))
                        return NSItemProvider(object: "hq-board-card:\(id)" as NSString)
                    }
                #endif
        } else {
            content
        }
    }

    private func item(_ kind: BoardDragKind) -> BoardDragItem {
        BoardDragItem(kind: kind, id: id, list: list, index: index, size: frame.size)
    }

    #if DEBUG && os(macOS)
        /// `HQ_UI_DRAG=open:3>420,200[>drop]`: the fixture lifts that card and
        /// walks it to the point, as the gesture would, so a screenshot can
        /// show a drag mid-flight (or landed) with no pointer.
        private func rehearse(_ drag: BoardDrag, _ kind: BoardDragKind) async {
            guard HQSimulatorFixture.isEnabled, let plan = BoardDragRehearsal.plan(list: list, index: index)
            else { return }
            try? await Task.sleep(for: .seconds(1.5))
            let grab = CGSize(width: 30, height: 20)
            let start = CGPoint(x: frame.minX + grab.width, y: frame.minY + grab.height)
            drag.preview = preview()
            drag.grab = grab
            drag.begin(item(kind))
            let geometry = drag.scroll
            boardDragLog.notice(
                "Rehearsal offset \(geometry?.contentOffset.x ?? -1) inset \(geometry?.contentInsets.leading ?? -1)")
            for step in 1...12 {
                let fraction = CGFloat(step) / 12
                drag.move(
                    to: CGPoint(
                        x: start.x + (plan.to.x - start.x) * fraction, y: start.y + (plan.to.y - start.y) * fraction))
                try? await Task.sleep(for: .milliseconds(40))
            }
            if plan.shouldDrop { drag.drop(at: plan.to) }
        }
    #endif
}

#if DEBUG && os(macOS)
    /// The rehearsed drag `HQ_UI_DRAG` asks for — in every window showing
    /// that card, each board having its own drag.
    @MainActor
    enum BoardDragRehearsal {
        struct Plan {
            let list: String
            let index: Int
            let to: CGPoint
            let shouldDrop: Bool
        }

        private static let requested: Plan? = {
            guard let raw = ProcessInfo.processInfo.environment["HQ_UI_DRAG"] else { return nil }
            let parts = raw.split(separator: ">").map(String.init)
            let from = parts.first?.split(separator: ":").map(String.init) ?? []
            let point = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            guard from.count == 2, let index = Int(from[1]), point.count == 2 else { return nil }
            return Plan(
                list: from[0], index: index, to: CGPoint(x: point[0], y: point[1]),
                shouldDrop: parts.last == "drop")
        }()

        static func plan(list: String, index: Int) -> Plan? {
            guard let requested, requested.list == list, requested.index == index else { return nil }
            return requested
        }
    }
#endif

/// The Mac's card in the air, over the lists: tipped a little the way
/// Trello tips it, where the pointer holds it.
private struct FloatingCard: View {
    let drag: BoardDrag

    var body: some View {
        if let item = drag.item, let point = drag.floating, let preview = drag.preview {
            preview
                .frame(width: item.size.width, height: item.size.height)
                .rotationEffect(.degrees(2.5))
                .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
                .offset(x: point.x - drag.grab.width, y: point.y - drag.grab.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Board

/// The board's side of a drag: where a drop goes, sideways scrolling while
/// the pointer rests at an edge, and — the Mac's — the card in the air; on
/// the iPhone, the system drop destination over all its lists.
struct BoardDropArea: ViewModifier {
    let drag: BoardDrag
    let isPaging: Bool
    let perform: ((BoardDragItem, BoardDropSpot) -> Void)?
    /// The panel over the lists' right: the drag's viewport ends at it.
    var panelInset: CGFloat = 0
    @Binding var position: ScrollPosition

    func body(content: Content) -> some View {
        // Restated on every draw: a board's drop reads the lists as drawn.
        // Unobserved, so this redraws nothing.
        drag.perform = perform
        return
            content
            .coordinateSpace(.named(BoardDrag.space))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                drag.viewportWidth = max(width - panelInset, 0)
            }
            #if os(macOS)
                .overlay(alignment: .topLeading) { FloatingCard(drag: drag) }
            #else
                .modifier(DropIfAny(drag: drag, perform: perform))
            #endif
            .task(id: drag.edge) { await scroll(toward: drag.edge) }
    }

    /// The Mac glides; the phone, whose lists page, turns one page after
    /// the pointer has rested at the edge a moment.
    private func scroll(toward edge: HorizontalEdge?) async {
        guard let edge else { return }
        if isPaging {
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                page(toward: edge)
                try? await Task.sleep(for: .milliseconds(750))
                drag.retrack()
            }
        } else {
            // Faster the deeper into the band, up to ~500pt a second.
            while !Task.isCancelled {
                let x = drag.pointer?.x ?? 0
                let depth = edge == .leading ? BoardDropMath.edgeBand - x : x - (drag.viewportWidth - BoardDropMath.edgeBand)
                let speed = 2 + 6 * min(max(depth / BoardDropMath.edgeBand, 0), 1)
                step(by: edge == .leading ? -speed : speed)
                try? await Task.sleep(for: .milliseconds(16))
                drag.retrack()
            }
        }
    }

    private var bounds: ClosedRange<CGFloat>? {
        guard let geometry = drag.scroll else { return nil }
        let lower = -geometry.contentInsets.leading
        let upper = geometry.contentSize.width + geometry.contentInsets.trailing - geometry.containerSize.width
        return lower...max(lower, upper)
    }

    private func step(by delta: CGFloat) {
        guard let geometry = drag.scroll, let bounds else { return }
        let x = min(max(geometry.contentOffset.x + delta, bounds.lowerBound), bounds.upperBound)
        if x != geometry.contentOffset.x { position.scrollTo(x: x) }
    }

    private func page(toward edge: HorizontalEdge) {
        guard let geometry = drag.scroll, let bounds else { return }
        let starts = drag.listFrames.values.map(\.minX).sorted()
        let gutter = Tokens.Projects.boardGutter
        let target =
            edge == .trailing
            ? starts.first { $0 > gutter + 1 }
            : starts.last { $0 < gutter - 1 }
        guard let target else { return }
        let x = min(max(geometry.contentOffset.x + target - gutter, bounds.lowerBound), bounds.upperBound)
        withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(x: x) }
    }
}

#if os(iOS)
private struct DropIfAny: ViewModifier {
    let drag: BoardDrag
    let perform: ((BoardDragItem, BoardDropSpot) -> Void)?

    func body(content: Content) -> some View {
        if let perform {
            content.onDrop(of: [UTType.text], delegate: BoardDropDelegate(drag: drag, perform: perform))
        } else {
            content
        }
    }
}
#endif

