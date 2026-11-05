import SwiftUI

/// The Tasks tab's Live list: everyone's agent sessions, a section
/// per person, the most recent first. The list does not animate — the projects
/// workspace's rule — so its age marks are static and a poll only swaps text. The
/// canvas is the exception: the lines of an active agent flow (`LiveCanvasView`),
/// and it stands still under Reduce Motion.
struct LiveThreadsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let live: LiveThreadsStore
    let actions: ProjectsActions
    let search: String
    /// Projects the server keeps for itself: never a hub on the canvas.
    var systemProjectIds: Set<String> = []
    /// Canvas or list, remembered. The canvas draws whenever it is offered (`canvasOffered`), at any width.
    @AppStorage("hq.live.display") private var display: LiveDisplay = .canvas

    /// Everyone who could have agents, so the canvas can show who has none.
    private var roster: [LiveThreadsModel.Idle] {
        store.people.values.filter { $0.kind == "person" && !$0.isRemoved }.map { .init(id: $0.id, name: $0.name) }
    }

    var body: some View {
        let model = LiveThreadsModel(
            threads: live.threads, now: live.now, search: search,
            isRemoved: { store.people[$0]?.isRemoved == true }, roster: roster)
        GeometryReader { geometry in
            // The stage keeps the page's gutter, less when that would leave it under the canvas's
            // minimum (so a window just over it stays 1:1). Under `LiveCanvasLayout.minWidth` the
            // canvas is laid out at that width and shown scaled down to the space.
            let inset = LiveCanvasLayout.stageInset(windowWidth: geometry.size.width, gutter: Tokens.Projects.liveGutter)
            let canvasWidth = max(0, geometry.size.width - 2 * inset)
            let offered = canvasOffered
            let wantsCanvas = offered && display == .canvas && model.total > 0
            VStack(spacing: 0) {
                HStack(spacing: Tokens.Space.x2) {
                    if wantsCanvas {
                        activeLine(LiveCanvasLayout.activeCount(model: model, now: live.now))
                    } else {
                        countLine(model)
                    }
                    Spacer(minLength: 0)
                    if offered {
                        LiveDisplayPicker(display: display) { chosen in
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { display = chosen }
                        }
                    }
                }
                .padding(.horizontal, Tokens.Projects.liveGutter).padding(.bottom, Tokens.Space.x2)
                if wantsCanvas {
                    canvas(model, width: canvasWidth, inset: inset)
                } else {
                    list(model)
                }
            }
        }
        .task { if live.isStale { await live.refresh(client: store.client) } }
        .background(VisiblePoll(key: "live-threads") { await live.refresh(client: store.client) })
        .background(VisiblePoll(key: "live-ages", interval: .seconds(60)) { live.tick() })
    }

    /// The canvas's header: "5 agents active now", counting the pills it draws
    /// (the list keeps its three hours).
    private func activeLine(_ count: Int) -> some View {
        Text(count == 1 ? "1 agent active now" : "\(count) agents active now").font(Tokens.Projects.listTitle)
            .accessibilityElement(children: .combine)
    }

    /// "12 agents" and the window they are counted in: the last three hours.
    private func countLine(_ model: LiveThreadsModel) -> some View {
        HStack(spacing: Tokens.Space.x2) {
            Text(model.total == 1 ? "1 agent" : "\(model.total) agents").font(Tokens.Projects.listTitle)
            Text("in the last 3 hours").font(Tokens.Projects.quiet).foregroundStyle(Tokens.Palette.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Whether the Canvas | List choice exists at all, at any width: not under
    /// VoiceOver (the canvas is a picture; the list is the accessible form) and
    /// not on the iPhone.
    private var canvasOffered: Bool {
        var isPhone = false
        #if os(iOS)
            isPhone = UIDevice.current.userInterfaceIdiom == .phone
        #endif
        return LiveCanvasLayout.isOffered(voiceOver: voiceOver, isPhone: isPhone)
    }

    /// No page scroll view around the canvas: the failure line and the selection header take
    /// their own height and the card the rest (`LiveCanvasViewport`), so its zoom controls are
    /// always on screen. The canvas scrolls inside the card, and `VisiblePoll` reads the hub.
    private func canvas(_ model: LiveThreadsModel, width: CGFloat, inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            failureLine(model, inset: true)
            LiveCanvasView(
                model: model, width: width, space: width, systemProjectIds: systemProjectIds, now: live.now,
                hub: HQConfig.baseURLString, personID: store.me?.id ?? "",
                open: { actions.open(.thread($0)) },
                camera: Binding(get: { live.canvasCamera }, set: { live.canvasCamera = $0 })
            )
            .padding(.horizontal, inset).padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func list(_ model: LiveThreadsModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                failureLine(model, inset: false)
                if model.total == 0, !model.groups.isEmpty, search.isEmpty {
                    Text("No agents in the last 3 hours").font(Tokens.Projects.quiet).foregroundStyle(Tokens.Palette.inkTertiary)
                        .padding(.vertical, Tokens.Space.x3)
                }
                ForEach(model.groups) { group in
                    Section {
                        ForEach(model.items(group, expanded: live.expanded)) { item in
                            line(item)
                        }
                    } header: {
                        header(group)
                    }
                }
                emptyState(model)
            }
            .padding(.horizontal, Tokens.Projects.liveGutter)
        }
        .refreshable { await live.refresh(client: store.client) }
    }

    /// The list sits in the gutter already; the canvas spans the full width.
    @ViewBuilder private func failureLine(_ model: LiveThreadsModel, inset: Bool) -> some View {
        if !model.groups.isEmpty, let failure = live.failure {
            Text(failure).font(Tokens.Projects.quiet).foregroundStyle(Tokens.Palette.inkTertiary)
                .padding(.vertical, Tokens.Space.x3).padding(.horizontal, inset ? Tokens.Projects.liveGutter : 0)
        }
    }

    // MARK: Lines

    @ViewBuilder private func line(_ item: LiveThreadsModel.Item) -> some View {
        switch item {
        case .row(let row):
            LiveRowView(row: row, open: { actions.open(.thread(row.id)) }, copy: {
                ProjectsPasteboard.copy(CodingThreadLink.url(row.id))
                actions.toast("Thread link copied")
            })
        case .more(let key, let count):
            foldButton("+\(count) more", key: key)
        case .folded(let key, let count):
            foldButton("+\(count) more with no name or task", key: key)
        case .earlier(let key, let count):
            foldButton("+\(count) earlier", key: key)
        }
    }

    private func foldButton(_ text: String, key: String) -> some View {
        Button { live.expand(key) } label: {
            HStack(spacing: Tokens.Space.x3) {
                Color.clear.frame(width: Tokens.Projects.liveDot, height: Tokens.Projects.liveDot)
                Text(text).font(Tokens.Projects.quiet).foregroundStyle(Tokens.Palette.inkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Tokens.Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .projectsPhoneTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint("Shows them")
    }

    private func header(_ group: LiveThreadsModel.Group) -> some View {
        HStack(spacing: Tokens.Space.x2) {
            AvatarView(name: group.name, isGroup: false, size: Tokens.Projects.cardFace, person: store.people[group.id])
            Text(group.name).font(Tokens.Projects.listTitle)
            Text(group.hasLive ? (group.agentCount == 1 ? "1 agent" : "\(group.agentCount) agents") : "No agents in the last 3 hours")
                .font(Tokens.Projects.cardMeta).foregroundStyle(Tokens.Palette.inkSecondary)
            Spacer(minLength: 0)
        }
        .padding(.top, Tokens.Space.x4).padding(.bottom, Tokens.Space.x1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func emptyState(_ model: LiveThreadsModel) -> some View {
        if model.groups.isEmpty {
            if let failure = live.failure {
                ContentUnavailableView {
                    Label("Agents unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Retry") { Task { await live.refresh(client: store.client) } }
                }
            } else if !live.hasLoaded {
                ProgressView("Loading agents").padding(Tokens.Space.x6)
                    .frame(maxWidth: .infinity)
            } else if search.isEmpty {
                ContentUnavailableView(
                    "No agents in the last 3 hours", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Agent sessions with activity in the last 3 hours appear here. Older ones from the last day fold under each person."))
            } else {
                ContentUnavailableView("No matching agents", systemImage: "magnifyingglass")
            }
        }
    }
}

/// One session: its age mark, its name, the task it belongs to and how long
/// since it did anything.
private struct LiveRowView: View {
    let row: LiveThreadsModel.Row
    let open: () -> Void
    let copy: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Tokens.Space.x3) {
                LiveAgeMark(age: row.age).padding(.top, Tokens.Space.x1)
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    Text(row.name)
                        .font(Tokens.Projects.cardTitle)
                        .italic(row.isFallbackName)
                        .foregroundStyle(row.isFallbackName ? Tokens.Palette.inkSecondary : Tokens.Palette.ink)
                        .lineLimit(1)
                    if let also = row.alsoText {
                        Label(also, systemImage: "person.2")
                            .font(Tokens.Projects.cardMeta)
                            .foregroundStyle(Tokens.Palette.warning)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Tokens.Space.x2)
                if let label = row.labelText {
                    Text(label)
                        .font(Tokens.Projects.cardRef)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .lineLimit(1)
                }
                Text(row.ageText)
                    .font(Tokens.Projects.cardMeta).monospacedDigit()
                    .foregroundStyle(Tokens.Palette.inkTertiary)
                    .frame(minWidth: Tokens.Space.x6 + Tokens.Space.x3, alignment: .trailing)
            }
            .padding(.vertical, Tokens.Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .projectsPhoneTarget()
        }
        .buttonStyle(.plain)
        .help(row.fullName)
        .contextMenu {
            Button("Copy thread link", systemImage: "link", action: copy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
        .accessibilityAddTraits(.isButton)
    }
}

/// Filled under 10 minutes, a ring under 60, a dashed dimmer ring after.
/// Read from the clock alone: presence is unreliable, and nothing pulses.
struct LiveAgeMark: View {
    let age: LiveThreadsModel.Age

    var body: some View {
        Group {
            switch age {
            case .fresh:
                Circle().fill(Tokens.Palette.live)
            case .recent:
                Circle().strokeBorder(Tokens.Palette.live, lineWidth: Tokens.Projects.liveRing)
            case .stale:
                Circle()
                    .strokeBorder(
                        Tokens.Palette.inkTertiary,
                        style: StrokeStyle(lineWidth: Tokens.Projects.liveRing, dash: Tokens.Projects.liveDash)
                    )
                    .opacity(Tokens.Projects.backlogOpacity)
            }
        }
        .frame(width: Tokens.Projects.liveDot, height: Tokens.Projects.liveDot)
        .accessibilityHidden(true)
    }
}
