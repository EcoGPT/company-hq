import AppKit
import SwiftUI

// Meet's pre-join screen: see yourself, set mic and camera, then join. Nobody
// should ever arrive in a room without knowing what they are broadcasting.
// The toggles are the call's own CircleControls, so what you set here looks
// exactly like what the control bar will show.
struct GreenRoomView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let title: String
    let kind: String
    let conversationId: String?
    var meetingId: String?
    @State private var isCameraOn = false
    @State private var isMicrophoneOn = true
    @State private var isJoining = false
    // The mic proof: a level-only tap (no transcription socket) drives the bar,
    // so a dead mic is caught here instead of one sentence into the call.
    @State private var levelMonitor = MeetingTranscriber()
    @State private var micLevel: Float = 0

    var body: some View {
        VStack(spacing: Tokens.Space.x4) {
            stage
            audioCheckRow
            VStack(spacing: Tokens.Space.x1) {
                Text(title)
                    .font(Tokens.Typography.sheetTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(readyLine)
                    .font(Tokens.Typography.meta)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                // Said before anyone joins, not discovered afterwards.
                Text("Recorded and transcribed")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietCapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isJoining ? "Joining…" : "Join now") { join() }
                    .buttonStyle(TintedCapsuleButtonStyle(tint: Tokens.Palette.live))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isJoining)
            }
        }
        .padding(Tokens.Space.x5)
        .frame(width: 470)
        .onAppear {
            levelMonitor.onLevel = { level in
                // Fast attack, slow decay — speech flicks the bar up and it
                // falls back readably.
                micLevel = max(level, micLevel * 0.7)
            }
            levelMonitor.startLevelMonitor()
        }
        .onDisappear { levelMonitor.stop() }
    }

    private var audioCheckRow: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                MicLevelBar(level: micLevel)
            }
            .help("Speak — the bar should move")
            Spacer()
            Button("Test speakers") {
                // Plays through the system's current output — the same
                // route the call will use.
                NSSound(named: "Glass")?.play()
            }
            .buttonStyle(QuietCapsuleButtonStyle())
        }
    }

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.stage)
            if isCameraOn {
                CameraPreviewView()
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                    // A self-view is a mirror, here and in the call.
                    .scaleEffect(x: -1, y: 1)
            } else {
                VStack(spacing: Tokens.Space.x3) {
                    AvatarView(name: store.me?.name ?? "You", size: 72)
                    Text("Camera is off")
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.stageInk.opacity(0.75))
                }
            }
        }
        .frame(width: 422, height: 238)
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                CircleControl(
                    symbol: isMicrophoneOn ? "mic.fill" : "mic.slash.fill",
                    isOn: isMicrophoneOn,
                    help: isMicrophoneOn ? "Mute" : "Unmute"
                ) {
                    isMicrophoneOn.toggle()
                }
                CircleControl(
                    symbol: isCameraOn ? "video.fill" : "video.slash.fill",
                    isOn: isCameraOn,
                    help: isCameraOn ? "Turn camera off" : "Turn camera on"
                ) {
                    isCameraOn.toggle()
                }
                CircleControl(
                    symbol: "camera.filters",
                    isOn: true,
                    help: "Video effects"
                ) {
                    SystemVideoEffects.showPicker()
                }
                .disabled(!isCameraOn)
            }
            .padding(.bottom, Tokens.Space.x3)
        }
    }

    private var readyLine: String {
        guard let live = liveCall else { return "You'll be the first one here" }
        let count = live.presentParticipants.count
        return count == 1 ? "1 person is already here" : "\(count) people are already here"
    }

    private var liveCall: Call? {
        if let meetingId { return store.liveCall(forMeeting: meetingId) }
        if let conversationId { return store.liveCall(inConversation: conversationId) }
        // A fresh instant start has no live call yet — the server births one.
        return nil
    }

    private func join() {
        isJoining = true
        Task {
            if let conversationId {
                await store.joinCall(
                    conversationId: conversationId,
                    isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn
                )
            } else {
                await store.joinMeeting(meetingId, isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn)
            }
            isJoining = false
            if store.activeCallId != nil {
                MeetingWindow.spotlight(using: openWindow)
                dismiss()
            }
        }
    }
}

// Ten segments, sqrt-mapped so quiet speech still moves the low end.
private struct MicLevelBar: View {
    let level: Float
    private let segmentCount = 10

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(index < litCount ? Tokens.Palette.live : Tokens.Palette.segmentTrack)
                    .frame(width: 6, height: 14)
            }
        }
        .animation(.linear(duration: 0.1), value: litCount)
    }

    private var litCount: Int {
        let normalized = max(0, min(1, Double(level) / 0.7))
        return min(segmentCount, Int(normalized.squareRoot() * Double(segmentCount) + 0.5))
    }
}
