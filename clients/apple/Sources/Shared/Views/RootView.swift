import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var isComposing = false
    @State private var callStripHeight: CGFloat = 0
    // Two remembered numbers own the sidebar: whether it was left railed, and
    // the list width it was left at. Everything else — the settle pass, the
    // details toggle, the system toggle — only writes these and re-asserts
    // them, so nothing can disagree about which state the sidebar is in.
    @AppStorage("sidebarIsRail", store: PresentationDefaults.current) private var isRail = false
    @AppStorage("sidebarListWidth", store: PresentationDefaults.current) private var listWidth = Double(SidebarMetrics.listDefault)
    @State private var settleTask: Task<Void, Never>?
    @State private var isMovingDivider = false
    @State private var dividerMoveTask: Task<Void, Never>?
    @State private var typingMonitor: Any?
    @State private var sidebarSession = SidebarLayoutSession()
    @State private var titlebarInstallTask: Task<Void, Never>?
    @State private var sidebarWasRailBeforeDetails: Bool?
    @State private var homePreferences = HomePreferences(hub: "", personID: "", defaults: nil)
    @State private var searchFocusRequested = false
    /// The pages that read their own data, kept above the destination switch.
    @State private var pages = PageMemory()

    private func configureWindowChrome() {
        titlebarInstallTask?.cancel()
        titlebarInstallTask = Task { @MainActor in
            for _ in 0..<10 {
                guard !Task.isCancelled else { return }
                if let window = Self.mainWindow() {
                    window.styleMask.insert(.fullSizeContentView)
                    window.titlebarAppearsTransparent = true
                    window.titlebarSeparatorStyle = .none
                    window.titleVisibility = .hidden
                    window.title = "HQ"
                    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                        window.standardWindowButton(kind)?.isHidden = true
                    }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.phase == .ready {
                ActiveCallBanner()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { callStripHeight = $0 }
            }
            appContent
                .overlay(alignment: .topLeading) {
                    // Window controls belong to the shell, not a replaceable page header.
                    WindowControls().frame(width: 90, height: 40).padding(.top, 8)
                }
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 860, minHeight: 560)
        .environment(homePreferences)
        .environment(\.toggleConversationDetails, { toggleDetails() })
        .toolbar(.hidden, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .focusedSceneValue(\.hqShell, shellActions)
        .overlay(alignment: .topTrailing) {
            if store.phase == .ready, store.selectedConversationId != nil {
                DetailPanelToggle(onToggleConversation: { toggleDetails() })
                    .frame(width: 220, height: Tokens.Home.desktopHeaderHeight)
                    .padding(.top, callStripHeight)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task { configureWindowChrome() }
        .onDisappear { titlebarInstallTask?.cancel() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
            // Window resizing must not become a remembered sidebar drag.
            if isSidebarMounted { setSidebarPosition(restingWidth) }
        }
        .task(id: store.me?.id) { loadHomePreferences() }
        .onChange(of: store.me?.id, initial: true) { _, personID in pages.keep(for: personID) }
        // A Find that never reached the field (the sidebar would not leave
        // the rail) must not steal focus when the field shows up later.
        .task(id: searchFocusRequested) {
            guard searchFocusRequested else { return }
            try? await Task.sleep(for: .seconds(1))
            searchFocusRequested = false
        }
    }

    private var sidebarPaneShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 28, style: .continuous).inset(by: 8)
    }

    @ViewBuilder private var appContent: some View {
        switch store.phase {
        case .enrolling:
            EnrollmentView()
        case .ready:
            HSplitView {
                SidebarView(
                    isComposing: $isComposing,
                    searchFocusRequested: $searchFocusRequested,
                    onWidthChange: { width in handleSidebarWidth(to: width) },
                    onToggleSidebar: { setSidebar(rail: !isRail) }
                )
                .frame(minWidth: SidebarMetrics.rail, idealWidth: restingWidth, maxWidth: SidebarMetrics.listMax)
                .clipShape(sidebarPaneShape)
                .hqGlass(in: sidebarPaneShape)
                .clipped()
                .ignoresSafeArea(.container, edges: .top)
                // Nothing a thread contains may move the furniture — see
                // `ColumnWidth`.
                ColumnWidth {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            switch store.destination {
                            case .conversation(let selectedId):
                                ChatView(conversationId: selectedId)
                            case .meetings:
                                MeetingsView()
                            case .tasks:
                                ProjectsWorkspace()
                            // A page held for someone else is a new page, so its
                            // reads start over under the person signed in now.
                            case .files:
                                FilesView(page: pages.files).id(ObjectIdentifier(pages.files))
                            case .settings:
                                SettingsView()
                            case .none:
                                ContentUnavailableView(
                                    "No Conversation Selected",
                                    systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Pick a conversation, or press ⌘N to start one.")
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                        // Reserve the panel width in the same update as its content.
                        Color.clear.frame(width: store.isDetailPanelOpen ? 321 : 0)
                    }
                    .overlay(alignment: .trailing) {
                        if let selectedId = store.selectedConversationId {
                            DesktopDetailPanel(isPresented: store.isDetailPanelOpen) {
                                ConversationDetailPanel(conversationId: selectedId)
                                    .id(selectedId)
                            }
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .ignoresSafeArea(.container, edges: .top)
            .id("hq-workspace")
            .onAppear {
                sidebarSession.begin()
                setSidebarPosition(restingWidth)
                installTypingMonitor()
            }
            .onDisappear {
                sidebarSession.end()
                settleTask?.cancel()
                dividerMoveTask?.cancel()
                isMovingDivider = false
                if let typingMonitor { NSEvent.removeMonitor(typingMonitor) }
                typingMonitor = nil
            }
            .sheet(isPresented: $isComposing) { NewConversationView() }
            .onChange(of: store.isDetailPanelOpen) { _, isOpen in
                let hasRoom = (Self.mainSplitView()?.bounds.width ?? 0) - restingWidth - 321 >= 360
                if isOpen {
                    sidebarWasRailBeforeDetails = isRail
                    if !hasRoom { isRail = true }
                } else if let wasRail = sidebarWasRailBeforeDetails {
                    isRail = wasRail
                    sidebarWasRailBeforeDetails = nil
                }
                setSidebarPosition(restingWidth)
            }
            // The panel is a conversation surface; leaving conversations
            // (Meetings, Settings, sign-out) takes it down with it.
            .onChange(of: store.selectedConversationId) { _, newValue in
                if newValue == nil { store.isDetailPanelOpen = false }
            }
        }
    }

    /// The menu bar's view of this window (`HQCommands`): ⌘N, ⌘F, ⌃⌘S and
    /// ⌘I all land on the same actions the sidebar and header buttons use.
    private var shellActions: HQShellActions {
        let isReady = store.phase == .ready
        return HQShellActions(
            canCompose: isReady,
            compose: { isComposing = true },
            canUseSidebar: isReady,
            findInSidebar: {
                if isRail { setSidebar(rail: false) }
                searchFocusRequested = true
            },
            toggleSidebar: { setSidebar(rail: !isRail) },
            canShowDetails: isReady && store.selectedConversationId != nil,
            detailsAreOpen: store.isDetailPanelOpen,
            toggleDetails: { toggleDetails() }
        )
    }

    private func toggleDetails() {
        guard store.selectedConversationId != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { store.isDetailPanelOpen.toggle() }
    }

    private func loadHomePreferences() {
        guard let personID = store.me?.id else { return }
        #if DEBUG
        if HQSimulatorFixture.isEnabled {
            homePreferences = HomePreferences(hub: HQConfig.baseURLString, personID: personID,
                defaults: nil, initialPins: HQSimulatorFixture.scenario == "pins"
                    ? Array(store.conversations.prefix(9).map(\.id)) : ["bo-dm", "scout-dm"])
            return
        }
        #endif
        homePreferences = HomePreferences(hub: HQConfig.baseURLString, personID: personID)
    }

    // Typing from any non-conversation page (Meetings, Settings, nothing
    // selected) belongs to the composer of the conversation you were last in:
    // jump there and carry the keystroke, the way Messages never eats a typed
    // character. The composer's own monitor covers the in-conversation case.
    private func installTypingMonitor() {
        guard typingMonitor == nil else { return }
        typingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if case .conversation = store.destination { return event }
            guard event.window?.identifier?.rawValue.hasPrefix("hq-meeting") != true,
                  event.window?.sheetParent == nil, event.window?.attachedSheet == nil,
                  event.specialKey == nil, event.keyCode != 53,
                  event.modifierFlags.intersection([.command, .control]).isEmpty,
                  let characters = event.characters, !characters.isEmpty,
                  TypingReclaim.isFree(event.window?.firstResponder, characters: characters),
                  let target = store.lastConversationId ?? store.conversations.first?.id
            else { return event }
            store.pendingComposerText = (store.pendingComposerText ?? "") + characters
            store.openConversation(target)
            return nil
        }
    }

    /// Remember the actual AppKit pane width in the same space as the divider.
    private var listRestingWidth: CGFloat {
        SidebarMetrics.listWidth(CGFloat(listWidth))
    }

    private var restingWidth: CGFloat {
        isRail ? SidebarMetrics.rail : listRestingWidth
    }

    private func handleSidebarWidth(to newWidth: CGFloat) {
        // Persist and restore the same AppKit column coordinate space.
        guard isSidebarMounted else { return }
        let width = Self.mainSplitView()?.arrangedSubviews.first?.frame.width ?? newWidth
        guard width >= SidebarMetrics.rail - 8 else { return }
        // Never decide mid-drag: fighting AppKit's divider tracking yanks the
        // column around under the cursor. Everything is decided once events go
        // quiet — on release, or once a move made from code has landed.
        scheduleSettle()
    }

    // The one decision point, and all it does is agree with the width already
    // on screen: under the threshold the sidebar IS the rail and re-pins to
    // its exact width; over it the list simply keeps the width the drag left
    // it at — and remembers it, so opening the details panel and closing it
    // again gives back the sidebar that was there, not a stock one.
    private var isSidebarMounted: Bool {
        sidebarSession.isActive && store.phase == .ready
    }

    private func scheduleSettle() {
        guard isSidebarMounted else { return }
        settleTask?.cancel()
        let generation = sidebarSession.generation
        settleTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, sidebarSession.accepts(generation), isSidebarMounted,
                  let split = Self.mainSplitView(),
                  let width = split.arrangedSubviews.first?.frame.width else { return }
            switch SidebarMetrics.settlement(
                width: width, availableWidth: split.bounds.width,
                hasDetails: store.isDetailPanelOpen,
                isDragging: NSEvent.pressedMouseButtons & 1 != 0,
                isMovingDivider: isMovingDivider
            ) {
            case .wait:
                scheduleSettle()
            case .ignore:
                break
            case .rail:
                isRail = true
                if abs(width - SidebarMetrics.rail) > 1 {
                    setSidebarPosition(SidebarMetrics.rail)
                }
            case .list(let width):
                isRail = false
                listWidth = Double(width)
            }
        }
    }

    private func setSidebar(rail: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isRail = rail
            // An explicit choice while details are open replaces the earlier
            // automatic restore target.
            if store.isDetailPanelOpen { sidebarWasRailBeforeDetails = rail }
            setSidebarPosition(rail ? SidebarMetrics.rail : listRestingWidth)
        }
    }

    // A single layout step avoids remeasuring the eager transcript every frame.
    // New intent cancels the previous move; a departed shell cannot move a
    // split view after its own divider has disappeared.
    private func setSidebarPosition(_ width: CGFloat) {
        guard isSidebarMounted else { return }
        settleTask?.cancel()
        dividerMoveTask?.cancel()
        isMovingDivider = true
        let generation = sidebarSession.generation
        dividerMoveTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, sidebarSession.accepts(generation), isSidebarMounted else { return }
            // A window resize asks for the resting width on every tick, and
            // the pane is usually already there: AppKit then has nothing to
            // move, so skip the setPosition and the layout pass it forces.
            // The cancel, the reset and the settle below still run, so a new
            // request still replaces the previous one. A split view with a
            // pending layout pass has a stale frame, so it is never skipped:
            // the pass would otherwise resize the sidebar after we read it.
            if let split = Self.mainSplitView() {
                let current = split.arrangedSubviews.first?.frame.width
                if split.needsLayout || (current.map({ abs($0 - width) > 0.5 }) ?? true) {
                    split.setPosition(width, ofDividerAt: 0)
                    split.layoutSubtreeIfNeeded()
                }
            }
            isMovingDivider = false
            scheduleSettle()
        }
    }

    /// HQ also runs a meeting window and sheets, and `NSApp.mainWindow` is
    /// whichever of them is in front — so the chat window is found by its
    /// scene id, the same way the menu bar finds it.
    @MainActor
    private static func mainWindow() -> NSWindow? {
        let windows = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }
        return windows.first { $0.identifier?.rawValue.hasPrefix("hq-main") == true }
            ?? windows.first { $0.identifier?.rawValue.hasPrefix("hq-meeting") != true }
    }

    #if DEBUG
    @MainActor
    static func setFixtureSidebarWidth(_ width: CGFloat) {
        guard HQSimulatorFixture.isEnabled else { return }
        mainSplitView()?.setPosition(width, ofDividerAt: 0)
    }
    #endif

    @MainActor
    private static func mainSplitView() -> NSSplitView? {
        guard let contentView = mainWindow()?.contentView else { return nil }
        return firstSplitView(in: contentView)
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let splitView = view as? NSSplitView { return splitView }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }
}

// A container that reports the width it was PROPOSED, never the width its
// content would like to have.
//
// Without it a single message can take the sidebar off the screen. A row of
// document cards is rigid — 200pt each, and a meeting drop pairs two — and
// that minimum travels up through the transcript's scroll view and becomes
// the detail column's minimum, at which point AppKit grows the WHOLE split
// view past the window to satisfy it: measured at 1110pt of split view inside
// a 900pt window for four cards, and the overflow comes off the sidebar's
// side. Content too wide for its column now overflows the column instead of
// moving the window's furniture.
struct ColumnWidth: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        // Both axes proposed: the answer is the proposal itself, so the
        // detail column's content is not measured at all (the HSplitView's
        // min/ideal/max probes would otherwise push the transcript through
        // widths nothing else uses).
        if let width = proposal.width, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(
            width: proposal.width ?? size.width,
            height: proposal.height ?? size.height
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

// The trailing header control that shows and hides the conversation's details.
private struct DetailPanelToggle: View {
    var onToggleConversation: (() -> Void)? = nil
    @Environment(AppStore.self) private var store

    private var isOpen: Bool { store.isDetailPanelOpen }
    private var isActive: Bool { store.selectedConversationId != nil }

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button {
                onToggleConversation?()
            } label: {
                toggleLabel
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Close details" : "Show details")
            .disabled(!isActive)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .accessibilityLabel(isOpen ? "Close details" : "Show details")
        }
        .padding(.trailing, 8)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    // Sized and shaped like a native macOS 26 toolbar button.
    @ViewBuilder
    private var toggleLabel: some View {
        let icon = Image(systemName: "sidebar.trailing")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        if #available(macOS 26.0, *) {
            icon.glassEffect(.regular.interactive(), in: .circle)
                .glassEffectTransition(.identity)
        } else {
            icon.background(.regularMaterial, in: Circle())
        }
    }
}
