import AppKit
import XCTest

#if canImport(HQ)
@testable import HQ
#endif

final class PhotoScrollTests: XCTestCase {
    func testZoomKeepsImagePointUnderPointerAfterPanning() {
        let pointer = CGPoint(x: 170, y: -90)
        let initial = CGSize(width: 40, height: 70)
        let zoomed = PhotoZoomAnchor.offset(initial, from: 2, to: 5, at: pointer)
        XCTAssertEqual((pointer.x - initial.width) / 2, (pointer.x - zoomed.width) / 5, accuracy: 0.001)
        XCTAssertEqual((pointer.y - initial.height) / 2, (pointer.y - zoomed.height) / 5, accuracy: 0.001)
        let restored = PhotoZoomAnchor.offset(zoomed, from: 5, to: 2, at: pointer)
        XCTAssertEqual(restored.width, initial.width, accuracy: 0.001)
        XCTAssertEqual(restored.height, initial.height, accuracy: 0.001)
        let minimum = PhotoZoomAnchor.offset(zoomed, from: 5, to: 1, at: pointer)
        XCTAssertEqual(pointer.x - minimum.width, (pointer.x - zoomed.width) / 5, accuracy: 0.001)
        XCTAssertEqual(pointer.y - minimum.height, (pointer.y - zoomed.height) / 5, accuracy: 0.001)
    }

    @MainActor
    func testMagnifyUsesPointerAndLeavesHeaderAlone() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 456),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = PhotoScrollEventView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView!.addSubview(view)
        defer { view.removeFromSuperview() }
        var points: [CGPoint] = []
        view.onMagnify = { _, point in points.append(point) }
        // Magnification works at fit, even though scrolling is disabled.
        XCTAssertTrue(view.handleMagnify(at: CGPoint(x: 450, y: 300), in: window, magnification: 0.2))
        XCTAssertEqual(points, [CGPoint(x: 150, y: -100)])
        XCTAssertFalse(view.handleMagnify(at: CGPoint(x: 450, y: 428), in: window, magnification: 0.2))
        XCTAssertFalse(view.handleMagnify(at: CGPoint(x: 450, y: 300), in: nil, magnification: 0.2))
        XCTAssertEqual(points.count, 1)
    }

    @MainActor
    func testScrollIsScopedToZoomedViewport() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 456),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = PhotoScrollEventView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView!.addSubview(view)
        defer { view.removeFromSuperview() }
        var received: [CGSize] = []
        view.onScroll = { received.append($0) }
        let delta = CGSize(width: 12, height: -24)
        let inside = CGPoint(x: 300, y: 200)

        XCTAssertFalse(view.handleScroll(at: inside, in: window, delta: delta, isPrecise: true))
        view.isEnabled = true
        XCTAssertTrue(view.handleScroll(at: inside, in: window, delta: delta, isPrecise: true))
        XCTAssertEqual(received, [delta])
        // The Done/header strip must never be intercepted by photo input.
        XCTAssertFalse(view.handleScroll(at: CGPoint(x: 300, y: 428), in: window,
                                        delta: delta, isPrecise: true))
        XCTAssertFalse(view.handleScroll(at: inside, in: nil, delta: delta, isPrecise: true))
        view.isHidden = true
        XCTAssertFalse(view.handleScroll(at: inside, in: window, delta: delta, isPrecise: true))
        XCTAssertEqual(received.count, 1)
        XCTAssertNil(view.hitTest(inside), "The scroll observer must not steal button or drag hits")
    }
}
