import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    /// Whether the call screen is UP, kept as its own state rather than read
    /// off `activeCallId`. Being in a call and looking at the call are two
    /// different facts on a phone: minimizing puts the screen away without
    /// touching the call, and a derived flag has nowhere to record that.
    /// A call that starts (or a ring that is answered) raises it again.
    @State private var isCallScreenUp = true

    var body: some View {
        VStack(spacing: 0) {
            if store.activeCallId != nil, !isCallScreenUp {
                CallReturnStrip { isCallScreenUp = true }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.returnToActiveCall, { isCallScreenUp = true })
        .onChange(of: store.activeCallId) { _, newValue in
            if newValue != nil { isCallScreenUp = true }
        }
        .fullScreenCover(item: callPresentation) { presentation in
            switch presentation {
            case .ringing:
                IncomingCallPhoneView().environment(store)
            case .inCall:
                MeetingView().environment(store)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG && targetEnvironment(simulator)
        if HQSimulatorFixture.scenario.hasPrefix("preview-") {
            HQFixturePresentation()
        } else {
            appContent
        }
        #else
        appContent
        #endif
    }

    @ViewBuilder
    private var appContent: some View {
        switch store.phase {
        case .enrolling:
            EnrollmentView()
        case .ready:
            MainView(personID: store.me?.id ?? "")
                .id("\(HQConfig.baseURLString)|\(store.me?.id ?? "")")
        }
    }

    /// What the call layer is showing, if anything: a ring being offered, or
    /// this device actually in a call. Being in one wins — answering clears
    /// the ring, and a ring that arrives mid-call is dropped by the store
    /// before it ever gets here.
    ///
    /// Nothing is a third state, and it is NOT the same as no call: a
    /// minimized call is live with this enum reading nil, which is why
    /// `isCallScreenUp` exists beside `activeCallId` rather than being
    /// derived from it.
    private enum CallPresentation: String, Identifiable {
        case ringing
        case inCall

        var id: String { rawValue }
    }

    private var callPresentation: Binding<CallPresentation?> {
        Binding(
            get: {
                if store.activeCallId != nil { return isCallScreenUp ? .inCall : nil }
                return store.incomingCall == nil ? nil : .ringing
            },
            set: { presentation in
                // The only way this clears from the UI is a dismissal, and
                // the only dismissable state is being in a call — where a
                // dismissal is a MINIMIZE, never a hang-up. Audio keeps
                // running behind it (`UIBackgroundModes: audio`), the green
                // strip above says so, and leaving stays an explicit act.
                guard presentation == nil, store.activeCallId != nil else { return }
                isCallScreenUp = false
            }
        )
    }
}

/// Messages' own shape: a list of threads that pushes a transcript. It is a
/// `NavigationSplitView` rather than a `NavigationStack` because that is one
/// code path for both devices — collapsed to exactly this push stack on
/// iPhone, and the two-column layout Messages uses on iPad.
private struct MainView: View {
    @Environment(AppStore.self) private var store
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    // Built once, on first read. RootView's body re-runs on call, session and
    // prompt changes and makes a fresh MainView each time (SwiftUI then keeps
    // the State it already has), and `HomePreferences` reads UserDefaults and
    // decodes JSON. The holder is cheap to make and to throw away; the
    // preferences are made only by the first MainView body that reads them.
    @State private var holder: PreferencesHolder

    init(personID: String) {
        _holder = State(initialValue: PreferencesHolder(personID: personID))
    }

    @MainActor private final class PreferencesHolder {
        private let personID: String
        init(personID: String) { self.personID = personID }

        lazy var preferences: HomePreferences = {
            #if DEBUG && targetEnvironment(simulator)
            if HQSimulatorFixture.isEnabled {
                let environment = ProcessInfo.processInfo.environment
                var defaults: UserDefaults?
                if let value = environment["HQ_UI_HOME_STORAGE"], let id = UUID(uuidString: value) {
                    let suite = "\(HQIdentity.bundleID).ui-home-tests.\(id.uuidString)"
                    defaults = UserDefaults(suiteName: suite)
                }
                return HomePreferences(
                    hub: HQConfig.baseURLString, personID: personID, defaults: defaults,
                    initialPins: HQSimulatorFixture.scenario == "home" ? ["bo-dm", "home-0", "scout-dm"] : []
                )
            }
            #endif
            return HomePreferences(hub: HQConfig.baseURLString, personID: personID)
        }()
    }

    /// The store's destination as a selection. Popping back on iPhone writes
    /// nil through it, which is exactly how `isReadingThread` learns the
    /// transcript left the screen and banners start landing again.
    private var selection: Binding<AppStore.Destination?> {
        Binding(
            get: { store.destination == .none ? nil : store.destination },
            set: { newValue in
                guard let newValue else {
                    store.destination = .none
                    return
                }
                if case .conversation(let id) = newValue {
                    store.openConversation(id)
                } else {
                    store.destination = newValue
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(selection: selection)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(holder.preferences)
    }

    @ViewBuilder
    private var detail: some View {
        switch store.destination {
        case .conversation(let id):
            ChatView(conversationId: id)
        case .meetings:
            MeetingsView()
        case .tasks:
            ProjectsWorkspace()
        case .files:
            FilesView()
        case .settings:
            SettingsView()
        case .none:
            EmptyDetailView()
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        ZStack {
            Tokens.Palette.surface.ignoresSafeArea()
            EmptyStateText("Pick a conversation to start reading.")
        }
    }
}
