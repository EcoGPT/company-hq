import CoreImage
import CoreVideo
import Metal
import Vision
import WebRTC

/// A sender-side blur: camera frames are segmented and composited before they
/// reach RTCVideoSource, so the self-view and everybody else's copy match.
/// There is deliberately never more than one frame in flight. If Vision falls
/// behind, capture drops work instead of building a latency queue.
///
/// Both platforms. The Mac's camera hands over upright buffers; a phone's
/// does not — `RTCCameraVideoCapturer` leaves the frame in sensor orientation
/// and puts the correction in `RTCVideoFrame.rotation`. Vision segments a
/// sideways person badly, so the frame's rotation becomes the request's
/// orientation hint and the mask is put back into buffer space before it is
/// composited (see `alignedMask`). The composite itself stays in buffer
/// space with the frame's original rotation, so nothing downstream — the
/// encoder, the media server, the remote renderer — sees a different geometry than it
/// did without the blur.
final class BackgroundBlurProcessor: NSObject, RTCVideoCapturerDelegate, @unchecked Sendable {
    private let output: RTCVideoCapturerDelegate
    private let processingQueue = DispatchQueue(
        label: "\(HQIdentity.bundleID).background-blur", qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var isEnabled = false
    private var isProcessing = false
    private var generation = 0
    private var didReportFailure = false

    private let request: VNGeneratePersonSegmentationRequest
    private let requestHandler = VNSequenceRequestHandler()
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var outputPool: CVPixelBufferPool?
    private var outputSize: (width: Int, height: Int)?

    var onFailure: (() -> Void)?

    init(delegate: RTCVideoCapturerDelegate) {
        output = delegate
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device)
        } else {
            context = CIContext(options: [.useSoftwareRenderer: false])
        }
        super.init()
    }

    func setEnabled(_ enabled: Bool) {
        stateLock.lock()
        isEnabled = enabled
        generation += 1
        if enabled { didReportFailure = false }
        stateLock.unlock()
    }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        stateLock.lock()
        guard isEnabled else {
            stateLock.unlock()
            output.capturer(capturer, didCapture: frame)
            return
        }
        guard !isProcessing else {
            stateLock.unlock()
            return
        }
        isProcessing = true
        let frameGeneration = generation
        stateLock.unlock()

        processingQueue.async { [weak self] in
            guard let self else { return }
            let processed = self.blurredFrame(from: frame)
            self.finish(
                processed, capturer: capturer, generation: frameGeneration
            )
        }
    }

    private func finish(
        _ processed: RTCVideoFrame?,
        capturer: RTCVideoCapturer,
        generation frameGeneration: Int
    ) {
        stateLock.lock()
        let isCurrent = isEnabled && generation == frameGeneration
        isProcessing = false
        var shouldReportFailure = false
        if isCurrent, processed == nil, !didReportFailure {
            // Stop claiming that the background is protected if the processor
            // cannot produce a frame. The next capture resumes ordinary video.
            isEnabled = false
            generation += 1
            didReportFailure = true
            shouldReportFailure = true
        }
        stateLock.unlock()

        if isCurrent, let processed {
            output.capturer(capturer, didCapture: processed)
        }
        if shouldReportFailure { onFailure?() }
    }

    private func blurredFrame(from frame: RTCVideoFrame) -> RTCVideoFrame? {
        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let pixelBuffer = rtcBuffer.pixelBuffer

        let orientation = Self.orientation(for: frame.rotation)
        do {
            try requestHandler.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            return nil
        }
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return nil }

        let original = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = original.extent
        let mask = alignedMask(
            CIImage(cvPixelBuffer: maskBuffer), to: extent, hint: orientation
        )
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
            .cropped(to: extent)
        let background = original
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22.0])
            .cropped(to: extent)
        let composite = original.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask,
            ]
        )

        guard let outputBuffer = makeOutputBuffer(
            width: Int(extent.width), height: Int(extent.height)
        ) else { return nil }
        context.render(composite, to: outputBuffer, bounds: extent, colorSpace: colorSpace)

        return RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: outputBuffer),
            rotation: frame.rotation,
            timeStampNs: frame.timeStampNs
        )
    }

    /// Which way up the person is inside the capture buffer. The frame's
    /// rotation is what a renderer must APPLY to show the picture upright, so
    /// it names the same thing a `CGImagePropertyOrientation` does.
    private static func orientation(
        for rotation: RTCVideoRotation
    ) -> CGImagePropertyOrientation {
        switch rotation {
        case ._90: return .right
        case ._180: return .down
        case ._270: return .left
        default: return .up
        }
    }

    /// The mask, in the capture buffer's own coordinate space and scaled to
    /// it. Vision is free to hand a segmentation mask back in the ORIENTED
    /// space it was asked to work in — for a portrait phone that is the
    /// buffer with its sides swapped — and blending a transposed mask puts
    /// the sharp band across the wrong axis. A mask whose long side does not
    /// agree with the buffer's is rotated back before it is scaled; one that
    /// already agrees is left alone, so this is a no-op wherever Vision
    /// reports in buffer space (every Mac frame included).
    private func alignedMask(
        _ mask: CIImage, to extent: CGRect, hint: CGImagePropertyOrientation
    ) -> CIImage {
        var image = mask
        let isQuarterTurn = hint == .left || hint == .right
        let isTransposed = (mask.extent.width > mask.extent.height)
            != (extent.width > extent.height)
        if isQuarterTurn, isTransposed {
            // `.left` and `.right` are each other's inverse.
            image = image.oriented(hint == .right ? .left : .right)
        }
        image = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.origin.x, y: -image.extent.origin.y
            )
        )
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        return image.transformed(
            by: CGAffineTransform(
                scaleX: extent.width / image.extent.width,
                y: extent.height / image.extent.height
            )
        )
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if outputSize?.width != width || outputSize?.height != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                nil, nil, attributes as CFDictionary, &pool
            ) == kCVReturnSuccess else { return nil }
            outputPool = pool
            outputSize = (width, height)
        }
        guard let outputPool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &output) == kCVReturnSuccess
        else { return nil }
        return output
    }
}
