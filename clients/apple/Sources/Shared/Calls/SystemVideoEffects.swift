import AVFoundation

/// Opens the operating system's conferencing effects — Portrait blur,
/// backgrounds, Center Stage, and any effects the current camera supports.
/// AVFoundation applies them before WebRTC receives the captured frame, so
/// the local preview and the video sent to the room stay identical.
@MainActor
enum SystemVideoEffects {
    static func showPicker() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }
}
