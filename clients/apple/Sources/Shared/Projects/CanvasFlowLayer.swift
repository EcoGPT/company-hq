import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The flowing dash over the canvas's busy lines, drawn with Core Animation.
//
// It used to be a `TimelineView(.animation(minimumInterval: 1/30))` around a `Canvas`: a SwiftUI
// update and a main-thread commit 30 times a second for as long as the page was open (Control
// flows every open item's line, and Control is the Tasks home). A `CABasicAnimation` on a shape
// layer's `lineDashPhase` is advanced by the render server, so the app commits nothing per frame.
// The layers are rebuilt only when the lines change, and the animation exists only while motion
// is allowed, the window is drawn and the canvas is on screen (`docs/architecture.md`: a repeating
// animation runs while the window is hidden).

/// One line's flowing dash: drawn over its still line, in its colour.
struct FlowingLine: Equatable {
    let path: Path
    let color: Color
    let width: CGFloat
}

/// The flowing dash over the lines that carry work now: Agents' active sessions, Control's open
/// items. The dash exists only while motion is allowed, the window is drawn and the canvas is on
/// screen; otherwise the still lines under it are all there is. The dash travels from a path's
/// start to its end. It takes no clicks.
struct CanvasFlowLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lines: [FlowingLine]
    let isOnScreen: Bool

    var body: some View {
        if !lines.isEmpty {
            WindowVisibilityReader { isWindowDrawn in
                // Always in the tree, so the window probe stays in it (see `WindowVisibilityReader`);
                // the layers draw nothing and run nothing while `flows` is false.
                CanvasFlowHost(lines: lines, flows: (isWindowDrawn || Self.forcesFlow) && isOnScreen && !reduceMotion)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// `HQ_UI_CANVAS_FLOW=1` keeps the dash running in a fixture window that macOS
    /// reports as not drawn (a snapshot launch has no visible window).
    private static var forcesFlow: Bool {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            return HQSimulatorFixture.isEnabled && ProcessInfo.processInfo.environment["HQ_UI_CANVAS_FLOW"] == "1"
        #else
            return false
        #endif
    }
}

// MARK: - Layers

/// One `CAShapeLayer` per stroke (colour and width), each holding every flowing path of that
/// stroke, with a repeating `lineDashPhase` animation.
///
/// The SwiftUI original, number by number:
/// - dash `[3, 13]`, round caps                 -> `dash`, `lineCap`
/// - `dashPhase = -((t * 14) mod 16)`, so the dash travels from the path's start to its end at
///   14 points a second                         -> `lineDashPhase` 0 -> -16 over 16 / 14 s, linear,
///   repeating forever
/// - `minimumInterval: 1/30`                    -> `preferredFrameRateRange` up to 30 a second, so
///   the render server does not step it at a ProMotion display's 120
/// Every layer starts from the same instant (`epoch`), so lines added or taken out mid-flow
/// (a drag) keep the phase of the rest.
@MainActor
final class CanvasFlowLayers {
    static let dash: [CGFloat] = [3, 13]
    static let period: CGFloat = 16
    /// Points a second the dashes travel.
    static let speed: Double = 14
    static let duration: CFTimeInterval = Double(period) / speed
    private static let epoch = CACurrentMediaTime()

    /// The layer a host view hangs in its tree.
    let root = CALayer()
    private var layers: [Stroke: CAShapeLayer] = [:]
    private var applied: [FlowingLine] = []
    private var appliedColors: [Color.Resolved] = []
    private var wantsRunning = false

    private struct Stroke: Hashable {
        let color: Color.Resolved
        let width: CGFloat
    }

    init() {
        root.isHidden = true
        root.actions = ["hidden": NSNull()]
    }

    /// Rebuilds the paths when the lines or their resolved colours changed; otherwise nothing.
    func update(lines: [FlowingLine], environment: EnvironmentValues) {
        let colors = lines.map { $0.color.resolve(in: environment) }
        guard lines != applied || colors != appliedColors else { return }
        applied = lines
        appliedColors = colors

        var order: [Stroke] = []
        var paths: [Stroke: CGMutablePath] = [:]
        for (line, color) in zip(lines, colors) {
            let stroke = Stroke(color: color, width: line.width)
            if paths[stroke] == nil {
                paths[stroke] = CGMutablePath()
                order.append(stroke)
            }
            paths[stroke]?.addPath(line.path.cgPath)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for stroke in layers.keys where paths[stroke] == nil {
            layers[stroke]?.removeFromSuperlayer()
            layers[stroke] = nil
        }
        for stroke in order {
            let layer = layers[stroke] ?? makeLayer(stroke)
            layers[stroke] = layer
            layer.path = paths[stroke]
        }
        // In the order the lines came, so overlapping strokes always stack the same way.
        root.sublayers = order.compactMap { layers[$0] }
        CATransaction.commit()
    }

    /// Fits the layers to the host view: paths are in the canvas's own coordinates.
    func layout(size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        for layer in layers.values {
            layer.frame = root.bounds
            layer.contentsScale = scale
        }
        CATransaction.commit()
    }

    /// Runs (and shows) the dash only while asked to; a layer that is not running does no work.
    /// Safe to call again: a running layer keeps its animation, and one that lost it (an iOS app
    /// back from the background) gets it back.
    func setRunning(_ running: Bool) {
        wantsRunning = running
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if root.isHidden == running { root.isHidden = !running }
        CATransaction.commit()
        for layer in layers.values {
            if running {
                addAnimation(to: layer)
            } else {
                layer.removeAnimation(forKey: "flow")
            }
        }
    }

    private func makeLayer(_ stroke: Stroke) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = stroke.color.cgColor
        layer.lineWidth = stroke.width
        layer.lineCap = .round
        layer.lineDashPattern = Self.dash.map { NSNumber(value: Double($0)) }
        layer.frame = root.bounds
        layer.contentsScale = root.contentsScale
        if wantsRunning { addAnimation(to: layer) }
        return layer
    }

    private func addAnimation(to layer: CAShapeLayer) {
        guard layer.animation(forKey: "flow") == nil else { return }
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = -Self.period
        animation.duration = Self.duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        animation.beginTime = layer.convertTime(Self.epoch, from: nil)
        layer.add(animation, forKey: "flow")
    }
}

// MARK: - Hosts

#if os(macOS)

private final class FlowHostView: NSView {
    let layers = CanvasFlowLayers()
    var flows = false { didSet { if flows != oldValue { refreshRunning() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(layers.root)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The canvas's coordinates run down from the top-left, as SwiftUI's paths do.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layers.layout(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        refreshRunning()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func refreshRunning() { layers.setRunning(flows && window != nil) }
}

private struct CanvasFlowHost: NSViewRepresentable {
    let lines: [FlowingLine]
    let flows: Bool

    func makeNSView(context: Context) -> NSView {
        let view = FlowHostView()
        view.layers.update(lines: lines, environment: context.environment)
        view.flows = flows
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? FlowHostView else { return }
        view.layers.update(lines: lines, environment: context.environment)
        view.flows = flows
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

#else

private final class FlowHostView: UIView {
    let layers = CanvasFlowLayers()
    var flows = false { didSet { if flows != oldValue { refreshRunning() } } }
    private var foreground: (any NSObjectProtocol)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(layers.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layers.layout(size: bounds.size, scale: window?.screen.scale ?? traitCollection.displayScale)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        refreshRunning()
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
        foreground = nil
        guard window != nil else { return }
        // An app that was backgrounded comes back without its layer animations.
        foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRunning() }
        }
    }

    private func refreshRunning() { layers.setRunning(flows && window != nil) }
}

private struct CanvasFlowHost: UIViewRepresentable {
    let lines: [FlowingLine]
    let flows: Bool

    func makeUIView(context: Context) -> UIView {
        let view = FlowHostView()
        view.layers.update(lines: lines, environment: context.environment)
        view.flows = flows
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? FlowHostView else { return }
        view.layers.update(lines: lines, environment: context.environment)
        view.flows = flows
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

#endif
