import SwiftUI
import WebRTC

// The call itself, modeled on Google Meet: a dark stage of equal tiles (or one
// big presenter with a strip), a floating control bar, and one side panel that
// slides in for people or chat.
struct MeetingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var panel: SidePanel?

    enum SidePanel: String, Identifiable {
        case people
        case chat

        var id: String { rawValue }
    }

    private var call: Call? { store.activeCall }

    private var participants: [CallParticipant] {
        call?.presentParticipants ?? []
    }

    private var screenShare: (participant: CallParticipant, track: RTCVideoTrack?)? {
        guard let call else { return nil }
        guard let sharing = call.presentParticipants.first(where: { $0.isScreenSharing }) else { return nil }
        let name = call.liveTracks(from: "screen").first { $0.deviceId == sharing.deviceId }?.trackName
        let track = name.flatMap { store.callEngine.remoteVideo[$0] }
        return (participant: sharing, track: track)
    }

    private var callNotices: some View {
        VStack(spacing: 8) {
            if store.callEngine.isTalkingWhileMuted {
                micToast("Your mic is off", symbol: "mic.slash.fill")
            } else if store.callEngine.isMicSilent {
                micToast("No one can hear you — check your mic", symbol: "waveform.slash")
            }
            if let notice = store.callEngine.transientNotice {
                noticeToast(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Tokens.Palette.stage.ignoresSafeArea()
            if call == nil {
                idleState
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        stage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .bottom) { callNotices }
                        MeetingControlBar(panel: $panel)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let panel {
                        MeetingSidePanel(panel: panel, call: call) { self.panel = nil }
                            .frame(width: 320)
                    }
                }
            }

        }
        .overlay(alignment: .top) {
            // The self-heal in progress, said out loud: a silent rebuild
            // reads as a glitch, a named one reads as recovery.
            if call != nil, store.callEngine.stage == .reconnecting {
                reconnectingBanner
                    .transition(.opacity)
            }
        }
        .overlay {
            // Recovery giving up used to be invisible — the spinner stopped
            // and the stage silently froze while everyone else saw a ghost.
            if call != nil, case .failed(let message) = store.callEngine.stage {
                failedOverlay(message)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Every call is recorded and its audio goes to the server's
            // transcription, so every call says so for as long as it runs. A
            // recording nobody was told about is not a feature.
            if call != nil, store.callEngine.stage != .reconnecting {
                recordingPill
            }
        }
        .animation(.snappy(duration: 0.2), value: store.callEngine.transientNotice)
        .animation(.snappy(duration: 0.2), value: store.callEngine.isTalkingWhileMuted)
        .animation(.snappy(duration: 0.2), value: store.callEngine.isMicSilent)
        .animation(.snappy(duration: 0.2), value: store.callEngine.stage == .reconnecting)
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(call?.title ?? "Meeting")
        // Leaving (or the call ending under you) takes the window with it —
        // straight back to the app, never an empty black stage.
        .onChange(of: store.activeCallId) { _, newValue in
            guard newValue == nil else { return }
            dismissWindow(id: "hq-meeting")
            // dismissWindow silently no-ops on a window macOS restored at
            // launch instead of one opened by openWindow — close the AppKit
            // window directly so leaving always takes the stage with it.
            for window in NSApp.windows
            where window.identifier?.rawValue.hasPrefix("hq-meeting") == true {
                window.close()
            }
        }
    }

    private var recordingPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle")
                .font(.system(size: 11, weight: .semibold))
            Text("Recording · Transcribing")
                .font(Tokens.Typography.caption)
        }
        .foregroundStyle(Tokens.Palette.stageInk.opacity(0.85))
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, 5)
        .hqGlass(in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(Tokens.Space.x4)
        .padding(.trailing, panel == nil ? 0 : 320)
        .accessibilityHint("A transcript will be available after the call")
    }

    private var reconnectingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Tokens.Palette.stageInk)
            Text("Reconnecting…")
                .font(Tokens.Typography.rowEmphasis)
                .foregroundStyle(Tokens.Palette.stageInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.65)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .padding(.top, 16)
    }

    private func failedOverlay(_ message: String) -> some View {
        VStack(spacing: Tokens.Space.x4) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .medium))
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
        .background(Color.black.opacity(0.72))
    }

    private func noticeToast(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.row)
            .foregroundStyle(Tokens.Palette.stageInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.65)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
    }

    // High-contrast on the dark stage: the one toast that must be seen
    // mid-sentence.
    private func micToast(_ text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(Tokens.Typography.rowEmphasis)
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.92)))
    }

    private var idleState: some View {
        VStack(spacing: Tokens.Space.x3) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 34))
                .foregroundStyle(Tokens.Palette.stageInk.opacity(0.5))
            Text("You've left the meeting")
                .font(Tokens.Typography.sheetTitle)
                .foregroundStyle(Tokens.Palette.stageInk)
        }
    }

    @ViewBuilder
    private var stage: some View {
        if let share = screenShare {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                        .fill(Tokens.Palette.stage)
                    if let track = share.track {
                        VideoView(track: track)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
                    } else {
                        Text("\(store.people[share.participant.personId]?.name ?? "Someone") is presenting")
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.stageInk.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(participants) { participant in
                            tile(for: participant, isCompact: true)
                                .frame(width: 150, height: 96)
                        }
                    }
                }
                .frame(height: 96)
            }
            .padding(14)
        } else {
            GeometryReader { geo in
                // Tiles fit BOTH axes: a wide window sizes them by width, a
                // tall one by height. The grid never scrolls — every tile is
                // on screen, centered in the space above the control bar.
                let gap: CGFloat = 10
                let usable = CGSize(
                    width: max(geo.size.width - 28, 1),
                    height: max(geo.size.height - 28, 1)
                )
                let layout = MeetingGrid.layout(count: participants.count, in: usable)
                let cellWidth = (usable.width - gap * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
                let cellHeight = (usable.height - gap * CGFloat(layout.rows - 1)) / CGFloat(layout.rows)
                let tileWidth = max(min(cellWidth, cellHeight * 16 / 9), 1)
                VStack(spacing: gap) {
                    ForEach(0..<layout.rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(rowParticipants(row: row, columns: layout.columns)) { participant in
                                tile(for: participant)
                                    .frame(width: tileWidth, height: tileWidth * 9 / 16)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func rowParticipants(row: Int, columns: Int) -> [CallParticipant] {
        let start = row * columns
        guard start < participants.count else { return [] }
        return Array(participants[start..<min(start + columns, participants.count)])
    }

    private func tile(for participant: CallParticipant, isCompact: Bool = false) -> some View {
        let isSelf = participant.deviceId == store.session?.deviceId
        let cameraTrackName = call?.liveTracks(from: "cam")
            .first { $0.deviceId == participant.deviceId }?.trackName
        // A remote camera shows only while its owner says it is on: a
        // switched-off camera keeps its subscription (or, on an older hub,
        // its roster row) and would otherwise paint a black tile.
        let video: RTCVideoTrack? = isSelf
            ? (store.callEngine.isCameraOn ? store.callEngine.localVideo : nil)
            : participant.isCameraOn ? cameraTrackName.flatMap { store.callEngine.remoteVideo[$0] } : nil
        return ParticipantTileView(
            participant: participant, video: video, isSelf: isSelf, isCompact: isCompact
        )
    }
}

// Meet's tile arithmetic: as few columns as keep every tile near 16:9.
enum MeetingGrid {
    static func layout(count: Int, in size: CGSize) -> (columns: Int, rows: Int) {
        guard count > 1 else { return (1, 1) }
        var best = (columns: 1, rows: count)
        var bestScore = Double.greatestFiniteMagnitude
        for columns in 1...min(count, 5) {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let tileWidth = size.width / Double(columns)
            let tileHeight = size.height / Double(rows)
            guard tileWidth > 0, tileHeight > 0 else { continue }
            let score = abs((tileWidth / tileHeight) - (16.0 / 9.0))
            if score < bestScore {
                bestScore = score
                best = (columns: columns, rows: rows)
            }
        }
        return best
    }
}
