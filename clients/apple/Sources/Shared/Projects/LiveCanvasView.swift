import SwiftUI

/// How Live draws: the person-grouped list, or the canvas, a second
/// renderer of the same rows. The choice is remembered (`@AppStorage`); the
/// canvas is offered at every width (a narrow window scales it down) but not
/// to VoiceOver or on the iPhone (`LiveThreadsView`).
enum LiveDisplay: String, CaseIterable, Identifiable {
    case canvas = "Canvas"
    case list = "List"
    var id: String { rawValue }
}

/// The canvas's one line colour: a dot and a hairline, never a status.
enum LiveCanvasPalette {
    static let neutral = Tokens.Palette.inkTertiary
}

/// Canvas | List: two flat segments on a quiet track, the Projects | Agents picker's look.
/// `label` is what VoiceOver calls the group ("Agents view" on the Agents page).
struct LiveDisplayPicker: View {
    let display: LiveDisplay
    var label = "Agents view"
    let choose: (LiveDisplay) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LiveDisplay.allCases) { option in
                Button { choose(option) } label: {
                    Text(option.rawValue).font(Tokens.Projects.ctaSmall)
                        .foregroundStyle(option == display ? Tokens.Palette.ink : Tokens.Palette.inkSecondary)
                        .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 4)
                        .background(option == display ? Tokens.Palette.segmentChip : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == display ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Tokens.Palette.segmentTrack, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Live as a graph: people at the
/// two outer edges as round avatars, their agents' pills in a column beside
/// each, a hairline tree from avatar to pill, the projects the agents are on down the
/// middle with a curve from each linked pill, a dashed arc over the top where two people
/// are on one task, and the people with no active agent in a dim row at the
/// bottom. The same rows the list shows, placed by `LiveCanvasLayout`.
///
/// Only agents active now are pills (`LiveCanvasLayout.activeMinutes`), so the
/// canvas can still be taller than the window: it sits in a `LiveCanvasViewport`
/// that opens fitted to the width (a window narrower than `LiveCanvasLayout.minWidth`
/// shows the canvas scaled down to it) and pans and zooms (pinch, the Mac's middle-button drag
/// and an iPad finger's drag on empty canvas, two-finger scroll,
/// the View menu's Zoom In, Zoom Out and Fit, the corner buttons). The lines of an active session (the filled
/// green dot) flow with a slow dash; the others are still, and none flow under
/// Reduce Motion, in a hidden window or off screen.
///
/// Every node drags (a person with their pills, a pill, a project, an idle
/// face) and stays where it is put, across refreshes and relaunches: the drop is saved as a
/// `LiveCanvasPositions` pin for this hub and person. A node goes anywhere, past the sides and
/// above the top too (no invisible walls); the canvas grows to hold it, and the pan is
/// free (`LiveCanvasCamera.keepVisible`). While a node is dragged only it and its own lines move
/// (`CanvasDrag`): the canvas is laid out again once, at the drop, and a refresh mid-drag
/// never makes it smaller than it was when the drag began. "Put Back" on
/// a moved node's menu and "Reset Layout" beside the zoom controls undo it.
///
/// Mac (the way Figma and Miro do it): a left drag that starts on empty canvas draws a
/// box and selects the cards it touches (`boxSelection`, view state only; Shift adds, a click on
/// empty canvas or Escape clears, Shift-click on a card toggles it); dragging a selected card moves
/// every selected card by the same offset, each saved as a pin as a single drag saves one, and
/// "Put Back" on a selected card puts back every selected card that is pinned. The pan is the
/// middle button's. `selected`, the project whose agents stand out, is a different thing.
///
/// Double-clicking a person (Mac, from the click count of the press; a double-tap on iPad) mirrors
/// them: their pills cross to the other side of the avatar and the flag is saved with
/// the pins (`LiveCanvasPositions.mirrored`). The first click of the pair does what a single click
/// always did, so nothing waits for a second one. Idle faces and cards other than a person do
/// nothing new; "Put Back" on a person clears their flag with their pin, "Reset Layout" every flag.
///
/// Nodes are real views at fixed slots, so tapping, focus and VoiceOver come
/// from them under any zoom and pan; the lines are `Canvas` layers behind them
/// that draw and hear nothing. No glass; a poll swaps text and a tap on a
/// project swaps opacity, both with the animation cleared.
struct LiveCanvasView: View {
    @Environment(AppStore.self) private var store
    let model: LiveThreadsModel
    /// The width the layout is built for (the card's, before it is scaled to fit).
    let width: CGFloat
    /// The width the card has, which is less than the layout's in a narrow window.
    let space: CGFloat
    /// Projects the server keeps for itself: never drawn in the centre.
    var systemProjectIds: Set<String> = []
    /// The clock the model's ages use: a session older than `LiveCanvasLayout.activeMinutes` is not drawn.
    let now: Date
    /// Whose places are kept: this hub and this signed-in person.
    let hub: String
    let personID: String
    /// A session node was tapped: opens its thread, like a row.
    let open: (String) -> Void
    /// Where the person left the zoom and pan, held above the board (`LiveThreadsStore`)
    /// because opening a thread tears the board and this view down.
    let camera: Binding<LiveCanvasCamera?>
    #if DEBUG
        /// Tests watch the box selection through this; nothing in the app sets it.
        var boxSelectionObserver: ((Set<String>) -> Void)?
    #endif
    /// The project whose sessions stand out; the rest dim. Tapping it again clears it.
    @State private var selected: String?
    /// The cards picked with a box or Shift-click (Mac), as pin keys. Not `selected`: that is the
    /// project filter, and the two do not touch. View state only: it is not saved, and it drops a
    /// card that leaves the canvas.
    @State private var boxSelection: Set<String> = []
    /// Whether Shift was down at the last press, as the viewport's event monitor saw it.
    @State private var pointer = LiveCanvasPointer()
    /// The flowing dash runs only while the canvas can be seen.
    @State private var isOnScreen = true
    /// The places the person has put nodes. Nil until read: the first pass of `body` reads them
    /// from disk itself (`held`) so the first layout, and the camera that opens against it, already
    /// have every node where it was left, and `onAppear` keeps what was read. Never read in
    /// `init`, which runs on every redraw of the page above.
    @State private var storedPositions: LiveCanvasPositions?
    /// The nodes being dragged right now. Read only by them and their lines, never by `body`'s layout.
    @State private var drag = CanvasDrag()
    /// A drag that ends over a button must not also press it.
    @State private var tapsResumeAt = Date.distantPast

    /// Where this person's places are kept. A fixture window and a session with no person keep
    /// them in memory only.
    private var pinStore: LiveCanvasPositionsStore {
        var keepsOnDisk = !personID.isEmpty
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            if HQSimulatorFixture.isEnabled { keepsOnDisk = false }
        #endif
        return LiveCanvasPositionsStore(hub: hub, personID: personID, defaults: keepsOnDisk ? .standard : nil)
    }

    /// The saved places: what is held, or, before the first read has landed, what the disk has.
    private var positions: LiveCanvasPositions {
        get { storedPositions ?? loadPositions() }
        nonmutating set { storedPositions = newValue }
    }

    private func loadPositions() -> LiveCanvasPositions {
        var loaded = pinStore.load()
        seedFixturePins(into: &loaded)
        return loaded
    }

    private func rowIndex() -> [String: LiveThreadsModel.Row] {
        Dictionary(model.groups.flatMap { $0.named + $0.unnamed }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func groupIndex() -> [String: LiveThreadsModel.Group] {
        Dictionary(model.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Selection only counts while its node is on the canvas.
    private func activeSelection(_ layout: LiveCanvasLayout) -> String? {
        selected.flatMap { id in layout.nodes.contains { $0.kind == .hub && $0.refId == id } ? id : nil }
    }

    var body: some View {
        let held = positions
        let layout = LiveCanvasLayout.layout(
            model: model, systemProjectIds: systemProjectIds, width: width, now: now, pins: held, floor: drag.floor)
        let edgeFor = Dictionary(layout.edges.map { ($0.sessionId, $0.targetId) }, uniquingKeysWith: { first, _ in first })
        let rows = rowIndex(), groups = groupIndex()
        let tints = tintsFor(layout)
        let active = activeSelection(layout)
        let dimmed = dimmedPeople(layout, edgeFor: edgeFor, active: active)
        let moved = layout.nodes.contains { held.holds($0.pinKey) }
        return VStack(alignment: .leading, spacing: 0) {
            if let active, let name = names[active] {
                HStack(spacing: Tokens.Space.x2) {
                    Text("Showing agents on \(name)").font(Tokens.Projects.quiet).foregroundStyle(Tokens.Palette.inkSecondary)
                        .lineLimit(1)
                    Button("Clear") { selected = nil }.buttonStyle(.plain).font(Tokens.Projects.quiet)
                        .foregroundStyle(Tokens.Palette.accent)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Tokens.Projects.liveGutter).padding(.bottom, Tokens.Space.x2)
            }
            LiveCanvasViewport(
                contentSize: layout.size, contentOrigin: layout.origin, baseWidth: layout.baseWidth, isDragging: drag.isActive,
                space: space, saved: camera, pointer: pointer, hasSelection: !boxSelection.isEmpty,
                selectBox: { box, isAdditive in selectBox(box, isAdditive: isAdditive, layout: layout) },
                clearSelection: { boxSelection = [] }, resetLayout: moved ? { resetLayout() } : nil
            ) {
                ZStack(alignment: .topLeading) {
                    // The lines a drag leaves alone: drawn again only as a drag starts and ends.
                    CanvasDragReader(drag: drag) { drag in
                        let still = layout.lines(excluding: drag.movers)
                        linesLayer(still, size: layout.size, dimmed: dimmed, tints: tints, active: active)
                        flowLayer(still, size: layout.size, edgeFor: edgeFor, tints: tints, active: active)
                    }
                    // The moving nodes' own lines, the only drawing a pointer move asks for.
                    CanvasDragReader(drag: drag) { drag in
                        let bent = layout.lines(moving: drag.centres)
                        if bent != LiveCanvasLayout.Lines() {
                            linesLayer(bent, size: layout.size, dimmed: dimmed, tints: tints, active: active)
                            flowLayer(bent, size: layout.size, edgeFor: edgeFor, tints: tints, active: active)
                        }
                    }
                    captions(layout)
                    ForEach(layout.nodes) { node in
                        nodeView(node, layout: layout, rows: rows, groups: groups, edgeFor: edgeFor, tints: tints, active: active)
                            .frame(width: node.frame.width, height: node.frame.height)
                            .overlay { if boxSelection.contains(node.pinKey) { SelectionRing(radius: Self.ringRadius(node)) } }
                            .canvasNodeDrag(
                                onMove: { dragMoved(node, by: $0, layout: layout) }, onEnd: { dragEnded(node, by: $0, layout: layout) },
                                onCancel: { drag.cancel(node.pinKey) })
                            .contextMenu {
                                let keys = LiveCanvasSelection.putBackKeys(
                                    for: node.pinKey, selection: boxSelection, isPinned: { held.holds($0) })
                                if !keys.isEmpty { Button("Put Back") { putBack(keys) } }
                            }
                            .position(x: node.frame.midX, y: node.frame.midY)
                            .canvasDragFollow(
                                drag, key: node.pinKey, centre: layout.pinPoint(forDrawn: CGPoint(x: node.frame.midX, y: node.frame.midY)))
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                .transaction { $0.animation = nil }
            }
            .frame(maxWidth: .infinity)
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
        }
        .transaction { $0.animation = nil }
        .onAppear {
            if storedPositions == nil { storedPositions = loadPositions() }
            seedFixtureSelection()
        }
        .onChange(of: pinStore.key) { _, _ in storedPositions = loadPositions() }
        // A node that leaves mid-drag (its session ages out on a clock tick, its person turns
        // idle) takes its drag with it; its own gesture callbacks will never come. A selected
        // card that leaves the canvas leaves the selection.
        .onChange(of: layout.nodes.map(\.pinKey)) { _, keys in
            if let key = drag.key, !keys.contains(key) { drag.end() }
            let selection = LiveCanvasSelection.present(boxSelection, nodes: layout.nodes)
            if selection != boxSelection { boxSelection = selection }
        }
        .onChange(of: boxSelection) { _, now in announce(now) }
    }

    private func announce(_ selection: Set<String>) {
        #if DEBUG
            boxSelectionObserver?(selection)
        #endif
    }

    // MARK: Selecting nodes

    /// A box was drawn over `box` (drawn canvas coordinates): the cards it touches are selected,
    /// added to the selection when Shift was down.
    private func selectBox(_ box: CGRect, isAdditive: Bool, layout: LiveCanvasLayout) {
        let hit = LiveCanvasSelection.keys(in: box, nodes: layout.nodes)
        boxSelection = LiveCanvasSelection.boxed(hit, into: LiveCanvasSelection.present(boxSelection, nodes: layout.nodes), isAdditive: isAdditive)
    }

    /// A click on a card. With Shift down (Mac) it toggles the card in the selection and nothing
    /// else happens; otherwise `plain` is the card's own click.
    private func click(_ node: LiveCanvasLayout.Node, plain: () -> Void) {
        #if os(macOS)
            if pointer.isShiftDown {
                boxSelection = LiveCanvasSelection.toggled(node.pinKey, in: boxSelection)
                return
            }
        #endif
        plain()
    }

    /// `HQ_UI_CANVAS_SELECT="session:thread-one;person:cy"` selects those cards in a fixture run,
    /// so a snapshot can show them highlighted.
    private func seedFixtureSelection() {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            guard HQSimulatorFixture.isEnabled, let raw = ProcessInfo.processInfo.environment["HQ_UI_CANVAS_SELECT"] else { return }
            boxSelection = Set(raw.split(separator: ";").map(String.init))
        #endif
    }

    /// The ring's corner radius for a node: its card's, so the ring hugs it.
    private static func ringRadius(_ node: LiveCanvasLayout.Node) -> CGFloat {
        switch node.kind {
        case .session: 13
        case .hub: 12
        case .person, .idle: 10
        }
    }

    // MARK: Moving nodes

    /// The pointer has taken `node` `translation` canvas points from where the drag began, and with
    /// it every other card of the selection it was picked up from, by the same offset, and a moving
    /// person's pills that are not pinned. Nothing is laid out until the drop.
    private func dragMoved(_ node: LiveCanvasLayout.Node, by translation: CGSize, layout: LiveCanvasLayout) {
        if drag.key != node.pinKey {
            let placed = LiveCanvasSelection.movers(
                dragging: node.pinKey, selection: LiveCanvasSelection.present(boxSelection, nodes: layout.nodes),
                isAdditive: pointer.isShiftDown)
            let moving = placed.union(layout.followers(of: placed, pins: positions))
            var origins: [String: CGPoint] = [:]
            for mover in layout.nodes where moving.contains(mover.pinKey) {
                origins[mover.pinKey] = layout.pinPoint(forDrawn: CGPoint(x: mover.frame.midX, y: mover.frame.midY))
            }
            drag.begin(key: node.pinKey, placed: placed.filter { origins[$0] != nil }, origins: origins, floor: layout.bounds)
        }
        drag.move(by: translation, baseWidth: layout.baseWidth)
    }

    /// The drop: every moved node's place is saved, for this hub and person, each as a single drag
    /// saves one, and the canvas is laid out again. A move under `LiveCanvasLayout.dropDistance` is
    /// a shaky tap: nothing is saved and taps are not blocked. A card that was not selected becomes
    /// the selection, or joins it when Shift was down (Mac).
    private func dragEnded(_ node: LiveCanvasLayout.Node, by translation: CGSize, layout: LiveCanvasLayout) {
        guard LiveCanvasLayout.isDrop(translation: translation) else {
            drag.end()
            return
        }
        dragMoved(node, by: translation, layout: layout)
        if drag.key == node.pinKey {
            for place in drag.places(baseWidth: layout.baseWidth) { positions.set(place.key, xFraction: place.xFraction, y: place.y, at: Date()) }
            positions = pinStore.save(positions)
            #if os(macOS)
                if !boxSelection.contains(node.pinKey) {
                    boxSelection = LiveCanvasSelection.movers(
                        dragging: node.pinKey, selection: LiveCanvasSelection.present(boxSelection, nodes: layout.nodes),
                        isAdditive: pointer.isShiftDown)
                }
            #endif
        }
        drag.end()
        tapsResumeAt = Date().addingTimeInterval(0.3)
    }

    /// `HQ_UI_CANVAS_PINS="session:thread-one=1.35,260;person:cy=-0.25,-120"` pins those nodes
    /// in a fixture run (a fraction of the width, then y), so a snapshot can show a dragged canvas.
    private func seedFixturePins(into positions: inout LiveCanvasPositions) {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            guard HQSimulatorFixture.isEnabled else { return }
            // `HQ_UI_CANVAS_MIRROR="person:cy;person:bo"` mirrors those people, so a snapshot can show the flip.
            for key in (ProcessInfo.processInfo.environment["HQ_UI_CANVAS_MIRROR"] ?? "").split(separator: ";") {
                positions.setMirrored(String(key), true)
            }
            guard let raw = ProcessInfo.processInfo.environment["HQ_UI_CANVAS_PINS"] else { return }
            for entry in raw.split(separator: ";") {
                let parts = entry.split(separator: "=").map(String.init)
                let place = (parts.count == 2 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
                if place.count == 2 { positions.set(parts[0], xFraction: place[0], y: place[1], at: now) }
            }
        #endif
    }

    /// The person at `node` crosses their pills to the other side of their avatar (or back): the flag
    /// turns over, and pills that were pinned have their pins reflected about the avatar's centre
    /// line, so every pill changes sides. The avatar stays where it is, and so does the corner the
    /// camera is measured from, so only the pills move on screen. Nothing happens in a drag.
    private func mirror(_ node: LiveCanvasLayout.Node, layout: LiveCanvasLayout) {
        guard !drag.isActive, node.kind == .person else { return }
        let pills = layout.trees.filter { $0.personId == node.refId }.map { LiveCanvasPositions.sessionKey($0.targetId) }
        let centre = layout.pinPoint(forDrawn: CGPoint(x: node.frame.midX, y: node.frame.midY))
        positions.mirrorPerson(node.pinKey, aroundX: layout.pinPlace(forPinPoint: centre).xFraction, pills: pills, at: Date())
        positions = pinStore.save(positions)
    }

    private func putBack(_ keys: [String]) {
        for key in keys { positions.remove(key) }
        positions = pinStore.save(positions)
    }

    private func resetLayout() {
        positions.removeAll()
        positions = pinStore.save(positions)
    }

    /// A tap that lands right after a drop belongs to the drop.
    private var canTap: Bool { Date() >= tapsResumeAt }

    /// The names of the projects in the centre.
    private var names: [String: String] {
        var result: [String: String] = [:]
        for group in model.groups { for row in group.named { for project in row.projects where result[project.id] == nil { result[project.id] = project.name } } }
        return result
    }

    /// The colour of each centre node.
    private func tintsFor(_ layout: LiveCanvasLayout) -> [String: Color] {
        Dictionary(
            layout.nodes.filter { $0.kind == .hub }.map { ($0.refId, LiveCanvasPalette.neutral) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: Lines

    /// A person's tree line, a pill's line to its project: a curve that
    /// leaves flat and arrives flat (`LiveCanvasCurve`).
    private static func curve(from: CGPoint, to: CGPoint) -> Path { LiveCanvasCurve.path(from: from, to: to) }

    /// The people whose tree lines a selection dims: those whose session is not on it.
    private func dimmedPeople(_ layout: LiveCanvasLayout, edgeFor: [String: String], active: String?) -> Set<String> {
        active == nil ? [] : Set(layout.nodes.filter { $0.kind == .session && edgeFor[$0.refId] != active }.map(\.refId))
    }

    /// One `Canvas` for still lines: the people's trees, the project edges and the overlap arcs.
    /// It sits behind the nodes and takes no taps. It draws only when the layout, the selection or
    /// the set of moving nodes changes; the lines a drag bends are their own small layer.
    private func linesLayer(
        _ lines: LiveCanvasLayout.Lines, size: CGSize, dimmed dimmedPeople: Set<String>, tints: [String: Color], active: String?
    ) -> some View {
        Canvas { context, _ in
            for tree in lines.trees {
                let dim = dimmedPeople.contains(tree.targetId)
                context.stroke(
                    Self.curve(from: tree.from, to: tree.to), with: .color(Tokens.Palette.inkTertiary.opacity(dim ? 0.1 : 0.4)), lineWidth: 0.9)
            }
            for edge in lines.edges {
                let emphasis = active == nil ? 0.6 : (edge.targetId == active ? 0.95 : 0.1)
                context.stroke(
                    Self.curve(from: edge.from, to: edge.to), with: .color((tints[edge.targetId] ?? LiveCanvasPalette.neutral).opacity(emphasis)),
                    lineWidth: active == edge.targetId ? 1.75 : 1.25)
            }
            for arc in lines.overlaps {
                var path = Path()
                path.move(to: arc.from)
                path.addCurve(to: arc.to, control1: arc.control1, control2: arc.control2)
                context.stroke(
                    path, with: .color(Tokens.Palette.warning),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 3]))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The flowing dash over an active session's two lines (`CanvasFlowLayer`).
    private func flowLayer(
        _ lines: LiveCanvasLayout.Lines, size: CGSize, edgeFor: [String: String], tints: [String: Color], active: String?
    ) -> some View {
        CanvasFlowLayer(lines: flowingLines(lines, edgeFor: edgeFor, tints: tints, active: active), isOnScreen: isOnScreen)
            .frame(width: size.width, height: size.height)
    }

    /// The tree and project lines of active sessions that are not dimmed by a selection.
    private func flowingLines(_ lines: LiveCanvasLayout.Lines, edgeFor: [String: String], tints: [String: Color], active: String?) -> [FlowingLine] {
        var flowing: [FlowingLine] = []
        for tree in lines.trees where tree.isActive && (active == nil || edgeFor[tree.targetId] == active) {
            flowing.append(FlowingLine(path: Self.curve(from: tree.from, to: tree.to), color: Tokens.Palette.live, width: 1.6))
        }
        for edge in lines.edges where edge.isActive && (active == nil || edge.targetId == active) {
            flowing.append(
                FlowingLine(
                    path: Self.curve(from: edge.from, to: edge.to), color: tints[edge.targetId] ?? LiveCanvasPalette.neutral, width: 2.2))
        }
        return flowing
    }

    /// The one caption: the projects in the centre.
    @ViewBuilder private func captions(_ layout: LiveCanvasLayout) -> some View {
        if let point = layout.hubCaptionCenter {
            Text(LiveCanvasLayout.hubCaption).font(.system(size: 11.5)).foregroundStyle(Tokens.Palette.inkTertiary)
                .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Tokens.Projects.listFill, in: Capsule())
                .position(point).allowsHitTesting(false)
        }
    }

    // MARK: Nodes

    @ViewBuilder private func nodeView(
        _ node: LiveCanvasLayout.Node, layout: LiveCanvasLayout, rows: [String: LiveThreadsModel.Row], groups: [String: LiveThreadsModel.Group],
        edgeFor: [String: String], tints: [String: Color], active: String?
    ) -> some View {
        switch node.kind {
        case .person:
            if let group = groups[node.refId] {
                PersonNode(name: group.name, count: node.count, person: store.people[group.id], avatar: LiveCanvasLayout.avatar, dimmed: false)
                    .onClick {
                        click(node) {
                            if LiveCanvasLayout.isMirrorClick(clickCount: pointer.clickCount) { mirror(node, layout: layout) }
                        }
                    }
                    .onDoubleTap { mirror(node, layout: layout) }
            }
        case .idle:
            PersonNode(name: idleName(node.refId), count: nil, person: store.people[node.refId], avatar: LiveCanvasLayout.idleAvatar, dimmed: true)
                .onClick { click(node) {} }
        case .session:
            if let row = rows[node.refId] {
                let target = edgeFor[row.id]
                SessionNode(
                    row: row, tint: target.flatMap { tints[$0] }, showsProvider: node.frame.width >= 180,
                    dimmed: active != nil && target != active, open: { if canTap { click(node) { open(row.id) } } })
            }
        case .hub:
            CentreNode(
                name: names[node.refId] ?? "", detail: detail(count: node.count), color: LiveCanvasPalette.neutral,
                isSelected: active == node.refId, dimmed: active != nil && active != node.refId,
                tap: { if canTap { click(node) { selected = selected == node.refId ? nil : node.refId } } })
        }
    }

    private func detail(count: Int) -> String {
        count == 1 ? "1 agent" : count == 0 ? "No agents" : "\(count) agents"
    }

    private func idleName(_ id: String) -> String {
        model.idle.first { $0.id == id }?.name ?? model.groups.first { $0.id == id }?.name ?? store.people[id]?.name ?? ""
    }
}

// MARK: - Selecting nodes

/// Whether Shift was down when the last left press began (Mac), and its click count, which neither
/// a drag gesture nor a `Button`'s action reports. The viewport's event monitor records them on the
/// press and forgets them a moment after the button is up, once the click or box they belonged to
/// has landed, so a keyboard activation later is never taken for a Shift-click or a double-click.
/// Always false and 0 on iPad.
@MainActor
final class LiveCanvasPointer {
    private(set) var isShiftDown = false
    /// The window server's click count at the last left press: 1 for a single click, 2 for the
    /// second press of a double-click, and so on. A person is mirrored by the release of an even
    /// one (`LiveCanvasLayout.isMirrorClick`), so no click waits to learn whether a second comes.
    /// Forgotten with Shift; 0 while no press is recent and on iPad, which has no clicks.
    private(set) var clickCount = 0
    private var presses = 0

    func press(isShift: Bool, clickCount: Int = 1) {
        presses += 1
        isShiftDown = isShift
        self.clickCount = clickCount
    }

    func release() {
        let press = presses
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if let self, self.presses == press {
                self.isShiftDown = false
                self.clickCount = 0
            }
        }
    }
}

/// A selected card's highlight: an accent ring a little outside its edge over a faint fill, from
/// the accent token that is blue in light and in dark. It takes no clicks.
struct SelectionRing: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
        shape.fill(Tokens.Palette.accent.opacity(0.1))
            .overlay(shape.strokeBorder(Tokens.Palette.accent, lineWidth: 2))
            .padding(-3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Dragging a node

/// The canvas's zoom as the nodes need it to turn a drag on the screen into canvas points. Set
/// by the viewport on its content; only a zoom changes it, never a pan.
private struct LiveCanvasScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private extension EnvironmentValues {
    var liveCanvasScale: CGFloat {
        get { self[LiveCanvasScaleKey.self] }
        set { self[LiveCanvasScaleKey.self] = newValue }
    }
}

/// A node that follows the pointer. The gesture is high priority so it beats the background pan
/// under it, but it needs 4 points of travel on the Mac and 10 on iPad (a finger wobbles more than
/// a pointer), so a plain click or tap still reaches the node's button. It measures in the
/// screen's own coordinates (the node moves under the pointer as it drags) and divides by the zoom
/// to get canvas points. `GestureState` resets when the drag ends or is interrupted (a lost focus,
/// a Cmd-Tab), and that drops the node's half-made drag; so does the node leaving the canvas.
/// Applied through `canvasNodeDrag(onMove:onEnd:onCancel:)`.
private struct NodeDragModifier: ViewModifier {
    #if os(iOS)
        private static let minimumDistance: CGFloat = 10
    #else
        private static let minimumDistance: CGFloat = 4
    #endif

    @Environment(\.liveCanvasScale) private var scale
    @GestureState private var isDragging = false
    let onMove: (CGSize) -> Void
    let onEnd: (CGSize) -> Void
    let onCancel: () -> Void

    private func canvasPoints(_ translation: CGSize) -> CGSize {
        let zoom = max(scale, 0.01)
        return CGSize(width: translation.width / zoom, height: translation.height / zoom)
    }

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(
                DragGesture(minimumDistance: Self.minimumDistance, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { onMove(canvasPoints($0.translation)) }
                    .onEnded { onEnd(canvasPoints($0.translation)) }
            )
            .onChange(of: isDragging) { _, dragging in if !dragging { onCancel() } }
            .onDisappear { onCancel() }
    }
}

// MARK: - Viewport

/// The canvas's zoom for the menu bar: published by the viewport as a focused
/// scene value while the Live canvas is showing, so the Mac's View menu can
/// enable Zoom In, Zoom Out and Fit only then (`HQCommands`).
struct LiveCanvasZoomActions {
    var canZoomIn = false
    var canZoomOut = false
    var canFit = false
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var fit: () -> Void = {}
}

private struct LiveCanvasZoomKey: FocusedValueKey {
    typealias Value = LiveCanvasZoomActions
}

extension FocusedValues {
    var liveCanvasZoom: LiveCanvasZoomActions? {
        get { self[LiveCanvasZoomKey.self] }
        set { self[LiveCanvasZoomKey.self] = newValue }
    }
}

/// The curve between two canvas points: leaves flat and arrives flat. Live's tree and
/// project lines are drawn with it.
enum LiveCanvasCurve {
    static func path(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        let mid = (from.x + to.x) / 2
        path.addCurve(to: to, control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y))
        return path
    }
}

extension View {
    /// Makes the view a node that follows the pointer (`NodeDragModifier`): `onMove` and
    /// `onEnd` get the travel in canvas points, `onCancel` when the drag is interrupted or
    /// the node leaves. Only meaningful inside a `LiveCanvasViewport`, which sets the zoom.
    func canvasNodeDrag(
        onMove: @escaping (CGSize) -> Void, onEnd: @escaping (CGSize) -> Void, onCancel: @escaping () -> Void
    ) -> some View {
        modifier(NodeDragModifier(onMove: onMove, onEnd: onEnd, onCancel: onCancel))
    }

    /// Moves the node with the drag that carries it (`CanvasDrag`). `centre` is where the layout
    /// put it, in pin space.
    func canvasDragFollow(_ drag: CanvasDrag, key: String, centre: CGPoint) -> some View {
        modifier(CanvasDragFollow(drag: drag, key: key, centre: centre))
    }
}

/// A node drag on the canvas: which nodes move and how far. Only the
/// moving nodes and their own lines read it (`CanvasDragFollow`, `CanvasDragReader`), so a pointer
/// move redraws them and lays nothing out; the canvas is laid out again once, at the drop.
@MainActor @Observable
final class CanvasDrag {
    /// The pin keys of the moving nodes; empty with no drag. Changes only as a drag starts and ends.
    private(set) var movers: Set<String> = []
    /// How far they have moved, in canvas points, held at the pin bounds.
    private(set) var offset: CGSize = .zero
    /// The node under the pointer.
    @ObservationIgnored private(set) var key: String?
    /// The nodes the drop saves a place for: the dragged one and the rest of its selection. A
    /// person's unpinned pills move with them but are not saved, as the layout takes them along.
    @ObservationIgnored private(set) var placed: [String] = []
    /// Each moving node's centre when the drag began, in pin space: it does not move when the
    /// canvas's corner does.
    @ObservationIgnored private(set) var origins: [String: CGPoint] = [:]
    /// The canvas's bounds (pin space) when the drag began. A layout before the drop (a refresh)
    /// keeps the canvas at least this big on every side (`layout(floor:)`), so it does not shift or
    /// shrink under the pointer.
    @ObservationIgnored private(set) var floor: CGRect?

    var isActive: Bool { key != nil }

    func begin(key: String, placed: [String], origins: [String: CGPoint], floor: CGRect) {
        self.key = key
        self.placed = placed
        self.origins = origins
        self.floor = floor
        offset = .zero
        movers = Set(origins.keys)
    }

    /// The pointer has gone `translation` from where the drag began: one offset for the group,
    /// held so no saved node passes the pin bounds (`LiveCanvasSelection.groupOffset`).
    func move(by translation: CGSize, baseWidth: CGFloat) {
        let next = LiveCanvasSelection.groupOffset(translation, origins: placed.compactMap { origins[$0] }, baseWidth: baseWidth)
        if next != offset { offset = next }
    }

    /// Where a moving node is now, in pin space; nil for one that is not moving, which reads no offset.
    func centre(_ key: String) -> CGPoint? {
        guard movers.contains(key), let origin = origins[key] else { return nil }
        return CGPoint(x: origin.x + offset.width, y: origin.y + offset.height)
    }

    /// Every moving node's centre now, in pin space.
    var centres: [String: CGPoint] {
        guard !movers.isEmpty else { return [:] }
        let offset = offset
        return origins.mapValues { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
    }

    /// The pins the drop saves.
    func places(baseWidth: CGFloat) -> [(key: String, xFraction: Double, y: Double)] {
        placed.compactMap { key in
            guard let centre = centre(key) else { return nil }
            let place = LiveCanvasPositions.bounded(xFraction: Double(centre.x / max(baseWidth, 1)), y: Double(centre.y))
            return (key, place.xFraction, place.y)
        }
    }

    func end() {
        key = nil
        placed = []
        origins = [:]
        floor = nil
        if !movers.isEmpty { movers = [] }
        if offset != .zero { offset = .zero }
    }

    /// The drag on `key` was interrupted.
    func cancel(_ key: String) {
        if self.key == key { end() }
    }
}

/// Reads `CanvasDrag` in a body of its own, so what `content` reads of the drag redraws this view
/// alone, never the canvas around it.
struct CanvasDragReader<Content: View>: View {
    let drag: CanvasDrag
    @ViewBuilder let content: (CanvasDrag) -> Content

    var body: some View { content(drag) }
}

/// A node's place in a drag: a node that is not moving reads only who is, so a pointer move
/// redraws the moving nodes alone. A moving node stands over the rest.
private struct CanvasDragFollow: ViewModifier {
    let drag: CanvasDrag
    let key: String
    let centre: CGPoint

    func body(content: Content) -> some View {
        let moved = drag.centre(key)
        content
            .offset(x: (moved?.x ?? centre.x) - centre.x, y: (moved?.y ?? centre.y) - centre.y)
            .zIndex(moved == nil ? 0 : 1)
    }
}

private extension View {
    /// A click on a card that is not a button (a person), for Shift-click to select it. Mac only:
    /// the iPad keeps no selection, and a tap here would only compete with the node's drag.
    @ViewBuilder func onClick(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
            onTapGesture(perform: action)
        #else
            self
        #endif
    }

    /// A double-tap on a card, on iPad. The Mac reads the click count of the press instead
    /// (`LiveCanvasPointer`), which holds nothing back: a person's single tap does nothing on iPad,
    /// so a count-2 tap gesture delays no action, and the node's drag (10 points of travel) is
    /// not a tap.
    @ViewBuilder func onDoubleTap(perform action: @escaping () -> Void) -> some View {
        #if os(iOS)
            onTapGesture(count: 2, perform: action)
        #else
            self
        #endif
    }
}

private extension View {
    /// ⌘+key on the corner buttons, on iPad's hardware keyboard only: the Mac's
    /// menu bar owns these keys. (⌘= is the exception, on both: see `controls`.)
    @ViewBuilder func shortcut(_ key: KeyEquivalent) -> some View {
        #if os(iOS)
            keyboardShortcut(key, modifiers: .command)
        #else
            self
        #endif
    }
}

/// The window onto the canvas: a rounded card the canvas is drawn into at a
/// zoom and an offset. It owns the camera and every way to move it, and takes
/// its content as a finished value so a pan or pinch re-runs only this view,
/// never the 70-odd nodes' bodies.
///
/// - Pinch (trackpad on Mac, two fingers on iPad) zooms about the gesture.
/// - A drag that starts on a node moves that node, and the selection it belongs to
///   (`NodeDragModifier`), and a click on a node without travel is still its button's, so
///   taps always land. One that starts on empty canvas pans on iPad and, on the Mac,
///   draws a box that selects the cards it touches; a click on empty canvas, or Escape, clears
///   the selection. A pan, box or pinch that is interrupted (a lost focus, a Cmd-Tab) forgets
///   its start through `GestureState`, so it never strands the next one.
/// - Mac: the middle button's drag pans, wherever it starts. Two-finger scroll pans and ⌘-scroll
///   zooms about the pointer. The page's own scroll view would otherwise take the scroll, so a
///   local event monitor (`CanvasInputMonitor`) claims it while the pointer is over the card.
/// - The buttons in the corner zoom about the centre. On the Mac the View menu
///   has the same three (⌘+, ⌘-, ⌘0): the viewport publishes them as the
///   focused scene value `liveCanvasZoom` while it is on screen, so the menu
///   items are enabled only while the Live canvas is showing. The buttons
///   carry ⌘- and ⌘0 only on iPad, where there is no menu bar.
///   ⌘= is the + button's on both, and not a second menu row: macOS apps
///   list one Zoom In (⌘+) and also take the unshifted key.
/// - The camera is kept in `saved` once the person has moved it, unless it is the
///   opening view (`keep`), so a return from a thread (which rebuilds this view)
///   opens where the person left it.
struct LiveCanvasViewport<Content: View>: View {
    let contentSize: CGSize
    /// The pin-space point drawn at the canvas's top-left (`LiveCanvasLayout.origin`). It moves
    /// when a node is dropped left of or above the old corner; the camera follows it so nothing
    /// on screen jumps (`camera`).
    let contentOrigin: CGPoint
    /// The width the layout is built for (`LiveCanvasLayout.baseWidth`): it changes with the window,
    /// never because a node was moved, which tells the two reasons for a new `contentSize` apart.
    let baseWidth: CGFloat
    /// A node is being dragged: the canvas is not refitted under it.
    let isDragging: Bool
    /// The width the card may take; under `contentSize.width` in a narrow window.
    let space: CGFloat
    let content: Content
    /// Shift as the last press saw it (Mac): the box adds to the selection with it down.
    let pointer: LiveCanvasPointer
    /// Something is selected, so Escape has something to clear.
    let hasSelection: Bool
    /// A box was drawn over this rectangle of the canvas (drawn coordinates), with Shift down or not.
    let selectBox: (CGRect, Bool) -> Void
    /// A click on empty canvas, or Escape: nothing is selected.
    let clearSelection: () -> Void
    /// Puts every moved node back; nil while none is moved, and the button is not there.
    let resetLayout: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// The camera as last left, kept above the board; nil until the person first moves it.
    @Binding var saved: LiveCanvasCamera?
    /// The camera as last set; its offset is measured from the canvas corner it records
    /// (`LiveCanvasCamera.origin`), which `camera` moves to the corner drawn now.
    @State private var cameraState = LiveCanvasCamera()
    /// The layout width the camera was last fitted for.
    @State private var settledBase: CGFloat = 0
    /// The person has moved the view (or came back to a view they had moved): a canvas that
    /// changes under it no longer reopens it at the automatic layout. Dropping a node does not
    /// count: the opening view keeps the automatic layout where it is on screen, whatever the
    /// canvas around it grows to.
    @State private var hasTakenOver = false
    /// The card as laid out; the canvas's own size until it is measured.
    @State private var viewport: CGSize = .zero
    @State private var hasOpened = false
    @State private var dragStart: LiveCanvasCamera?
    @State private var pinchStart: LiveCanvasCamera?
    /// The camera when the middle button went down (Mac): the pan is measured from it.
    @State private var middlePanStart: LiveCanvasCamera?
    /// The box being drawn and where it began, in pin space (the canvas's drawn coordinates plus
    /// `contentOrigin`), so a scroll mid-drag moves the pointer's corner and not the one it began
    /// at, and neither does a refresh that moves the canvas's corner (`drawn(_:)` turns it back).
    @State private var marquee: CGRect?
    @State private var marqueeStart: CGPoint?
    @GestureState private var isBoxing = false
    /// True while a pan or pinch is in progress. A `GestureState` goes back to false when the
    /// gesture ends, is cancelled or is interrupted, which `onEnded` alone does not report, and
    /// that is when the start it held must go: a pinch whose start stayed behind would block
    /// every pan after it (`pan` waits for no pinch).
    @GestureState private var isPanning = false
    @GestureState private var isPinching = false

    init(
        contentSize: CGSize, contentOrigin: CGPoint, baseWidth: CGFloat, isDragging: Bool, space: CGFloat,
        saved: Binding<LiveCanvasCamera?>, pointer: LiveCanvasPointer, hasSelection: Bool,
        selectBox: @escaping (CGRect, Bool) -> Void, clearSelection: @escaping () -> Void,
        resetLayout: (() -> Void)? = nil, @ViewBuilder content: () -> Content
    ) {
        self.contentSize = contentSize
        self.contentOrigin = contentOrigin
        self.baseWidth = baseWidth
        self.isDragging = isDragging
        self.space = space
        self._saved = saved
        self.pointer = pointer
        self.hasSelection = hasSelection
        self.selectBox = selectBox
        self.clearSelection = clearSelection
        self.resetLayout = resetLayout
        self.content = content()
    }

    /// The least the card is, however short the window.
    private static var minHeight: CGFloat { 300 }

    private var cardWidth: CGFloat { LiveCanvasCamera.cardWidth(content: contentSize, space: space) }
    /// The canvas at the fit. The card never insists on more than this, so a short canvas in a
    /// short window keeps the card, and its zoom controls, inside the window.
    private var fittedHeight: CGFloat { contentSize.height * min(1, cardWidth / max(contentSize.width, 1)) }

    /// The camera, kept on the same canvas points when the canvas's corner has moved since it was
    /// set. Corrected here, in the pass that draws the new corner, rather than after it, so no
    /// frame shows the canvas shifted; `settle` then writes the correction back.
    private var camera: LiveCanvasCamera { cameraState.rebased(to: contentOrigin) }

    private func setCamera(_ next: LiveCanvasCamera) {
        cameraState = next.rebased(to: contentOrigin)
    }

    private var viewportSize: CGSize { viewport == .zero ? contentSize : viewport }
    /// The whole canvas at the viewport's width: the Fit button.
    private var fit: LiveCanvasCamera { .fit(content: contentSize, viewport: viewportSize, origin: contentOrigin) }

    /// The automatic layout at the top and the viewport's width: what a view nobody has touched
    /// shows, wherever the pinned nodes have taken the canvas.
    private func home(viewport size: CGSize) -> LiveCanvasCamera {
        .home(content: contentSize, viewport: size, origin: contentOrigin, baseWidth: baseWidth)
    }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // The card takes all the room that is left, however short the canvas, and asks for no more
        // than the fitted canvas or `minHeight`, whichever is less: a bigger window is more room to
        // pan, and room around the canvas to drop nodes into (the canvas grows to hold them), at the
        // same zoom. The canvas is drawn into it as an overlay so its size asks for nothing.
        Color.clear
            .frame(width: cardWidth)
            .frame(minHeight: min(fittedHeight, Self.minHeight), maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    content.environment(\.liveCanvasScale, camera.scale)
                    marqueeBox
                }
                .scaleEffect(camera.scale, anchor: .topLeading)
                .offset(x: camera.offset.x, y: camera.offset.y)
                .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
            }
            .background(Tokens.Projects.listFill)
            .clipShape(card)
            .overlay(card.strokeBorder(Tokens.Palette.border).allowsHitTesting(false))
            .overlay(alignment: .bottomTrailing) { controls.padding(10) }
            .contentShape(Rectangle())
            #if os(macOS)
                // A left drag on empty canvas draws a box and a click on it clears the selection (a
                // Shift-click keeps it, as Shift keeps it for a box); the pan is the middle button's
                // (`CanvasInputMonitor`).
                .gesture(boxSelect)
                .onTapGesture { if !pointer.isShiftDown { clearSelection() } }
            #else
                .gesture(pan)
            #endif
            .simultaneousGesture(pinch)
            #if os(macOS)
                .background(
                    CanvasInputMonitor(
                        pointer: pointer,
                        onScroll: { delta, location, isZoom in
                            if isZoom {
                                userMove(to: camera.zoomed(to: camera.scale * exp(delta.height * 0.01), around: location))
                            } else {
                                userMove(to: camera.panned(by: delta))
                            }
                        },
                        onPan: { middlePan($0) },
                        onEscape: {
                            guard hasSelection else { return false }
                            clearSelection()
                            return true
                        }))
            #endif
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                viewport = size
                if hasOpened {
                    settledBase = baseWidth
                    move(to: hasTakenOver ? camera.resized(content: contentSize, viewport: size) : home(viewport: size), viewport: size)
                } else {
                    hasOpened = true
                    settledBase = baseWidth
                    hasTakenOver = saved != nil
                    setCamera(openingCamera(viewport: size))
                    // A return keeps its place; a first open (nil) shows the automatic layout (`home`).
                }
            }
            .onChange(of: contentSize) { _, _ in contentChanged() }
            .onChange(of: contentOrigin) { _, _ in settle() }
            .onChange(of: isPanning) { _, panning in if !panning { dragStart = nil } }
            .onChange(of: isPinching) { _, pinching in if !pinching { pinchStart = nil } }
            .onChange(of: isBoxing) { _, boxing in
                if !boxing {
                    marquee = nil
                    marqueeStart = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    dragStart = nil
                    pinchStart = nil
                    middlePanStart = nil
                    marquee = nil
                    marqueeStart = nil
                }
            }
            .onAppear { seedFixtureMarquee() }
            .accessibilityElement(children: .contain)
            .focusedSceneValue(\.liveCanvasZoom, menuActions)
    }

    /// What the View menu's Zoom In, Zoom Out and Fit ask of this canvas.
    private var menuActions: LiveCanvasZoomActions {
        LiveCanvasZoomActions(
            canZoomIn: camera.canZoomIn, canZoomOut: camera.canZoomOut, canFit: camera != fit,
            zoomIn: { zoom(by: LiveCanvasCamera.step) }, zoomOut: { zoom(by: 1 / LiveCanvasCamera.step) },
            fit: { userMove(to: fit, animated: true) })
    }

    // MARK: Moving

    /// A move the person asked for: from here on the view is theirs, and a canvas that changes
    /// under it (a node dropped far out) is not sent back to the automatic layout.
    private func userMove(to next: LiveCanvasCamera, animated: Bool = false) {
        hasTakenOver = true
        move(to: next, animated: animated)
    }

    /// The canvas is a different size. A new layout width (the window) goes through
    /// `LiveCanvasCamera.resized`. Otherwise a node was moved, or the pins have just loaded:
    /// a view nobody has touched shows the automatic layout (`home`), any other stays where it is
    /// (rebased to the canvas's corner, and kept reachable), never zoomed under a pointer or after a drop.
    private func contentChanged() {
        guard hasOpened else { return }
        if baseWidth != settledBase {
            settledBase = baseWidth
            move(to: hasTakenOver ? camera.resized(content: contentSize, viewport: viewportSize) : home(viewport: viewportSize))
        } else if !hasTakenOver, !isDragging {
            move(to: home(viewport: viewportSize))
        } else {
            move(to: camera.clamped(content: contentSize, viewport: viewportSize))
        }
        settle()
    }

    /// Writes the corner correction into the camera and, for a view the person has moved, the kept
    /// copy of it (which records its corner, so it needs no correction to come back right).
    private func settle() {
        let current = camera
        guard current != cameraState else { return }
        setCamera(current)
        keep(current)
    }

    /// Holds `camera` above the board for a return from a thread: only a view the person has
    /// moved, and not the exact fit or opening view. An untouched view opens afresh.
    private func keep(_ camera: LiveCanvasCamera, viewport size: CGSize? = nil) {
        saved = hasTakenOver ? camera.kept(content: contentSize, viewport: size ?? viewportSize, baseWidth: baseWidth) : nil
    }

    /// Sets the camera, kept reachable. The opening view, or any view the person has not taken
    /// over, is held as nothing saved, and a camera that follows the fit is held with that flag
    /// (`LiveCanvasCamera.followsFit`), so a thread opened and closed again, or a window resized
    /// meanwhile, fits the width afresh.
    private func move(to next: LiveCanvasCamera, viewport size: CGSize? = nil, animated: Bool = false) {
        let size = size ?? viewportSize
        let clamped = next.rebased(to: contentOrigin).clamped(content: contentSize, viewport: size)
        guard clamped != camera else { return }
        keep(clamped, viewport: size)
        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: 0.16)) { setCamera(clamped) }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { setCamera(clamped) }
        }
    }

    private func zoom(by factor: CGFloat) {
        let size = viewportSize
        userMove(to: camera.zoomed(to: camera.scale * factor, around: CGPoint(x: size.width / 2, y: size.height / 2)), animated: true)
    }

    /// A point of the card (viewport coordinates) in the canvas's drawn coordinates.
    private func canvasPoint(_ viewportPoint: CGPoint) -> CGPoint {
        let zoom = max(camera.scale, 0.01)
        return CGPoint(x: (viewportPoint.x - camera.offset.x) / zoom, y: (viewportPoint.y - camera.offset.y) / zoom)
    }

    /// A point of the card (viewport coordinates) in pin space: it stays on the same canvas point
    /// when a refresh moves the canvas's corner.
    private func pinPoint(_ viewportPoint: CGPoint) -> CGPoint {
        let drawn = canvasPoint(viewportPoint)
        return CGPoint(x: drawn.x + contentOrigin.x, y: drawn.y + contentOrigin.y)
    }

    /// A pin-space box in the canvas's drawn coordinates as of now.
    private func drawn(_ box: CGRect) -> CGRect {
        box.offsetBy(dx: -contentOrigin.x, dy: -contentOrigin.y)
    }

    /// The box, as a thin accent border over a faint fill, drawn in the canvas's own space so it
    /// stays on the points it was dragged over at any zoom and pan, with a hairline at any zoom.
    @ViewBuilder private var marqueeBox: some View {
        if let marquee = marquee.map(drawn) {
            Rectangle().fill(Tokens.Palette.accent.opacity(0.1))
                .overlay(Rectangle().strokeBorder(Tokens.Palette.accent, lineWidth: 1 / max(camera.scale, 0.01)))
                .frame(width: marquee.width, height: marquee.height)
                .offset(x: marquee.minX, y: marquee.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// A left drag that starts on empty canvas (a node's own drag takes one that starts on a node):
    /// the box grows with the pointer and, on release, the cards it touches are selected.
    private var boxSelect: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($isBoxing) { _, state, _ in state = true }
            .onChanged { value in
                let start = marqueeStart ?? pinPoint(value.startLocation)
                marqueeStart = start
                marquee = LiveCanvasSelection.rect(from: start, to: pinPoint(value.location))
            }
            .onEnded { value in
                let start = marqueeStart ?? pinPoint(value.startLocation)
                selectBox(drawn(LiveCanvasSelection.rect(from: start, to: pinPoint(value.location))), pointer.isShiftDown)
                marquee = nil
                marqueeStart = nil
            }
    }

    #if os(macOS)
        /// The middle button's drag pans, wherever it starts, over a card too: the camera moves by
        /// the distance the pointer has travelled since the button went down.
        private func middlePan(_ phase: CanvasInputMonitor.PanPhase) {
            switch phase {
            case .began: middlePanStart = camera
            case .moved(let delta): userMove(to: (middlePanStart ?? camera).panned(by: delta))
            case .ended: middlePanStart = nil
            }
        }
    #endif

    /// `HQ_UI_CANVAS_BOX="x,y,w,h"` shows a box mid-drag over that part of the canvas (drawn
    /// coordinates) in a fixture run, so a snapshot can show one.
    private func seedFixtureMarquee() {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            guard HQSimulatorFixture.isEnabled, let raw = ProcessInfo.processInfo.environment["HQ_UI_CANVAS_BOX"] else { return }
            let box = raw.split(separator: ",").compactMap { Double($0) }
            if box.count == 4 { marquee = CGRect(x: box[0] + contentOrigin.x, y: box[1] + contentOrigin.y, width: box[2], height: box[3]) }
        #endif
    }

    /// The pan of an iPad finger; the Mac's pan is the middle button's.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($isPanning) { _, state, _ in state = true }
            .onChanged { value in
                guard pinchStart == nil else { return }
                let start = dragStart ?? camera
                dragStart = start
                userMove(to: start.panned(by: value.translation))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .updating($isPinching) { _, state, _ in state = true }
            .onChanged { value in
                let start = pinchStart ?? camera
                pinchStart = start
                let size = viewportSize
                // A pinch that reports no place zooms about the centre.
                let anchor = value.startLocation == .zero ? CGPoint(x: size.width / 2, y: size.height / 2) : value.startLocation
                userMove(to: start.zoomed(to: start.scale * value.magnification, around: anchor))
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func openingCamera(viewport size: CGSize) -> LiveCanvasCamera {
        if let saved {
            return .opening(saved: saved, content: contentSize, viewport: size, origin: contentOrigin, baseWidth: baseWidth)
        }
        let opened = home(viewport: size)
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            // `HQ_UI_CANVAS_ZOOM=1.8` opens the fixture zoomed about the card's centre and
            // `HQ_UI_CANVAS_PAN=-120,-300` then moves the canvas by that many points.
            if HQSimulatorFixture.isEnabled, let zoom = ProcessInfo.processInfo.environment["HQ_UI_CANVAS_ZOOM"].flatMap(Double.init) {
                var camera = opened.zoomed(to: CGFloat(zoom), around: CGPoint(x: size.width / 2, y: size.height / 2))
                let pan = (ProcessInfo.processInfo.environment["HQ_UI_CANVAS_PAN"] ?? "").split(separator: ",").compactMap { Double($0) }
                if pan.count == 2 { camera = camera.panned(by: CGSize(width: pan[0], height: pan[1])) }
                return camera.clamped(content: contentSize, viewport: size)
            }
        #endif
        return opened
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 0) {
            if let resetLayout {
                control("arrow.uturn.backward", label: "Reset Layout", help: "Reset Layout: put every node back", action: resetLayout)
            }
            Text("\(camera.percent)%").font(.system(size: 11).monospacedDigit()).foregroundStyle(Tokens.Palette.inkTertiary)
                .padding(.horizontal, 8).accessibilityHidden(true)
            control("minus", label: "Zoom out", help: "Zoom out (⌘-)") { zoom(by: 1 / LiveCanvasCamera.step) }
                .shortcut("-").disabled(!camera.canZoomOut)
            control("arrow.up.left.and.arrow.down.right", label: "Fit to width", help: "Fit to width (⌘0)") {
                userMove(to: fit, animated: true)
            }
            .shortcut("0").disabled(camera == fit)
            // ⌘= on both: the View menu lists Zoom In once, as ⌘+, and this takes the unshifted key.
            control("plus", label: "Zoom in", help: "Zoom in (⌘+)") { zoom(by: LiveCanvasCamera.step) }
                .keyboardShortcut("=", modifiers: .command).disabled(!camera.canZoomIn)
        }
        .background(Tokens.Palette.segmentTrack, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.Palette.border))
    }

    private func control(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.Palette.ink)
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

#if os(macOS)
    import AppKit

    /// The canvas's pointer and key input that SwiftUI's gestures do not give it, read by a local
    /// event monitor that leaves with the window and lets every event it does not claim through:
    ///
    /// - Scroll-wheel events whose pointer is over the card, because the page's own scroll view
    ///   would take them: two-finger scroll pans, ⌘-scroll zooms.
    /// - The middle button (`buttonNumber` 2): a drag pans, wherever it starts, over a card too
    ///. SwiftUI has no gesture for it, and it is claimed so the card under the
    ///   pointer never sees it. A press that carries no window counts only while no other window of
    ///   the app is in front of this one at that point.
    /// - Whether Shift was down when a left press began, which a gesture cannot report and a
    ///   `Button`'s action cannot see (`LiveCanvasPointer`).
    /// - Escape, while something is selected, the card is on screen and no text field is being typed in.
    ///
    /// The view takes no clicks (`hitTest` is nil). Only the part of the card that is on screen
    /// counts: a press over a clipped part belongs to the page.
    private struct CanvasInputMonitor: NSViewRepresentable {
        enum PanPhase {
            case began
            /// How far the pointer is from where the button went down, in points (down is positive).
            case moved(CGSize)
            case ended
        }

        let pointer: LiveCanvasPointer
        /// The scroll in points, the pointer in the card's top-left coordinates and whether it zooms.
        let onScroll: (CGSize, CGPoint, Bool) -> Void
        let onPan: (PanPhase) -> Void
        /// Escape was pressed: true when it cleared something and the key is spent.
        let onEscape: () -> Bool

        func makeNSView(context: Context) -> MonitorView {
            let view = MonitorView()
            update(view)
            return view
        }

        func updateNSView(_ view: MonitorView, context: Context) {
            update(view)
        }

        private func update(_ view: MonitorView) {
            view.pointer = pointer
            view.onScroll = onScroll
            view.onPan = onPan
            view.onEscape = onEscape
        }

        final class MonitorView: NSView {
            var pointer: LiveCanvasPointer?
            var onScroll: (CGSize, CGPoint, Bool) -> Void = { _, _, _ in }
            var onPan: (PanPhase) -> Void = { _ in }
            var onEscape: () -> Bool = { false }
            private var monitor: Any?
            /// Where the middle button went down, in this view's top-left coordinates.
            private var panStart: NSPoint?

            override var isFlipped: Bool { true }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                panStart = nil
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.scrollWheel, .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp, .keyDown]
                ) { [weak self] event in
                    guard let self else { return event }
                    return MainActor.assumeIsolated { self.handle(event) }
                }
            }

            private func handle(_ event: NSEvent) -> NSEvent? {
                guard window != nil else { return event }
                switch event.type {
                case .scrollWheel: return handleScroll(event)
                case .leftMouseDown:
                    if event.window === window {
                        pointer?.press(isShift: event.modifierFlags.contains(.shift), clickCount: event.clickCount)
                    }
                    return event
                case .leftMouseUp:
                    if event.window === window { pointer?.release() }
                    return event
                case .otherMouseDown, .otherMouseDragged, .otherMouseUp: return handleMiddle(event)
                case .keyDown: return handleKey(event)
                default: return event
                }
            }

            /// The event's place in this view's coordinates. An event with no window (a middle-button
            /// event can arrive that way) carries the screen's coordinates instead; it counts when
            /// that point is inside this view's window (`isOnTop` says whether another window of the
            /// app is in front of it there).
            private func location(of event: NSEvent) -> NSPoint? {
                guard let window else { return nil }
                if event.window === window { return convert(event.locationInWindow, from: nil) }
                guard event.window == nil, window.frame.contains(event.locationInWindow) else { return nil }
                return convert(window.convertPoint(fromScreen: event.locationInWindow), from: nil)
            }

            /// Whether a window-less event at a screen point is for this view's window: no other
            /// window of this app (an HQ panel, a popover) is in front of it there. An event that
            /// carries a window is for that window and needs no check. Only this app's windows are
            /// asked: a click on another app's window never reaches a local monitor, and the window
            /// server's own answer for a point (`NSWindow.windowNumber(at:)`) is whatever is topmost,
            /// a lock screen or a click-through overlay included.
            private func isOnTop(_ event: NSEvent) -> Bool {
                guard event.window == nil, let window else { return true }
                for other in NSApp.orderedWindows {
                    if other === window { return true }
                    if other.isVisible, !other.ignoresMouseEvents, other.frame.contains(event.locationInWindow) { return false }
                }
                return true
            }

            private func handleScroll(_ event: NSEvent) -> NSEvent? {
                guard event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
                let point = convert(event.locationInWindow, from: nil)
                // Only the part of the card that is on screen: a scroll over a clipped part belongs to the page.
                guard bounds.intersection(visibleRect).contains(point) else { return event }
                // A mouse wheel reports lines, a trackpad points.
                let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                onScroll(
                    CGSize(width: event.scrollingDeltaX * unit, height: event.scrollingDeltaY * unit), point,
                    event.modifierFlags.contains(.command))
                return nil
            }

            private func handleMiddle(_ event: NSEvent) -> NSEvent? {
                guard event.buttonNumber == 2 else { return event }
                switch event.type {
                case .otherMouseDown:
                    guard !isHiddenOrHasHiddenAncestor, isOnTop(event), let point = location(of: event),
                        bounds.intersection(visibleRect).contains(point)
                    else { return event }
                    panStart = point
                    onPan(.began)
                    return nil
                case .otherMouseDragged:
                    guard let start = panStart, let point = location(of: event) else { return event }
                    onPan(.moved(CGSize(width: point.x - start.x, height: point.y - start.y)))
                    return nil
                default:
                    guard panStart != nil else { return event }
                    panStart = nil
                    onPan(.ended)
                    return nil
                }
            }

            private func handleKey(_ event: NSEvent) -> NSEvent? {
                let escape: UInt16 = 53
                // Caps Lock is a state, not a chord: Escape still counts with it on.
                let chord = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
                guard event.keyCode == escape, chord.isEmpty, event.window === window, !isHiddenOrHasHiddenAncestor,
                    !bounds.intersection(visibleRect).isEmpty, !(window?.firstResponder is NSText)
                else { return event }
                return onEscape() ? nil : event
            }

            deinit {
                if let monitor { NSEvent.removeMonitor(monitor) }
            }
        }
    }
#endif

// MARK: - Nodes

/// A person: a round avatar with their name and agent count under it. Idle
/// people are small and dim, with no count.
struct PersonNode: View {
    let name: String
    let count: Int?
    let person: Person?
    let avatar: CGFloat
    let dimmed: Bool

    var body: some View {
        VStack(spacing: 3) {
            AvatarView(name: name, isGroup: false, size: avatar, person: person).opacity(dimmed ? 0.55 : 1)
            Text(name).font(.system(size: dimmed ? 11 : 12, weight: dimmed ? .regular : .semibold))
                .foregroundStyle(dimmed ? Tokens.Palette.inkTertiary : Tokens.Palette.ink).lineLimit(1)
            if let count {
                Text(count == 1 ? "1 agent" : "\(count) agents").font(.system(size: 11)).foregroundStyle(Tokens.Palette.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
    }

    private var accessibilityText: String {
        var parts = [name]
        if let count {
            parts.append(count == 1 ? "1 agent" : "\(count) agents")
        } else {
            parts.append("not active now")
        }
        return parts.joined(separator: ", ")
    }
}

/// One session: its age mark, name, the tool when it is not Claude, and its age.
/// The stroke is a grey line when it is on a project, a fainter one when it is on a task only,
/// and dashed when it is on neither.
private struct SessionNode: View {
    let row: LiveThreadsModel.Row
    let tint: Color?
    /// The "Codex" tag takes room a narrow pill needs for the name.
    let showsProvider: Bool
    let dimmed: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                LiveAgeMark(age: row.age)
                Text(row.name).font(.system(size: 12)).italic(row.isFallbackName)
                    .foregroundStyle(row.isFallbackName ? Tokens.Palette.inkSecondary : Tokens.Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                if showsProvider, let provider = row.providerText {
                    Text(provider).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.Palette.inkTertiary)
                        .lineLimit(1).fixedSize()
                }
                Text(row.ageText).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Tokens.Palette.inkTertiary)
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Tokens.Projects.cardFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(stroke)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.3 : 1)
        .help("\(row.fullName), \(row.ageText == "now" ? "active now" : "\(row.ageText) ago")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var stroke: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        if let tint {
            shape.strokeBorder(tint, lineWidth: 1.3)
        } else if row.label == .none {
            shape.strokeBorder(Tokens.Palette.inkTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
        } else {
            shape.strokeBorder(Tokens.Palette.inkTertiary.opacity(0.65), lineWidth: 1)
        }
    }
}

/// A project: its colour, its name and its agents. Tapping it picks out its agents.
private struct CentreNode: View {
    let name: String
    let detail: String
    let color: Color
    let isSelected: Bool
    let dimmed: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Tokens.Palette.inkTertiary).lineLimit(1)
                    .padding(.leading, 16)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Tokens.Projects.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(0.6), lineWidth: isSelected ? 2.2 : 1.3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.45 : 1)
        .help(name)
        .accessibilityLabel("\(name), \(detail)")
        .accessibilityHint(isSelected ? "Shows every agent again" : "Shows only the agents on it")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}
