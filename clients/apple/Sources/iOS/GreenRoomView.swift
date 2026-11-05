import AVFoundation
import SwiftUI

/// The pre-join screen: see yourself, prove your mic, then join. Nobody
/// should ever arrive in a room without knowing what they are broadcasting —
/// and on a phone that matters more, because the camera is pointed at
/// whatever the phone is pointed at.
struct GreenRoomView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var conversationId: String?
    var meetingId: String?
    var title: String = "Call"

    @State private var isCameraOn = false
    @State private var isMicrophoneOn = true
    @State private var isJoining = false
    // The mic proof: a level-only tap (no transcription socket) drives the
    // bar, so a dead mic is caught here instead of one sentence into the call.
    @State private var levelMonitor = MeetingTranscriber()
    @State private var micLevel: Float = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Tokens.Space.x4) {
                    stage
                        .frame(maxWidth: 300)
                        .frame(maxWidth: .infinity)
                    audioCheckRow
                    VStack(spacing: Tokens.Space.x1) {
                        Text(title)
                            .font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(readyLine)
                            .font(Tokens.Typography.meta)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                        // Said before anyone joins, not discovered afterwards.
                        Text("Recorded and transcribed")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                    }

                }
                .padding(Tokens.Space.x4)
            }
            .background(Tokens.Palette.surface)
            .safeAreaInset(edge: .bottom) {
                Button(isJoining ? "Joining…" : "Join now") { join() }
                    .buttonStyle(TintedCapsuleButtonStyle(tint: Tokens.Palette.live))
                    .disabled(isJoining)
                    .padding(12)
            }
            .navigationTitle("Ready to join?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if HQSimulatorFixture.isEnabled { return }
            #endif
            // The prompts have to come before the preview, or the first join
            // is a black rectangle and a silent mic.
            await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVAudioApplication.requestRecordPermission()
            levelMonitor.onLevel = { level in
                // Fast attack, slow decay — speech flicks the bar up and it
                // falls back readably.
                micLevel = max(level, micLevel * 0.7)
            }
            levelMonitor.startLevelMonitor()
        }
        .onDisappear { levelMonitor.stop() }
    }

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.stage)
            if isCameraOn {
                CameraPreviewView()
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                    .scaleEffect(x: -1, y: 1)
            } else {
                VStack(spacing: Tokens.Space.x3) {
                    AvatarView(name: store.me?.name ?? "?", size: 76)
                    Text("Camera is off")
                        .font(Tokens.Typography.meta)
                        .foregroundStyle(Tokens.Palette.stageInk.opacity(0.7))
                }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay(alignment: .bottom) {
            HStack(spacing: Tokens.Space.x3) {
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
            .padding(.bottom, Tokens.Space.x4)
        }
    }

    private var audioCheckRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                microphoneCheck
                speakerCheck
            }
            VStack(spacing: 12) {
                microphoneCheck
                speakerCheck
            }
        }
    }

    private var microphoneCheck: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                MicLevelBar(level: micLevel)
            }
            Text(micLevel > 0.01 ? "Mic is working" : "Say something")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Tokens.Typography.caption)
        .foregroundStyle(.secondary)
    }

    private var speakerCheck: some View {
        Button("Test speakers") { SpeakerTest.play() }
            .buttonStyle(QuietCapsuleButtonStyle(height: 44))
            .fixedSize()
    }

    /// Who is already in the room. "Ready to join" said nothing a person did
    /// not already know; whether they are walking into an empty room or a
    /// meeting six people deep changes what they do next.
    private var readyLine: String {
        if !isMicrophoneOn { return "Joining muted" }
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
        levelMonitor.stop()
        Task {
            if let meetingId {
                await store.joinMeeting(
                    meetingId, isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn
                )
            } else if let conversationId {
                await store.joinCall(
                    conversationId: conversationId,
                    isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn
                )
            } else {
                await store.joinMeeting(
                    nil, isCameraOn: isCameraOn, isMicrophoneOn: isMicrophoneOn
                )
            }
            isJoining = false
            // The stage covers the whole screen off `activeCallId`; this
            // sheet's job is done either way.
            dismiss()
        }
    }
}

/// A live input meter — the difference between "I think my mic works" and
/// seeing that it does.
private struct MicLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Palette.surfaceActive)
                Capsule()
                    .fill(Tokens.Palette.live)
                    .frame(width: geometry.size.width * min(1, CGFloat(level) * 3))
            }
        }
        .frame(width: 90, height: 6)
    }
}

/// The raw camera, before WebRTC owns it. AVFoundation directly, because the
/// engine's capture does not exist until a call does.
private struct CameraPreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.start()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.stop()
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        private let session = AVCaptureSession()

        private var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe by `layerClass`: this view's layer is always the preview.
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("layerClass guarantees AVCaptureVideoPreviewLayer")
            }
            return layer
        }

        func start() {
            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front
            ), let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input) else { return }
            session.addInput(input)
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            let session = session
            Task.detached { session.startRunning() }
        }

        func stop() {
            let session = session
            Task.detached { session.stopRunning() }
        }
    }
}
