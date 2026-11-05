import Foundation

/// The Live canvas's arithmetic: where each person, session, project
/// and idle face sits, and which line joins which. A second renderer of the
/// same `LiveThreadsModel` the list reads, so the two never disagree about who
/// is here. Pure Foundation with no clock and no random: slots are fixed, there
/// is no force simulation, and the same input gives the same frames. Nothing
/// here draws.
///
/// The shape: people split to the left and right edges, several stacked down
/// each side. A person is a round avatar at the OUTER edge with their name and
/// "N agents" under it, and their session pills stand in a column beside it
/// toward the centre, each joined to the avatar by a hairline "tree" curve. The
/// centre column holds up to five of the projects the visible agents are linked to,
/// most agents first, in neutral colours, under a "Projects" caption. A curve runs from
/// each pill's inner edge to its project.
/// Two people on the same task are joined by a dashed arc over the top. People
/// with no active agent stand dim in a row at the bottom, with no caption.
///
/// Only sessions active now are drawn (`activeMinutes`; the list keeps its
/// three hours), and nothing moves when the order of activity does: people sit
/// in person-id order, alternating sides over the whole roster (drawn, idle or
/// hidden by a search), and a person's pills in project, then session-id,
/// order. A person can drag any node anywhere (no invisible walls);
/// `LiveCanvasPositions` pins it and the layout applies the pin after the
/// automatic placement, so every line follows the moved frame. The canvas grows
/// to hold the automatic layout and every node, past the old edges on all four
/// sides: see "Two coordinate spaces" below.
///
/// Double-clicking a person mirrors them: their pills stand on the other side of the
/// avatar, reflected about its centre line at the same heights, and the lines follow because they are
/// drawn from the frames (`LiveCanvasPositions.mirrored`). The canvas grows to hold them as it does for
/// any node past an edge.
///
/// A session that is active now (the filled green dot) marks its pill, its tree
/// line and its project line `isActive`, which is what the view animates.
struct LiveCanvasLayout: Equatable {
    enum Kind: Equatable { case person, session, hub, idle }

    /// Which side of the centre column a node stands on.
    enum Side: Equatable { case left, right, center }

    struct Node: Identifiable, Equatable {
        let kind: Kind
        /// A person's id (`person`, `idle`), a session's id or a project's id.
        let refId: String
        var frame: CGRect
        let side: Side
        /// `hub`: the agents on it. `person`: their agents in the window.
        var count = 0
        /// `session`: it has a line to a project.
        var linked = false
        /// `session`: active now (the filled green dot), so its lines flow.
        var isActive = false

        var id: String { "\(kind):\(refId)" }
        /// The key this node's place is saved under (`LiveCanvasPositions`).
        var pinKey: String {
            switch kind {
            case .person: LiveCanvasPositions.personKey(refId)
            case .idle: LiveCanvasPositions.idleKey(refId)
            case .session: LiveCanvasPositions.sessionKey(refId)
            case .hub: LiveCanvasPositions.hubKey(refId)
            }
        }
        var leftAnchor: CGPoint { CGPoint(x: frame.minX, y: frame.midY) }
        var rightAnchor: CGPoint { CGPoint(x: frame.maxX, y: frame.midY) }

        /// `person` and `idle`: the round face, at the top of the cell.
        var avatar: CGRect {
            let size = kind == .idle ? LiveCanvasLayout.idleAvatar : LiveCanvasLayout.avatar
            return CGRect(x: frame.midX - size / 2, y: frame.minY, width: size, height: size)
        }
    }

    /// One session's line to its project. `side` is the session's.
    struct Edge: Identifiable, Equatable {
        let sessionId: String
        /// The `refId` of the hub node it ends on.
        let targetId: String
        let side: Side
        let from: CGPoint
        let to: CGPoint
        /// Its session is active now: the line flows.
        var isActive = false

        var id: String { sessionId }
    }

    /// A person's hairline to one of their pills.
    struct Tree: Identifiable, Equatable {
        let personId: String
        /// The `refId` of the session node it ends on.
        let targetId: String
        let side: Side
        let from: CGPoint
        let to: CGPoint
        /// Its session is active now: the line flows.
        var isActive = false

        var id: String { personId + "/" + targetId }
    }

    /// Two people on one task: a dashed arc over the top, with no
    /// label (the text is not needed). `from` and `to` are on
    /// the two pills; the controls draw the cubic.
    struct Overlap: Identifiable, Equatable {
        let taskId: String
        let sessionIds: [String]
        let from: CGPoint
        let to: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        /// Its lane in the band above the pills (`lanePeak`).
        var lane = 0

        var id: String { taskId }
    }

    /// Every line the canvas draws behind its nodes.
    struct Lines: Equatable {
        var trees: [Tree] = []
        var edges: [Edge] = []
        var overlaps: [Overlap] = []
    }

    // MARK: Rules

    /// The narrowest the canvas is laid out: the columns, the centre and the
    /// gaps between them need this much. A smaller space gets the same layout
    /// at this width and `LiveCanvasCamera.fit` scales it down to the space, so
    /// a narrow Mac window and an iPad split view show the whole picture. This
    /// is not the card panel's breakpoint (`Tokens.Projects.panelBelow`, which
    /// happens to be the same number): the two are unrelated.
    static let minWidth: CGFloat = 720
    /// Wider than this the canvas stops growing and the view centres it.
    static let maxWidth: CGFloat = 1600
    /// Projects drawn in the centre.
    static let maxHubs = 5
    /// Overlap arcs drawn.
    static let maxOverlaps = 3
    /// A session is drawn only when its last activity is this recent; the list keeps
    /// its three hours (`LiveThreadsModel.liveMinutes`), the canvas shows what is happening now.
    static let activeMinutes = 15

    static let avatar: CGFloat = 40
    static let idleAvatar: CGFloat = 30
    static let personCellWidth: CGFloat = 72
    /// Avatar, name, count.
    static let personCellHeight: CGFloat = 76
    /// Where the pills start, measured from the canvas's own edge.
    static let pillInset: CGFloat = 88
    static let pillHeight: CGFloat = 26
    static let rowStep: CGFloat = 32
    static let minPillWidth: CGFloat = 130
    static let maxPillWidth: CGFloat = 232
    static let minGap: CGFloat = 44
    static let minCenterWidth: CGFloat = 156
    static let maxCenterWidth: CGFloat = 260
    static let hubHeight: CGFloat = 46
    /// Between one centre node and the next: fixed, so the projects stack
    /// from the top of the column in their order at any height.
    static let centerGap: CGFloat = 28
    static let personGap: CGFloat = 26
    static let captionHeight: CGFloat = 20
    /// Between one overlap arc's peak and the next, so they never share a lane.
    static let overlapStep: CGFloat = 10
    static let idleCell = CGSize(width: 72, height: 54)
    static let margin: CGFloat = 14

    static let hubCaption = "Projects"

    /// Two coordinate spaces. A pin is in PIN space: x is a fraction of `baseWidth`, y is down from
    /// the automatic layout's top, and both may be negative or past 1. Everything this layout
    /// carries (node frames, line ends, the caption) is in DRAWN space, whose top-left is the
    /// canvas's own corner: `drawn = pin - origin`. With no node outside the automatic layout
    /// `origin` is zero and the two agree. `layout` shifts everything into drawn space once, at its
    /// end; `pinPoint(forDrawn:)` and `drawnPoint(forPin:)` are the way back and forth after that.
    ///
    /// The canvas's size in drawn space: the automatic layout's bounds united with every node's
    /// frame (and every line), plus `margin` where a node reaches past them.
    let size: CGSize
    /// The pin-space point drawn at the canvas's top-left: negative when a node sits left of or
    /// above the automatic layout.
    let origin: CGPoint
    /// The width pins are fractions of: the automatic layout's, `min(max(width, minWidth), maxWidth)`.
    let baseWidth: CGFloat
    /// People with their sessions and chips, the centre column, then the idle row.
    let nodes: [Node]
    let edges: [Edge]
    let trees: [Tree]
    let overlaps: [Overlap]
    /// The centre holds projects.
    let usesHubs: Bool
    /// Where the "Projects" caption sits, when it shows.
    let hubCaptionCenter: CGPoint?

    // MARK: Layout

    /// The canvas in pin space: where the drawing sits relative to the automatic layout.
    var bounds: CGRect { CGRect(origin: origin, size: size) }

    /// The pin-space point of a drawn point.
    func pinPoint(forDrawn point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    /// The drawn point of a pin-space point.
    func drawnPoint(forPin point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// The pin (a fraction of `baseWidth`, and y) for a pin-space point.
    func pinPlace(forPinPoint point: CGPoint) -> (xFraction: Double, y: Double) {
        (Double(point.x / max(baseWidth, 1)), Double(point.y))
    }

    /// Whether the Canvas | List choice exists: at every window width, but not under VoiceOver
    /// (the canvas is a picture; the list is the accessible form) and not on the iPhone.
    static func isOffered(voiceOver: Bool, isPhone: Bool) -> Bool { !voiceOver && !isPhone }

    /// The gutter either side of the canvas card in a window `windowWidth` wide. At or above
    /// `minWidth` it narrows between `minWidth` and `minWidth + 2 * gutter`, so the canvas
    /// stays at 720pt and 1:1 there; a window under `minWidth` keeps the whole gutter and the
    /// canvas is scaled down to what is left.
    static func stageInset(windowWidth: CGFloat, gutter: CGFloat) -> CGFloat {
        guard windowWidth >= minWidth else { return gutter }
        return max(0, min(gutter, (windowWidth - minWidth) / 2))
    }

    /// Whether a session counts as active now: its last activity is within
    /// `activeMinutes` of `now`. Ended sessions never reach the canvas (the model
    /// leaves them out of its live set), and `state` is not read: only check-ins
    /// set it, so the age of the activity is the truth.
    static func isActive(_ row: LiveThreadsModel.Row, now: Date) -> Bool {
        now.timeIntervalSince(row.activity) <= Double(activeMinutes) * 60
    }

    /// The pills the canvas draws, across everyone: the header's "N agents active now".
    static func activeCount(model: LiveThreadsModel, now: Date) -> Int {
        var count = 0
        for group in model.groups {
            for row in group.named + group.unnamed where isActive(row, now: now) { count += 1 }
        }
        return count
    }

    /// Canvas points a node must travel before letting go of it saves a place. Less is a
    /// shaky tap: nothing is saved and the tap is not blocked.
    static let dropDistance: CGFloat = 8

    /// Whether a drag that moved a node `translation` canvas points is a drop, not a tap.
    static func isDrop(translation: CGSize) -> Bool {
        (translation.width * translation.width + translation.height * translation.height) >= dropDistance * dropDistance
    }

    /// Whether a press that is the `clickCount`th of a quick run of clicks (the window server's
    /// count) mirrors a person: every second one, so two double-clicks in a row flip and flip back.
    static func isMirrorClick(clickCount: Int) -> Bool { clickCount >= 2 && clickCount.isMultiple(of: 2) }

    /// One person as the layout sees them.
    private struct Person {
        let id: String
        let name: String
        /// Their sessions active now, in the order they are drawn once ranked.
        var rows: [LiveThreadsModel.Row]
    }

    /// The canvas for `model` in `width` points: `minWidth` when the space is
    /// narrower (the view scales it to fit) and `maxWidth` when it is wider.
    /// `now` is the clock the model's ages use; `pins` are the places the person
    /// has put nodes, applied after the automatic placement. `floor` is pin-space bounds the
    /// canvas never gets smaller than, on any side: a drag passes the canvas it began on, so a
    /// node pulled back inward does not shrink the canvas, or move its corner, under the pointer.
    static func layout(
        model: LiveThreadsModel, systemProjectIds: Set<String> = [], width: CGFloat, now: Date,
        pins: LiveCanvasPositions = LiveCanvasPositions(), floor: CGRect? = nil
    ) -> LiveCanvasLayout {
        let width = min(max(width, minWidth), maxWidth).rounded(.down)

        // Everyone drawn: a person with a group, or an idle face.
        var everyone: [String: Person] = [:]
        for group in model.groups {
            everyone[group.id] = Person(
                id: group.id, name: group.name, rows: (group.named + group.unnamed).filter { isActive($0, now: now) })
        }
        for idle in model.idle where everyone[idle.id] == nil {
            everyone[idle.id] = Person(id: idle.id, name: idle.name, rows: [])
        }
        guard !everyone.isEmpty else {
            return LiveCanvasLayout(
                size: CGSize(width: width, height: 0), origin: .zero, baseWidth: width, nodes: [], edges: [], trees: [],
                overlaps: [], usesHubs: false, hubCaptionCenter: nil)
        }
        // Sides go by person id over the whole roster (`LiveThreadsModel.roster`), which a search
        // does not shrink, so neither who was active last, who else is active now nor a keystroke
        // in the search moves anyone to the other side.
        let order = everyone.keys.sorted()
        var sideOf: [String: Side] = [:]
        let sideOrder = Set(model.roster.map(\.id)).union(order).sorted()
        for (index, id) in sideOrder.enumerated() { sideOf[id] = index % 2 == 0 ? .left : .right }
        let drawnIds = order.filter { !(everyone[$0]?.rows.isEmpty ?? true) }
        let idlePeople = order.compactMap { everyone[$0] }.filter(\.rows.isEmpty).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        let allRows = drawnIds.flatMap { everyone[$0]?.rows ?? [] }

        // The centre column: the projects the drawn agents are on.
        let hubs = hubList(rows: allRows.filter { !$0.isUnnamed }, systemProjectIds: systemProjectIds)
        let usesHubs = !hubs.isEmpty
        let hubSlot: [String: Int] = Dictionary(uniqueKeysWithValues: hubs.enumerated().map { ($1.id, $0) })
        /// Projects in the centre's order, then none.
        func rank(_ row: LiveThreadsModel.Row) -> Int {
            if let hub = hubId(for: row, hubs: hubs), let slot = hubSlot[hub] { return slot }
            return 9999
        }
        for id in drawnIds {
            everyone[id]?.rows.sort { (rank($0), $0.id) < (rank($1), $1.id) }
        }
        let shown: [[LiveThreadsModel.Row]] = drawnIds.map { everyone[$0]?.rows ?? [] }

        // Columns.
        let avail = width - 2 * pillInset
        let centerWidth = min(max((avail * 0.26).rounded(.down), minCenterWidth), maxCenterWidth)
        let pillWidth = min(max(((avail - centerWidth - 2 * minGap) / 2).rounded(.down), minPillWidth), maxPillWidth)
        let centerLeft = ((width - centerWidth) / 2).rounded(.down)
        let leftPillX = pillInset
        let rightPillX = width - pillInset - pillWidth

        // Overlaps decide how much room the top needs.
        let overlapPlans = plannedOverlaps(ids: drawnIds, shown: shown)
        let topPad: CGFloat = overlapPlans.isEmpty ? 14 : 26 + CGFloat(overlapPlans.count - 1) * overlapStep

        var personNodes: [(node: Node, pills: [String])] = []
        var pillNodes: [String: Node] = [:]
        var cursor: [Side: CGFloat] = [.left: topPad, .right: topPad]

        for (index, id) in drawnIds.enumerated() {
            let side = sideOf[id] ?? .left
            let rows = shown[index]
            let rowsHeight = CGFloat(rows.count) * rowStep - (rowStep - pillHeight)
            let top = cursor[side] ?? topPad
            let centerY = top + rowsHeight / 2
            let cellTop = (centerY - avatar / 2).rounded(.down)
            let cellX = side == .left ? 2 : width - 2 - personCellWidth
            let person = Node(
                kind: .person, refId: id,
                frame: CGRect(x: cellX, y: cellTop, width: personCellWidth, height: personCellHeight), side: side,
                count: rows.count)
            let pillX = side == .left ? leftPillX : rightPillX
            var y = top
            for row in rows {
                var node = Node(
                    kind: .session, refId: row.id, frame: CGRect(x: pillX, y: y, width: pillWidth, height: pillHeight), side: side)
                node.isActive = row.age == .fresh
                pillNodes[row.id] = node
                y += rowStep
            }
            personNodes.append((person, rows.map(\.id)))
            cursor[side] = max(top + rowsHeight, cellTop + personCellHeight) + personGap
        }
        let columnsBottom = personNodes.isEmpty ? 0 : max((cursor[.left] ?? topPad), (cursor[.right] ?? topPad)) - personGap

        // The centre column: stacked from the top at a fixed gap, in order.
        let slots = hubs.count
        let captionRoom: CGFloat = usesHubs ? captionHeight : 0
        let neededHeight = captionRoom + CGFloat(slots) * hubHeight + CGFloat(max(slots - 1, 0)) * centerGap
        let regionTop = topPad + captionRoom
        var centerNodes: [Node] = []
        for index in 0..<slots {
            let y = regionTop + CGFloat(index) * (hubHeight + centerGap)
            let frame = CGRect(x: centerLeft, y: y, width: centerWidth, height: hubHeight)
            centerNodes.append(Node(kind: .hub, refId: hubs[index].id, frame: frame, side: .center, count: hubs[index].agents))
        }
        let hasContent = !personNodes.isEmpty || slots > 0
        let contentBottom: CGFloat = hasContent ? max(columnsBottom, slots > 0 ? topPad + neededHeight : 0) : 0

        // The idle row, with no caption.
        var idleNodes: [Node] = []
        var bottom = contentBottom
        if !idlePeople.isEmpty {
            let perRow = max(1, Int((width - 2 * margin) / (idleCell.width + 6)))
            let rows = stride(from: 0, to: idlePeople.count, by: perRow).map { Array(idlePeople[$0..<min($0 + perRow, idlePeople.count)]) }
            var y = contentBottom + (hasContent ? 34 : 14)
            for row in rows {
                let rowWidth = CGFloat(row.count) * (idleCell.width + 6) - 6
                var x = ((width - rowWidth) / 2).rounded(.down)
                for person in row {
                    idleNodes.append(
                        Node(kind: .idle, refId: person.id, frame: CGRect(origin: CGPoint(x: x, y: y), size: idleCell), side: .center))
                    x += idleCell.width + 6
                }
                y += idleCell.height + 4
            }
            bottom = y
        }

        // Pins, after the automatic placement. Where a node is pinned its centre is the pin,
        // wherever that is (past the width, above the top); a pin is only held to the sanity
        // bounds (`LiveCanvasPositions.bounded`). A pinned person takes their unpinned pills
        // along by the distance they moved; a pinned pill stays where it was put.
        func pinnedCenter(_ node: Node) -> CGPoint? {
            guard let pin = pins.pin(for: node.pinKey), pin.xFraction.isFinite, pin.y.isFinite else { return nil }
            let place = LiveCanvasPositions.bounded(xFraction: pin.xFraction, y: pin.y)
            return CGPoint(x: place.xFraction * Double(width), y: place.y)
        }
        func move(_ node: inout Node, toCenter center: CGPoint) {
            node.frame = CGRect(
                x: center.x - node.frame.width / 2, y: center.y - node.frame.height / 2, width: node.frame.width, height: node.frame.height)
        }
        for index in personNodes.indices {
            guard let center = pinnedCenter(personNodes[index].node) else { continue }
            let from = CGPoint(x: personNodes[index].node.frame.midX, y: personNodes[index].node.frame.midY)
            let delta = CGSize(width: center.x - from.x, height: center.y - from.y)
            move(&personNodes[index].node, toCenter: center)
            for sessionId in personNodes[index].pills where !pins.contains(LiveCanvasPositions.sessionKey(sessionId)) {
                guard var pill = pillNodes[sessionId] else { continue }
                let shifted = CGPoint(x: pill.frame.midX + delta.width, y: pill.frame.midY + delta.height)
                move(&pill, toCenter: shifted)
                pillNodes[sessionId] = pill
            }
        }
        // A mirrored person's pills stand across the avatar: each unpinned pill is reflected about
        // the avatar's centre line (where the avatar stands now, pinned or not) at the same height.
        // A pinned pill is where it was put; mirroring rewrote its pin when the flag changed.
        for index in personNodes.indices where pins.isMirrored(personNodes[index].node.pinKey) {
            let axis = personNodes[index].node.frame.midX
            for sessionId in personNodes[index].pills where !pins.contains(LiveCanvasPositions.sessionKey(sessionId)) {
                guard var pill = pillNodes[sessionId] else { continue }
                move(&pill, toCenter: CGPoint(x: 2 * axis - pill.frame.midX, y: pill.frame.midY))
                pillNodes[sessionId] = pill
            }
        }
        for (id, pill) in pillNodes {
            guard let center = pinnedCenter(pill) else { continue }
            var moved = pill
            move(&moved, toCenter: center)
            pillNodes[id] = moved
        }
        func applyPins(_ list: inout [Node]) {
            for index in list.indices {
                if let center = pinnedCenter(list[index]) { move(&list[index], toCenter: center) }
            }
        }
        applyPins(&centerNodes)
        applyPins(&idleNodes)

        // Trees, from the avatar's edge toward each pill.
        var nodes: [Node] = []
        var trees: [Tree] = []
        for entry in personNodes {
            let person = entry.node
            nodes.append(person)
            for sessionId in entry.pills {
                guard let pill = pillNodes[sessionId] else { continue }
                nodes.append(pill)
                trees.append(tree(person: person, pill: pill))
            }
        }

        // Edges, in each person's pill order.
        let targets = Dictionary(centerNodes.map { ($0.refId, $0) }, uniquingKeysWith: { first, _ in first })
        var edges: [Edge] = []
        for index in personNodes.indices {
            for row in shown[index] {
                guard let target = hubId(for: row, hubs: hubs),
                    let end = targets[target], let pill = pillNodes[row.id]
                else { continue }
                edges.append(edge(pill: pill, end: end))
            }
        }
        // Mark the linked pills.
        let linked = Set(edges.map(\.sessionId))
        nodes = nodes.map { node in
            guard node.kind == .session, linked.contains(node.refId) else { return node }
            var copy = node
            copy.linked = true
            return copy
        }

        // Overlap arcs.
        var arcs: [Overlap] = []
        for (index, plan) in overlapPlans.enumerated() {
            guard let a = pillNodes[plan.sessionIds[0]], let b = pillNodes[plan.sessionIds[1]] else { continue }
            arcs.append(overlap(taskId: plan.taskId, a: a, b: b, lane: index, peak: lanePeak(index)))
        }

        let all = nodes + centerNodes + idleNodes
        let caption = usesHubs ? CGPoint(x: width / 2, y: topPad + captionHeight / 2) : nil

        // The canvas holds the automatic layout, every node and every line, and a pinned node low
        // on it, past its sides or above its top makes it bigger that way. Everything above is in
        // pin space; the shift into drawn space happens once, here.
        var reach = all.map(\.frame)
        for arc in arcs {
            for step in 0...16 {
                let t = CGFloat(step) / 16, u = 1 - t
                let point = CGPoint(
                    x: u * u * u * arc.from.x + 3 * u * u * t * arc.control1.x + 3 * u * t * t * arc.control2.x + t * t * t * arc.to.x,
                    y: u * u * u * arc.from.y + 3 * u * u * t * arc.control1.y + 3 * u * t * t * arc.control2.y + t * t * t * arc.to.y)
                reach.append(CGRect(origin: point, size: .zero))
            }
        }
        let bounds = canvasBounds(width: width, bottom: bottom, reaching: reach, floor: floor)
        let origin = bounds.origin
        func drawn(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
        guard origin != .zero else {
            return LiveCanvasLayout(
                size: bounds.size, origin: origin, baseWidth: width, nodes: all, edges: edges, trees: trees, overlaps: arcs,
                usesHubs: usesHubs, hubCaptionCenter: caption)
        }
        return LiveCanvasLayout(
            size: bounds.size, origin: origin, baseWidth: width,
            nodes: all.map { node in
                var copy = node
                copy.frame = node.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                return copy
            },
            edges: edges.map {
                Edge(sessionId: $0.sessionId, targetId: $0.targetId, side: $0.side, from: drawn($0.from), to: drawn($0.to), isActive: $0.isActive)
            },
            trees: trees.map {
                Tree(personId: $0.personId, targetId: $0.targetId, side: $0.side, from: drawn($0.from), to: drawn($0.to), isActive: $0.isActive)
            },
            overlaps: arcs.map {
                Overlap(
                    taskId: $0.taskId, sessionIds: $0.sessionIds, from: drawn($0.from), to: drawn($0.to), control1: drawn($0.control1),
                    control2: drawn($0.control2), lane: $0.lane)
            },
            usesHubs: usesHubs, hubCaptionCenter: caption.map(drawn))
    }

    // MARK: Lines

    /// A person's hairline to one pill: from the avatar's edge on the pill's side to the pill's near end.
    static func tree(person: Node, pill: Node) -> Tree {
        let towardsRight = pill.frame.midX >= person.avatar.midX
        return Tree(
            personId: person.refId, targetId: pill.refId, side: person.side,
            from: CGPoint(x: towardsRight ? person.avatar.maxX : person.avatar.minX, y: person.avatar.midY),
            to: CGPoint(x: towardsRight ? pill.frame.minX : pill.frame.maxX, y: pill.frame.midY),
            isActive: pill.isActive)
    }

    /// A pill's line to its project, between their facing ends.
    static func edge(pill: Node, end: Node) -> Edge {
        let towardsRight = pill.frame.midX < end.frame.midX
        return Edge(
            sessionId: pill.refId, targetId: end.refId, side: pill.side,
            from: towardsRight ? pill.rightAnchor : pill.leftAnchor,
            to: towardsRight ? end.leftAnchor : end.rightAnchor, isActive: pill.isActive)
    }

    /// The pin-space height of an overlap arc's lane: each arc peaks in its own lane of the band above the pills.
    static func lanePeak(_ lane: Int) -> CGFloat { 8 + CGFloat(lane) * overlapStep }

    /// The arc between two pills on one task; `peak` is its lane, in the space the frames are in.
    static func overlap(taskId: String, a: Node, b: Node, lane: Int, peak: CGFloat) -> Overlap {
        let (left, right) = a.frame.minX <= b.frame.minX ? (a, b) : (b, a)
        if left.frame.maxX < right.frame.minX {
            let from = left.rightAnchor, to = right.leftAnchor
            let control = controlHeight(from: from.y, to: to.y, peak: peak)
            let reach = min(150, (to.x - from.x) / 3)
            return Overlap(
                taskId: taskId, sessionIds: [a.refId, b.refId], from: from, to: to,
                control1: CGPoint(x: from.x + reach, y: control), control2: CGPoint(x: to.x - reach, y: control), lane: lane)
        }
        // The same column: a bracket in the lane toward the centre.
        let inward: CGFloat = left.side == .left ? 1 : -1
        let x = left.side == .left ? max(left.frame.maxX, right.frame.maxX) : min(left.frame.minX, right.frame.minX)
        let from = CGPoint(x: x, y: left.frame.midY), to = CGPoint(x: x, y: right.frame.midY)
        return Overlap(
            taskId: taskId, sessionIds: [a.refId, b.refId], from: from, to: to,
            control1: CGPoint(x: x + inward * 44, y: from.y), control2: CGPoint(x: x + inward * 44, y: to.y), lane: lane)
    }

    /// The pills that go with `movers` (pin keys) in a drag: a moving person's pills that are not
    /// pinned, as a pinned person takes them along in `layout`.
    func followers(of movers: Set<String>, pins: LiveCanvasPositions) -> Set<String> {
        Set(
            trees.filter { movers.contains(LiveCanvasPositions.personKey($0.personId)) }
                .map { LiveCanvasPositions.sessionKey($0.targetId) }
                .filter { !pins.contains($0) && !movers.contains($0) })
    }

    /// Every line with no end on a node in `movers` (pin keys): what stays still under a drag.
    func lines(excluding movers: Set<String>) -> Lines {
        guard !movers.isEmpty else { return Lines(trees: trees, edges: edges, overlaps: overlaps) }
        return Lines(
            trees: trees.filter { !Self.touches($0, movers) }, edges: edges.filter { !Self.touches($0, movers) },
            overlaps: overlaps.filter { !Self.touches($0, movers) })
    }

    /// The lines a drag bends: every line with an end on a moving node, drawn from where
    /// `centres` (pin key to pin-space centre) has taken those nodes. The rest of the canvas stays
    /// as laid out until the drop lays it out again, so a pointer move costs these lines alone.
    func lines(moving centres: [String: CGPoint]) -> Lines {
        guard !centres.isEmpty else { return Lines() }
        let movers = Set(centres.keys)
        let byKey = Dictionary(nodes.map { ($0.pinKey, $0) }, uniquingKeysWith: { first, _ in first })
        func node(_ key: String) -> Node? {
            guard var node = byKey[key] else { return nil }
            if let centre = centres[key] {
                let point = drawnPoint(forPin: centre)
                node.frame.origin = CGPoint(x: point.x - node.frame.width / 2, y: point.y - node.frame.height / 2)
            }
            return node
        }
        var lines = Lines()
        for tree in trees where Self.touches(tree, movers) {
            guard let person = node(LiveCanvasPositions.personKey(tree.personId)),
                let pill = node(LiveCanvasPositions.sessionKey(tree.targetId))
            else { continue }
            lines.trees.append(Self.tree(person: person, pill: pill))
        }
        for edge in edges where Self.touches(edge, movers) {
            guard let pill = node(LiveCanvasPositions.sessionKey(edge.sessionId)),
                let end = node(LiveCanvasPositions.hubKey(edge.targetId))
            else { continue }
            lines.edges.append(Self.edge(pill: pill, end: end))
        }
        for arc in overlaps where Self.touches(arc, movers) {
            guard arc.sessionIds.count == 2, let a = node(LiveCanvasPositions.sessionKey(arc.sessionIds[0])),
                let b = node(LiveCanvasPositions.sessionKey(arc.sessionIds[1]))
            else { continue }
            lines.overlaps.append(Self.overlap(taskId: arc.taskId, a: a, b: b, lane: arc.lane, peak: Self.lanePeak(arc.lane) - origin.y))
        }
        return lines
    }

    private static func touches(_ tree: Tree, _ movers: Set<String>) -> Bool {
        movers.contains(LiveCanvasPositions.personKey(tree.personId)) || movers.contains(LiveCanvasPositions.sessionKey(tree.targetId))
    }

    private static func touches(_ edge: Edge, _ movers: Set<String>) -> Bool {
        movers.contains(LiveCanvasPositions.sessionKey(edge.sessionId)) || movers.contains(LiveCanvasPositions.hubKey(edge.targetId))
    }

    private static func touches(_ arc: Overlap, _ movers: Set<String>) -> Bool {
        arc.sessionIds.contains { movers.contains(LiveCanvasPositions.sessionKey($0)) }
    }

    /// The height of both control points of an overlap arc whose ends are at `from` and `to`
    /// (y, down), so that it peaks at `peak` in the middle, as the arcs of the automatic layout
    /// do (a lane of the band above the pills). Ends at different heights make the curve dip
    /// past that lane (a pill dragged far down put the top of the arc about 8% of the drop above
    /// the layout, and the canvas grew upward to hold it), so the controls go no higher than keeps
    /// the curve at or below the lane, or below its higher end when that is above the lane: it
    /// never rises above the topmost end by more than the lane stood above it.
    static func controlHeight(from: CGFloat, to: CGFloat, peak: CGFloat) -> CGFloat {
        let lane = (8 * peak - (from + to)) / 6
        let floor = min(peak, from, to)
        // y(t) = from*u^3 + to*t^3 + 3*u*t*c, linear in c: c must be at least this at every t.
        var lowest = lane
        for step in 1..<1024 {
            let t = CGFloat(step) / 1024, u = 1 - t
            lowest = max(lowest, (floor - from * u * u * u - to * t * t * t) / (3 * u * t))
        }
        return lowest
    }

    /// The canvas in pin space: the automatic layout (`width` wide, `bottom` plus the margin tall)
    /// united with each rect in `reaching`, which brings `margin` of room with it on the side it
    /// reaches past, and with `floor` as it is. A rect inside the automatic layout changes
    /// nothing, except below `bottom`, which always has its margin.
    static func canvasBounds(width: CGFloat, bottom: CGFloat, reaching: [CGRect], floor: CGRect? = nil) -> CGRect {
        var minX: CGFloat = 0, minY: CGFloat = 0, maxX = width, maxY = bottom + margin
        for rect in reaching {
            if rect.minX < 0 { minX = min(minX, rect.minX - margin) }
            if rect.minY < 0 { minY = min(minY, rect.minY - margin) }
            if rect.maxX > width { maxX = max(maxX, rect.maxX + margin) }
            maxY = max(maxY, rect.maxY + margin)
        }
        if let floor {
            minX = min(minX, floor.minX)
            minY = min(minY, floor.minY)
            maxX = max(maxX, floor.maxX)
            maxY = max(maxY, floor.maxY)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Pieces

    /// The projects the drawn agents are linked to, most agents first, for the
    /// centre. Never a project the server keeps for itself (`systemProjectIds`).
    static func hubList(rows: [LiveThreadsModel.Row], systemProjectIds: Set<String>) -> [(id: String, name: String, agents: Int)] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for row in rows {
            var seen = Set<String>()
            for project in row.projects
            where !systemProjectIds.contains(project.id) && seen.insert(project.id).inserted {
                names[project.id] = project.name
                counts[project.id, default: 0] += 1
            }
        }
        return counts.map { (id: $0.key, name: names[$0.key] ?? "", agents: $0.value) }
            .sorted { a, b in
                if a.agents != b.agents { return a.agents > b.agents }
                return (a.name, a.id) < (b.name, b.id)
            }
            .prefix(maxHubs).map { $0 }
    }

    /// Which hub a row is on: its first project among the hubs.
    private static func hubId(for row: LiveThreadsModel.Row, hubs: [(id: String, name: String, agents: Int)]) -> String? {
        let ids = Set(hubs.map(\.id))
        return row.projects.first { ids.contains($0.id) }?.id
    }

    private struct OverlapPlan {
        let taskId: String
        let sessionIds: [String]
    }

    /// Different people on one task, among the pills
    /// drawn: the first two people (in person-id order) are joined, by their first
    /// pill on it. At most `maxOverlaps`, in the order tasks are first met.
    private static func plannedOverlaps(ids: [String], shown: [[LiveThreadsModel.Row]]) -> [OverlapPlan] {
        var order: [String] = []
        var byTask: [String: [(owner: String, row: String)]] = [:]
        for (index, id) in ids.enumerated() {
            for row in shown[index] {
                for task in row.tasks {
                    guard !(byTask[task.id] ?? []).contains(where: { $0.owner == id }) else { continue }
                    if byTask[task.id] == nil { order.append(task.id) }
                    byTask[task.id, default: []].append((id, row.id))
                }
            }
        }
        return order.compactMap { id in
            guard let people = byTask[id], people.count >= 2 else { return nil }
            return OverlapPlan(taskId: id, sessionIds: [people[0].row, people[1].row])
        }.prefix(maxOverlaps).map { $0 }
    }
}

/// Where the viewport looks on the canvas: a zoom and the point of the
/// viewport the canvas's top-left lands on. The arithmetic of pinch, scroll
/// and the +, - and fit buttons, kept out of the view so it can be tested and
/// so every input clamps the same way.
struct LiveCanvasCamera: Equatable {
    /// The lowest zoom, unless the viewport is narrower than the canvas by more
    /// than this: see `minZoom`.
    static let minScale: CGFloat = 0.4
    /// The lowest zoom of all, however wide the canvas: a canvas at the pin bounds
    /// (`LiveCanvasPositions.maxFraction`) is about 13,000pt wide, which this fits in a 650pt
    /// viewport. Under it a node would be too small to find and the line layers too big to draw.
    static let hardMinScale: CGFloat = 0.05
    static let maxScale: CGFloat = 2.5
    /// One press of + or -.
    static let step: CGFloat = 1.25
    /// The one rule on panning (no invisible walls): the canvas may be dragged well
    /// past its edges, but at least this much of it (of each side, so of its width and of its
    /// height) stays inside the viewport, so it is never lost off screen. A canvas smaller than
    /// this keeps all of itself in view.
    static let keepVisible: CGFloat = 80

    var scale: CGFloat = 1
    /// Viewport coordinates of the canvas's top-left corner.
    var offset: CGPoint = .zero
    /// The lowest zoom this camera allows: `minScale`, or the fit when the fit
    /// is lower (a canvas wider than its viewport), so fit, zoom out and the
    /// fit button all reach the whole width. `clamped` keeps it current for the
    /// viewport the camera is in.
    var minZoom: CGFloat = LiveCanvasCamera.minScale
    /// The camera shows the canvas at the viewport's width (`isFitWidth`), however far it is
    /// scrolled down. Set by `fit` and `clamped`, so a camera that has been moved always knows
    /// whether it was following the fit in the viewport it was moved in, which a later resize or
    /// a return from a thread no longer shows. `resized` then keeps it at the width.
    var followsFit = false
    /// The pin-space point of the canvas corner `offset` is measured from
    /// (`LiveCanvasLayout.origin` when the camera was set). The corner moves when a node is put
    /// left of or above the layout, so a camera kept above the board, or set before the pins
    /// were read, says which corner its offset belongs to and `rebased(to:)` moves it to the
    /// corner it is opened against: the view comes back where it was left.
    var origin: CGPoint = .zero

    /// The lowest zoom for a viewport: `minScale`, or the fit when that is lower, never under
    /// `hardMinScale`.
    static func minZoom(content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, viewport.width > 0 else { return minScale }
        return max(hardMinScale, min(minScale, viewport.width / content.width))
    }

    /// The whole canvas at the viewport's width, at its top: the Fit button. The layout is built
    /// for the width it gets, so with nothing outside it that is 1:1 (centred when the window is
    /// wider than `LiveCanvasLayout.maxWidth`), or, in a viewport narrower than
    /// `LiveCanvasLayout.minWidth`, the 720pt layout scaled down to it. A canvas grown by a node
    /// put outside the layout is fitted whole; `home` is what a first look shows.
    static func fit(content: CGSize, viewport: CGSize, origin: CGPoint = .zero) -> LiveCanvasCamera {
        guard content.width > 0, viewport.width > 0 else { return LiveCanvasCamera(origin: origin) }
        let floor = minZoom(content: content, viewport: viewport)
        let scale = min(max(viewport.width / content.width, floor), 1)
        return LiveCanvasCamera(
            scale: scale, offset: CGPoint(x: (viewport.width - content.width * scale) / 2, y: 0), minZoom: floor, followsFit: true,
            origin: origin)
    }

    /// The opening view: the automatic layout (pin-space x 0...`baseWidth`, y from 0) at the
    /// viewport's width, its top at the top of the viewport, wherever the canvas around it has
    /// grown to. With nothing outside the layout this is `fit`. A node put outside it stays
    /// reachable by panning and by Fit, which shows the whole canvas.
    static func home(content: CGSize, viewport: CGSize, origin: CGPoint, baseWidth: CGFloat) -> LiveCanvasCamera {
        guard content.width > 0, viewport.width > 0, baseWidth > 0 else { return fit(content: content, viewport: viewport, origin: origin) }
        let floor = minZoom(content: content, viewport: viewport)
        let scale = min(max(viewport.width / baseWidth, floor), 1)
        return LiveCanvasCamera(
            scale: scale,
            offset: CGPoint(x: (viewport.width - baseWidth * scale) / 2 + origin.x * scale, y: origin.y * scale),
            minZoom: floor, origin: origin
        ).clamped(content: content, viewport: viewport)
    }

    /// Whether this camera shows the canvas at the viewport's width: the fit's zoom and its
    /// horizontal place. Where it sits vertically does not matter, so a canvas read by scrolling
    /// down it is still at the fit.
    func isFitWidth(content: CGSize, viewport: CGSize) -> Bool {
        let fit = Self.fit(content: content, viewport: viewport)
        return abs(scale - fit.scale) < 0.001 && abs(offset.x - fit.offset.x) < 0.5
    }

    /// This camera for a new viewport or a new canvas. One that follows the fit moves to the new
    /// fit width and keeps looking at the same height of the canvas (the vertical offset scales
    /// with the zoom), so a window made wider or narrower while the person reads down a tall
    /// canvas neither leaves the old zoom behind nor throws away where they were. Any other
    /// camera is the person's own choice and is only kept reachable.
    func resized(content: CGSize, viewport: CGSize) -> LiveCanvasCamera {
        guard followsFit else { return clamped(content: content, viewport: viewport) }
        let fit = Self.fit(content: content, viewport: viewport, origin: origin)
        let y = scale > 0 ? offset.y * fit.scale / scale : 0
        return LiveCanvasCamera(scale: fit.scale, offset: CGPoint(x: fit.offset.x, y: y), minZoom: fit.minZoom, followsFit: true, origin: origin)
            .clamped(content: content, viewport: viewport)
    }

    /// What to keep above the board for a return from a thread: nothing at the opening view (a
    /// first look needs no memory, and it opens afresh; with nothing outside the layout that is
    /// the exact fit), the camera otherwise. `baseWidth` is the layout's, `content.width` by
    /// default. The whole canvas fitted while nodes stand outside the layout is the person's own
    /// view and is kept, so they come back to it.
    func kept(content: CGSize, viewport: CGSize, baseWidth: CGFloat? = nil) -> LiveCanvasCamera? {
        let home = Self.home(content: content, viewport: viewport, origin: origin, baseWidth: baseWidth ?? content.width)
        return self == home ? nil : self
    }

    /// Where the viewport opens: where the person left it (`saved`, kept above the
    /// board by `LiveThreadsStore` so a thread opened and closed again does not
    /// throw the zoom away), moved to the canvas corner `origin` it opens against and kept
    /// reachable in this window's size; the opening view when there is none.
    static func opening(
        saved: LiveCanvasCamera?, content: CGSize, viewport: CGSize, origin: CGPoint = .zero, baseWidth: CGFloat? = nil
    ) -> LiveCanvasCamera {
        if let saved { return saved.rebased(to: origin).resized(content: content, viewport: viewport) }
        return home(content: content, viewport: viewport, origin: origin, baseWidth: baseWidth ?? content.width)
    }

    /// The card's width for `space` points of window: all of it, so the card grows with the window
    /// while the canvas inside stays at its fit. The canvas's own width until the
    /// space is measured. Its height is whatever the page has left (`LiveCanvasViewport`).
    static func cardWidth(content: CGSize, space: CGFloat) -> CGFloat {
        space > 0 ? space : content.width
    }

    var percent: Int { Int((scale * 100).rounded()) }
    var canZoomIn: Bool { scale < Self.maxScale - 0.001 }
    var canZoomOut: Bool { scale > minZoom + 0.001 }

    /// The canvas point under `anchor` (a viewport point) stays under it.
    func zoomed(to target: CGFloat, around anchor: CGPoint) -> LiveCanvasCamera {
        let next = min(max(target, minZoom), Self.maxScale)
        let ratio = next / scale
        return LiveCanvasCamera(
            scale: next, offset: CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio, y: anchor.y - (anchor.y - offset.y) * ratio),
            minZoom: minZoom, origin: origin)
    }

    func panned(by delta: CGSize) -> LiveCanvasCamera {
        LiveCanvasCamera(
            scale: scale, offset: CGPoint(x: offset.x + delta.width, y: offset.y + delta.height), minZoom: minZoom, origin: origin)
    }

    /// The same view of the canvas after its drawn corner moved from the pin-space point `old`
    /// to `new` (a node was dropped left of or above the old corner, or the canvas shrank back):
    /// every canvas point stays under the same viewport point, so nothing on screen jumps.
    func rebased(from old: CGPoint, to new: CGPoint) -> LiveCanvasCamera {
        guard old != new else { return self }
        var result = self
        result.offset = CGPoint(x: offset.x + (new.x - old.x) * scale, y: offset.y + (new.y - old.y) * scale)
        result.origin = new
        return result
    }

    /// This camera for the corner `new`, from the corner it records.
    func rebased(to new: CGPoint) -> LiveCanvasCamera { rebased(from: origin, to: new) }

    /// Keeps the canvas reachable: free to go past its edges, as long as `keepVisible` of it
    /// stays inside the viewport. Also puts the zoom floor and the zoom in range for this viewport.
    func clamped(content: CGSize, viewport: CGSize) -> LiveCanvasCamera {
        let floor = Self.minZoom(content: content, viewport: viewport)
        let scale = min(max(scale, floor), Self.maxScale)
        func limit(_ offset: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
            let size = content * scale
            let keep = min(Self.keepVisible, size, viewport)
            return min(max(offset, keep - size), viewport - keep)
        }
        var result = LiveCanvasCamera(
            scale: scale,
            offset: CGPoint(
                x: limit(offset.x, content: content.width, viewport: viewport.width),
                y: limit(offset.y, content: content.height, viewport: viewport.height)),
            minZoom: floor, origin: origin)
        result.followsFit = result.isFitWidth(content: content, viewport: viewport)
        return result
    }
}

/// The Live canvas's box selection: which cards the person has picked, as pin
/// keys (`LiveCanvasLayout.Node.pinKey`), and the rules for picking, moving and putting back a
/// group of them. View state only, never saved. Pure, so the rules run in unit tests; the view
/// holds the set.
enum LiveCanvasSelection {
    /// The box a drag from `start` to `end` draws, whichever way it was dragged.
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// The cards whose frame the box touches (an edge counts, and so does a box with no height or
    /// width, which a straight drag makes). Both are in the canvas's drawn coordinates.
    static func keys(in box: CGRect, nodes: [LiveCanvasLayout.Node]) -> Set<String> {
        Set(
            nodes.filter {
                $0.frame.minX <= box.maxX && $0.frame.maxX >= box.minX && $0.frame.minY <= box.maxY && $0.frame.maxY >= box.minY
            }.map(\.pinKey))
    }

    /// The selection after a box took in `hit`: Shift adds them to `current`, otherwise they
    /// replace it.
    static func boxed(_ hit: Set<String>, into current: Set<String>, isAdditive: Bool) -> Set<String> {
        isAdditive ? current.union(hit) : hit
    }

    /// Shift-click on a card: out if it is in, in if it is not.
    static func toggled(_ key: String, in selection: Set<String>) -> Set<String> {
        var result = selection
        if result.remove(key) == nil { result.insert(key) }
        return result
    }

    /// A selection keeps only the cards still on the canvas.
    static func present(_ selection: Set<String>, nodes: [LiveCanvasLayout.Node]) -> Set<String> {
        selection.intersection(nodes.map(\.pinKey))
    }

    /// The cards a drag that began on `key` moves: the whole selection when it began on a
    /// selected card; otherwise that card alone, or with the selection when `isAdditive` (Shift).
    static func movers(dragging key: String, selection: Set<String>, isAdditive: Bool = false) -> Set<String> {
        if selection.contains(key) { return selection }
        return isAdditive ? selection.union([key]) : [key]
    }

    /// The offset a group may move by: `translation`, held so that no card, wherever it began
    /// (`origins`, pin space), ends past the pin bounds (`LiveCanvasPositions.maxFraction` of
    /// `baseWidth` across, `maxY` down). One offset for the group, so the card that reaches a bound
    /// first stops them all and they keep their spacing; clamping each card alone would bunch the
    /// others up against the bound.
    static func groupOffset(_ translation: CGSize, origins: [CGPoint], baseWidth: CGFloat) -> CGSize {
        func held(_ offset: CGFloat, along values: [CGFloat], limit: CGFloat) -> CGFloat {
            guard let low = values.min(), let high = values.max() else { return offset }
            let floor = -limit - low, ceiling = limit - high
            return floor <= ceiling ? min(max(offset, floor), ceiling) : offset
        }
        return CGSize(
            width: held(
                translation.width, along: origins.map(\.x), limit: CGFloat(LiveCanvasPositions.maxFraction) * max(baseWidth, 1)),
            height: held(translation.height, along: origins.map(\.y), limit: CGFloat(LiveCanvasPositions.maxY)))
    }

    /// The cards "Put Back" sets down from the menu of `key`: every selected card that is pinned
    /// when `key` is selected, otherwise `key` itself if it is.
    static func putBackKeys(for key: String, selection: Set<String>, isPinned: (String) -> Bool) -> [String] {
        movers(dragging: key, selection: selection).filter(isPinned).sorted()
    }
}
