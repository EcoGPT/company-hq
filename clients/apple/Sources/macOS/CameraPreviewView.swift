import AVFoundation
import SwiftUI

// The green room's live self-view. This is plain AVFoundation rather than a
// WebRTC track: before you have joined there is no peer connection to attach
// to, and Meet's whole point here is that you see yourself *first*.
struct CameraPreviewView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.layer?.frame = nsView.bounds
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private let session = AVCaptureSession()
        private(set) var layer: AVCaptureVideoPreviewLayer?

        func attach(to view: NSView) {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(preview)
            layer = preview
            Task { await start() }
        }

        private func start() async {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return }
            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)
            session.commitConfiguration()
            // startRunning blocks; keeping it off the main actor keeps the sheet
            // responsive while the camera warms up.
            let session = self.session
            await Task.detached { session.startRunning() }.value
        }

        func stop() {
            let session = self.session
            Task.detached { session.stopRunning() }
        }
    }
}
