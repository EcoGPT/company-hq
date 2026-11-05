import Foundation
import ScreenCaptureKit
import WebRTC

// Screen sharing, sender-side: ScreenCaptureKit hands us frames, we hand them
// to the same video pipeline a camera uses. The whole display is shared —
// window pickers come later; what matters first is that "Present now" works.
final class ScreenShareCapturer: NSObject, @unchecked Sendable {
    private let source: RTCVideoCapturerDelegate
    private var stream: SCStream?
    private lazy var capturer = RTCVideoCapturer(delegate: source)
    private let queue = DispatchQueue(label: HQIdentity.bundleID + ".screenshare")

    init(delegate: RTCVideoCapturerDelegate) {
        source = delegate
        super.init()
    }

    enum CaptureError: Error {
        case noDisplay
    }

    func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = min(display.width * 2, 1920)
        config.height = min(display.height * 2, 1080)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stopCapture() async {
        try? await stream?.stopCapture()
        stream = nil
    }
}

extension ScreenShareCapturer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: Int64(timestamp * Double(NSEC_PER_SEC))
        )
        source.capturer(capturer, didCapture: frame)
    }
}
