import SwiftUI
import UIKit

/// Native scrolling keeps pinch, one/two-finger panning and deceleration
/// together, with a viewport that cannot intercept the navigation bar.
struct PhotoZoomScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> PhotoZoomView {
        PhotoZoomView()
    }

    func updateUIView(_ view: PhotoZoomView, context: Context) {
        view.setImage(image)
    }
}

final class PhotoZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var viewportSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        // At fit, horizontal swipes belong to the surrounding photo pager.
        panGestureRecognizer.isEnabled = false
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        viewportSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        if viewportSize != bounds.size {
            // Refit on rotation/resizing, and when a different photo loads.
            viewportSize = bounds.size
            setZoomScale(1, animated: false)
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(
                width: image.size.width * fit, height: image.size.height * fit
            ))
            contentSize = imageView.bounds.size
            centerImage()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        } else {
            centerImage()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale
        centerImage()
    }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
