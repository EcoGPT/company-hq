import UIKit
import XCTest

final class PhotoZoomTests: XCTestCase {
    @MainActor
    func testZoomPanFitAndToolbarHitTesting() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let done = UIButton(frame: CGRect(x: 16, y: 0, width: 80, height: 56))
        root.addSubview(done)
        let photo = PhotoZoomView(frame: CGRect(x: 0, y: 56, width: 390, height: 788))
        root.addSubview(photo)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        photo.setImage(image)
        photo.layoutIfNeeded()
        XCTAssertEqual(photo.zoomScale, 1)
        XCTAssertFalse(photo.panGestureRecognizer.isEnabled, "Fit-mode swipes belong to the photo pager")

        photo.setZoomScale(4, animated: false)
        photo.layoutIfNeeded()
        XCTAssertTrue(photo.panGestureRecognizer.isEnabled)
        XCTAssertGreaterThan(photo.contentSize.width, photo.bounds.width)
        XCTAssertGreaterThan(photo.contentSize.height, photo.bounds.height)
        photo.setContentOffset(CGPoint(x: 120, y: 90), animated: false)
        photo.layoutIfNeeded()
        XCTAssertEqual(photo.contentOffset.x, 120, accuracy: 0.1)
        XCTAssertEqual(photo.contentOffset.y, 90, accuracy: 0.1)
        XCTAssertTrue(root.hitTest(CGPoint(x: 40, y: 28), with: nil) === done)
        XCTAssertTrue(photo.clipsToBounds)

        // A routine SwiftUI update must preserve the user's zoom and pan.
        photo.setImage(image)
        photo.layoutIfNeeded()
        XCTAssertEqual(photo.zoomScale, 4)
        XCTAssertEqual(photo.contentOffset.x, 120, accuracy: 0.1)

        photo.setZoomScale(1, animated: false)
        photo.layoutIfNeeded()
        XCTAssertFalse(photo.panGestureRecognizer.isEnabled)
        XCTAssertEqual(photo.imageView.frame.midX + photo.contentInset.left, photo.bounds.width / 2,
                       accuracy: 0.1)
    }

    @MainActor
    func testViewportResizeRefitsImage() {
        let photo = PhotoZoomView(frame: CGRect(x: 0, y: 0, width: 390, height: 788))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { _ in }
        photo.setImage(image)
        photo.layoutIfNeeded()
        photo.setZoomScale(3, animated: false)
        photo.frame.size = CGSize(width: 788, height: 390)
        photo.setNeedsLayout()
        photo.layoutIfNeeded()
        XCTAssertEqual(photo.zoomScale, 1)
        XCTAssertEqual(photo.imageView.frame.height, 390, accuracy: 0.1)
        XCTAssertFalse(photo.panGestureRecognizer.isEnabled)
    }
}
