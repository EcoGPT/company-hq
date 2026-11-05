import SwiftUI
import WebRTC

// A single WebRTC track, rendered by Metal. Both platforms ship a Metal view
// for exactly this; they differ only in name and in which representable
// protocol wraps them. The view fills its bounds — the tile above it owns the
// aspect and the rounded corners.
#if os(macOS)
struct VideoView: NSViewRepresentable {
    let track: RTCVideoTrack

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: .zero)
        track.add(view)
        context.coordinator.attached = track
        return view
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
        guard context.coordinator.attached !== track else { return }
        context.coordinator.attached?.remove(nsView)
        track.add(nsView)
        context.coordinator.attached = track
    }

    static func dismantleNSView(_ nsView: RTCMTLNSVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(nsView)
        coordinator.attached = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var attached: RTCVideoTrack?
    }
}
#else
struct VideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    /// `.scaleAspectFill` for a tile that should be edge to edge,
    /// `.scaleAspectFit` for a shared screen that must not be cropped.
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = contentMode
        // The phone rotates; the renderer must not letterbox itself into the
        // old orientation when it does.
        view.clipsToBounds = true
        track.add(view)
        context.coordinator.attached = track
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.videoContentMode = contentMode
        guard context.coordinator.attached !== track else { return }
        context.coordinator.attached?.remove(uiView)
        track.add(uiView)
        context.coordinator.attached = track
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(uiView)
        coordinator.attached = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var attached: RTCVideoTrack?
    }
}
#endif
