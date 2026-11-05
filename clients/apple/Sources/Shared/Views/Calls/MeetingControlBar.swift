import SwiftUI

// The floating control bar: mic, camera, present, raise hand on the left of the
// leave button; people and chat on the right. Round buttons, red hangup, the
// muted state inverted — the arrangement everyone already knows from Meet.
struct MeetingControlBar: View {
    @Environment(AppStore.self) private var store
    @Binding var panel: MeetingView.SidePanel?
    @State private var isShowingBackgroundEffects = false

    private var engine: CallEngine { store.callEngine }

    private var isHandRaised: Bool {
        guard let deviceId = store.session?.deviceId else { return false }
        return store.activeCall?.participants.first { $0.deviceId == deviceId }?.isHandRaised ?? false
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                mediaControls
                meetingControls
            }
            VStack(spacing: 10) {
                HStack(spacing: 10) { mediaControls }
                HStack(spacing: 10) { meetingControls }
            }
        }
        .hqGlassContainer()
        .environment(\.colorScheme, .dark)
    }

    private var mediaControls: some View {
        Group {
            CircleControl(
                symbol: engine.isMicrophoneOn ? "mic.fill" : "mic.slash.fill",
                isOn: engine.isMicrophoneOn,
                help: engine.isMicrophoneOn ? "Mute (⌘D)" : "Unmute (⌘D)"
            ) {
                Task { await engine.setMicrophone(on: !engine.isMicrophoneOn) }
            }
            .keyboardShortcut("d", modifiers: .command)

            CircleControl(
                symbol: engine.isCameraOn ? "video.fill" : "video.slash.fill",
                isOn: engine.isCameraOn,
                help: engine.isCameraOn ? "Turn camera off (⌘E)" : "Turn camera on (⌘E)"
            ) {
                Task { await engine.setCamera(on: !engine.isCameraOn) }
            }
            .keyboardShortcut("e", modifiers: .command)

            CircleControl(
                symbol: "camera.filters",
                isOn: true,
                isActive: engine.isBackgroundBlurred,
                help: "Background effects"
            ) {
                isShowingBackgroundEffects.toggle()
            }
            .disabled(!engine.isCameraOn)
            .popover(isPresented: $isShowingBackgroundEffects, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Video effects")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                    backgroundEffectButton(
                        "None",
                        isSelected: !engine.isBackgroundBlurred
                    ) {
                        engine.setBackgroundBlurred(false)
                        isShowingBackgroundEffects = false
                    }
                    backgroundEffectButton(
                        "Blur background",
                        isSelected: engine.isBackgroundBlurred
                    ) {
                        engine.setBackgroundBlurred(true)
                        isShowingBackgroundEffects = false
                    }

                    Divider()
                        .padding(.vertical, 2)

                    Button {
                        isShowingBackgroundEffects = false
                        DispatchQueue.main.async {
                            SystemVideoEffects.showPicker()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "camera.filters")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple video effects…")
                                Text("Portrait, lighting, reactions, backgrounds")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .frame(width: 280)
            }

            CircleControl(
                symbol: "rectangle.on.rectangle",
                isOn: !engine.isScreenSharing,
                isActive: engine.isScreenSharing,
                help: engine.isScreenSharing ? "Stop presenting" : "Present your screen"
            ) {
                Task {
                    if engine.isScreenSharing {
                        await engine.stopScreenShare()
                    } else {
                        await engine.startScreenShare()
                    }
                }
            }
        }
    }

    private var meetingControls: some View {
        Group {
            CircleControl(
                symbol: "hand.raised.fill",
                isOn: !isHandRaised,
                isActive: isHandRaised,
                help: isHandRaised ? "Lower hand" : "Raise hand"
            ) {
                Task { await store.updateHandRaised(!isHandRaised) }
            }

            CircleControl(symbol: "phone.down.fill", isOn: true, isDestructive: true, help: "Leave call") {
                Task { await store.leaveCall() }
            }

            CircleControl(
                symbol: "person.2.fill",
                isOn: true,
                isActive: panel == .people,
                help: "People"
            ) {
                panel = panel == .people ? nil : .people
            }

            CircleControl(
                symbol: "bubble.left.and.bubble.right.fill",
                isOn: true,
                isActive: panel == .chat,
                help: "Chat"
            ) {
                panel = panel == .chat ? nil : .chat
            }
        }
    }

    private func backgroundEffectButton(
        _ title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
