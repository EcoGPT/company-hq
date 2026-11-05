import SwiftUI
import WebRTC

/// The call, full screen. Meet's arrangement carried onto a phone: everyone
/// in a grid on the fixed dark stage, a presenter filling it when someone is
/// sharing, and the control bar floating at the bottom over the home
/// indicator.
struct MeetingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var panel: MeetingPanel?

    private var engine: CallEngine { store.callEngine }
    private var call: Call? { store.activeCall }

    private var participants: [CallParticipant] {
        call?.presentParticipants ?? []
    }

    /// A screen share owns the stage; everyone else drops to the strip.
    private var presenterTrack: RTCVideoTrack? {
        guard let call else { return nil }
        let sharing = Set(call.presentParticipants.filter(\.isScreenSharing).map(\.deviceId))
        for track in call.liveTracks(from: "screen") where sharing.contains(track.deviceId) {
            if let video = engine.remoteVideo[track.trackName] { return video }
        }
        return nil
    }

    var body: some View {
        ZStack {
            Tokens.Palette.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let error = store.callError {
                    CallErrorBanner(text: error)
                        .padding(.horizontal, Tokens.Space.x3)
                        .padding(.bottom, Tokens.Space.x2)
                }
                if let presenterTrack {
                    VideoView(track: presenterTrack, contentMode: .scaleAspectFit)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
                        .padding(.horizontal, Tokens.Space.x3)
                    presenterStrip
                } else {
                    grid
                }
                Spacer(minLength: 0)
            }
            .safeAreaInset(edge: .bottom) {
                MeetingControlBarPhone(panel: $panel)
                    .padding(.bottom, Tokens.Space.x2)
            }
            if let notice = engine.transientNotice {
                noticeToast(notice)
            }
            // Recovery giving up used to be invisible on the phone too: the
            // spinner stopped and the frozen grid claimed to be live.
            if case .failed(let message) = engine.stage {
                failedOverlay(message)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(item: $panel) { which in
            MeetingPanelSheet(which: which, conversationId: call?.conversationId)
                .environment(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .trailing, spacing: Tokens.Space.x2) {
            HStack(spacing: Tokens.Space.x2) {
                // Messages' and FaceTime's chevron, in the place they put it:
                // the call screen goes away, the call does not. Leaving is the
                // red button at the bottom and nothing else.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.stageInk)
                        .frame(width: 44, height: 44)
                        .hqGlass(in: Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize call")
                if engine.stage == .reconnecting {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Reconnecting…")
                } else {
                    Text(title).lineLimit(2)
                }
                Spacer(minLength: 0)
                if isCallLive { LiveBadge().fixedSize() }
            }
            if isCallLive {
                Label("Recording · Transcribing", systemImage: "record.circle")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.stageInk.opacity(0.85))
                    .accessibilityHint("A transcript will be available after the call")
            }
            if engine.isTalkingWhileMuted {
                Label("You're muted", systemImage: "mic.slash.fill")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(.yellow)
            } else if engine.isMicSilent {
                Label("No one can hear you", systemImage: "waveform.slash")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .font(Tokens.Typography.meta)
        .foregroundStyle(Tokens.Palette.stageInk)
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.bottom, Tokens.Space.x3)
    }

    private var isCallLive: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if HQSimulatorFixture.scenario == "call" { return true }
        #endif
        return engine.stage == .live
    }

    private var title: String {
        guard let call else { return "Call" }
        if let title = call.title, !title.isEmpty { return title }
        guard let conversation = store.conversation(call.conversationId)
        else { return "Call" }
        return store.displayName(for: conversation)
    }

    /// One column of tall tiles on a phone, two when there are enough people
    /// to justify the smaller faces.
    private var grid: some View {
        let columns = participants.count <= 2 ? 1 : 2
        return ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Tokens.Space.x2), count: columns
                ),
                spacing: Tokens.Space.x2
            ) {
                ForEach(participants) { participant in
                    tile(participant, isCompact: columns > 1)
                        .aspectRatio(columns == 1 ? 3 / 4 : 3 / 4, contentMode: .fit)
                }
            }
            .padding(.horizontal, Tokens.Space.x3)
        }
    }

    private var presenterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Space.x2) {
                ForEach(participants) { participant in
                    tile(participant, isCompact: true)
                        .frame(width: 108, height: 144)
                }
            }
            .padding(.horizontal, Tokens.Space.x3)
        }
        .frame(height: 152)
        .padding(.top, Tokens.Space.x2)
    }

    private func tile(_ participant: CallParticipant, isCompact: Bool) -> some View {
        let isSelf = participant.deviceId == store.session?.deviceId
        // "cam" is the wire's source name (see CallTrack) — filtering on
        // "camera" matched nothing, so remote cameras never rendered here.
        let track = call?.liveTracks(from: "cam")
            .first { $0.deviceId == participant.deviceId }
        // Gated like the Mac: stopCamera keeps the last frame in localVideo,
        // and an ungated read froze that frame into your own tile.
        // A remote camera shows only while its owner says it is on: a
        // switched-off camera keeps its subscription (or, on an older hub,
        // its roster row) and would otherwise paint a black tile.
        let video = isSelf
            ? (engine.isCameraOn ? engine.localVideo : nil)
            : participant.isCameraOn ? track.flatMap { engine.remoteVideo[$0.trackName] } : nil
        return ParticipantTileView(
            participant: participant, video: video, isSelf: isSelf, isCompact: isCompact
        )
    }

    private func failedOverlay(_ message: String) -> some View {
        VStack(spacing: Tokens.Space.x4) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Tokens.Palette.stageInk.opacity(0.8))
            Text(message)
                .font(Tokens.Typography.rowEmphasis)
                .foregroundStyle(Tokens.Palette.stageInk)
            HStack(spacing: Tokens.Space.x3) {
                Button("Rejoin") {
                    Task { await store.retryCall() }
                }
                .buttonStyle(.borderedProminent)
                Button("Leave") {
                    Task { await store.leaveCall() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72).ignoresSafeArea())
    }

    private func noticeToast(_ notice: String) -> some View {
        Text(notice)
            .font(Tokens.Typography.meta)
            .foregroundStyle(Tokens.Palette.stageInk)
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x2)
            .background(.black.opacity(0.7), in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 60)
            .transition(.opacity)
    }
}

enum MeetingPanel: String, Identifiable {
    case people
    case chat

    var id: String { rawValue }
}

/// The phone's control bar. Same controls as the Mac's, minus presenting —
/// iOS can only capture the screen through a Broadcast Upload extension —
/// plus the camera flip a phone needs and the Mac has no use for.
private struct MeetingControlBarPhone: View {
    @Environment(AppStore.self) private var store
    @Binding var panel: MeetingPanel?

    private var engine: CallEngine { store.callEngine }

    private var isHandRaised: Bool {
        guard let deviceId = store.session?.deviceId else { return false }
        return store.activeCall?.participants.first { $0.deviceId == deviceId }?.isHandRaised ?? false
    }

    var body: some View {
        HStack(spacing: 4) {
            CircleControl(
                symbol: engine.isMicrophoneOn ? "mic.fill" : "mic.slash.fill",
                isOn: engine.isMicrophoneOn,
                help: engine.isMicrophoneOn ? "Mute" : "Unmute"
            ) {
                Task { await engine.setMicrophone(on: !engine.isMicrophoneOn) }
            }
            CircleControl(
                symbol: engine.isCameraOn ? "video.fill" : "video.slash.fill",
                isOn: engine.isCameraOn,
                help: engine.isCameraOn ? "Turn camera off" : "Turn camera on"
            ) {
                Task { await engine.setCamera(on: !engine.isCameraOn) }
            }
            // The Mac's background picker plus the flip a phone needs. HQ's
            // own blur is a menu choice rather than the Mac's popover — a
            // popover on a phone is a menu with extra steps.
            Menu {
                Button("Flip camera", systemImage: "arrow.triangle.2.circlepath.camera.fill") {
                    Task { await engine.flipCamera() }
                }
                Section("Background") {
                    Button {
                        engine.setBackgroundBlurred(false)
                    } label: {
                        Label(
                            "None",
                            systemImage: engine.isBackgroundBlurred
                                ? "circle" : "checkmark.circle.fill"
                        )
                    }
                    Button {
                        engine.setBackgroundBlurred(true)
                    } label: {
                        Label(
                            "Blur background",
                            systemImage: engine.isBackgroundBlurred
                                ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
                Button("Apple video effects…", systemImage: "camera.filters") {
                    SystemVideoEffects.showPicker()
                }
            } label: {
                CircleControlLabel(
                    symbol: "camera.filters", isOn: true, isActive: engine.isBackgroundBlurred
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera options")
            .disabled(!engine.isCameraOn)
            CircleControl(
                symbol: "hand.raised.fill",
                isOn: !isHandRaised,
                isActive: isHandRaised,
                help: isHandRaised ? "Lower hand" : "Raise hand"
            ) {
                Task { await store.updateHandRaised(!isHandRaised) }
            }
            CircleControl(
                symbol: "bubble.left.and.bubble.right.fill",
                isOn: true,
                isActive: panel == .chat,
                help: "People and chat"
            ) {
                panel = .chat
            }
            CircleControl(
                symbol: "phone.down.fill", isOn: true, isDestructive: true, help: "Leave call"
            ) {
                Task { await store.leaveCall() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, Tokens.Space.x2)

    }
}

/// People and in-call chat, as one sheet with a segmented control — a phone
/// has no room for the Mac's side panel.
private struct MeetingPanelSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let which: MeetingPanel
    let conversationId: String?
    @State private var tab: MeetingPanel

    init(which: MeetingPanel, conversationId: String?) {
        self.which = which
        self.conversationId = conversationId
        _tab = State(initialValue: which)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("People").tag(MeetingPanel.people)
                    Text("Chat").tag(MeetingPanel.chat)
                }
                .pickerStyle(.segmented)
                .padding(Tokens.Space.x3)

                if tab == .people {
                    peopleList
                } else if let conversationId {
                    // The in-call composer sends into the MEETING's room,
                    // never the list's selection — the bug that put in-call
                    // chat in the wrong thread on the Mac.
                    ChatView(conversationId: conversationId).environment(store)
                } else {
                    EmptyStateText("This call has no thread to chat in.")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private var peopleList: some View {
        List(store.activeCall?.presentParticipants ?? []) { participant in
            HStack(spacing: Tokens.Space.x3) {
                AvatarView(name: store.people[participant.personId]?.name ?? "?", size: 34)
                Text(store.people[participant.personId]?.name ?? "Someone")
                    .font(Tokens.Typography.row)
                Spacer(minLength: 0)
                if participant.isHandRaised {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
                }
                if participant.isMuted {
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                }
            }
        }
    }
}
