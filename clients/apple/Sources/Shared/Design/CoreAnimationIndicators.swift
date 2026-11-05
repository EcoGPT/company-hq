import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The transcript's two live indicators — the agent shimmer and the typing
// dots — drawn with Core Animation instead of SwiftUI's repeatForever.
//
// Why: a SwiftUI animation re-runs the view graph on every display frame,
// and in the eager transcript every frame re-asks each bubble for its size
// (the 4-11 ms pass at 80-200 rows that was measured,
// 60-120 times a second whenever an agent works in the open chat). A
// `CABasicAnimation` on a layer is advanced by the render server: no SwiftUI
// transaction, no layout, no main-thread work per frame.
//
// Both indicators keep every number the SwiftUI versions had; the mapping is
// spelled out beside each constant. The callers keep their
// `WindowVisibilityReader` gate, so the views still leave the tree while the
// window is not drawn — and the layers stop on their own the moment their
// view leaves a window, which covers any other way of going off screen.

// MARK: - Shimmer

/// The band of light that sweeps across a label, masked to its glyphs.
///
/// SwiftUI original (`ShimmerBand`), parameter by parameter:
/// - gradient `[.clear, ink.opacity(0.8), .clear]`, leading to trailing,
///   evenly spaced (stops 0, 0.5, 1)           -> `colors` / `peakOpacity`
/// - band width `0.55 *` the label's width     -> `bandFraction`
/// - `phase` -1 -> 1, `offset(x: phase * 1.5 * width)`, so the band's left
///   edge travels from -1.5 W to +1.5 W        -> `startPoint`/`endPoint` x,
///   in the gradient layer's unit space, so the motion is a FRACTION of the
///   width and survives the label changing width (the work row's headline
///   changes every second) without restarting
/// - `.linear(duration: 1.8)`, `repeatForever(autoreverses: false)`
///                                              -> `duration`, `.linear`,
///   `repeatCount = .infinity`, `autoreverses = false`
/// - `.mask(Text(text).font(font))`             -> the same `Text`, drawn to
///   an image by `ImageRenderer` at the label's size and the screen's scale,
///   used as the gradient layer's mask. A `CATextLayer` would shape the
///   glyphs differently; this is SwiftUI's own text.
@MainActor
final class ShimmerBandLayers {
    static let bandFraction: CGFloat = 0.55
    static let travel: CGFloat = 1.5
    static let duration: CFTimeInterval = 1.8
    static let peakOpacity: CGFloat = 0.8

    /// The layer a host view hangs in its tree.
    let root = CALayer()
    private let band = CAGradientLayer()
    private let glyphMask = CALayer()

    private var text = ""
    private var font: Font = .system(size: 13)
    /// Bold Text and right-to-left change how the same glyphs are drawn, and
    /// the mask is rendered outside the label's environment, so both are
    /// handed in and are part of the mask's key.
    private var legibilityWeight: LegibilityWeight?
    private var layoutDirection: LayoutDirection = .leftToRight
    private var size: CGSize = .zero
    private var scale: CGFloat = 2
    private var renderedMask: MaskKey?
    private var wantsRunning = false

    private struct MaskKey: Equatable {
        let text: String
        let font: Font
        let size: CGSize
        let scale: CGFloat
        let legibilityWeight: LegibilityWeight?
        let layoutDirection: LayoutDirection
    }

    init() {
        band.startPoint = Self.start(atPhase: -1)
        band.endPoint = Self.end(atPhase: -1)
        band.mask = glyphMask
        glyphMask.contentsGravity = .resize
        root.addSublayer(band)
        // Nothing shows until the glyph mask exists: an unmasked band would
        // flash as a plain rectangle of light.
        root.isHidden = true
        root.actions = ["hidden": NSNull()]
    }

    /// Where the band's left and right edges sit, in the gradient layer's
    /// unit space, for a SwiftUI `phase` of -1...1.
    static func start(atPhase phase: CGFloat) -> CGPoint {
        CGPoint(x: phase * travel, y: 0.5)
    }

    static func end(atPhase phase: CGFloat) -> CGPoint {
        CGPoint(x: phase * travel + bandFraction, y: 0.5)
    }

    func setInk(_ ink: CGColor) {
        let peak = ink.copy(alpha: Self.peakOpacity * ink.alpha)
        // Both ends are the ink itself at zero alpha, so the fade is in
        // alpha only and never passes through a grey.
        let clear = ink.copy(alpha: 0)
        guard let peak, let clear else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.colors = [clear, peak, clear]
        CATransaction.commit()
    }

    func update(
        text: String, font: Font,
        legibilityWeight: LegibilityWeight? = nil, layoutDirection: LayoutDirection = .leftToRight
    ) {
        self.text = text
        self.font = font
        self.legibilityWeight = legibilityWeight
        self.layoutDirection = layoutDirection
    }

    /// Fits the layers to the host view and (re)draws the glyph mask when
    /// the text, font, size or scale changed.
    func layout(size: CGSize, scale: CGFloat) {
        self.size = size
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        band.frame = root.bounds
        glyphMask.frame = band.bounds
        glyphMask.contentsScale = scale
        let key = MaskKey(
            text: text, font: font, size: size, scale: scale,
            legibilityWeight: legibilityWeight, layoutDirection: layoutDirection
        )
        if key != renderedMask {
            renderedMask = key
            if let image = Self.glyphs(
                text: text, font: font, size: size, scale: scale,
                legibilityWeight: legibilityWeight, layoutDirection: layoutDirection
            ) {
                glyphMask.contents = image
                root.isHidden = false
            }
        }
        CATransaction.commit()
        if wantsRunning { startIfNeeded() }
    }

    /// SwiftUI's rendering of the label's text, alpha only. Drawn black on
    /// purpose: SwiftUI's own `.mask` takes the glyph coverage as if the text
    /// were black whatever its colour or the scheme (measured: black matches
    /// the old mask to 1-3/255 in light and dark; white or primary differ by
    /// up to 46), so black is what reproduces its edges.
    static func glyphs(
        text: String, font: Font, size: CGSize, scale: CGFloat,
        legibilityWeight: LegibilityWeight? = nil, layoutDirection: LayoutDirection = .leftToRight
    ) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = ImageRenderer(
            content: Text(text).font(font).foregroundStyle(.black)
                .frame(width: size.width, height: size.height)
                .environment(\.legibilityWeight, legibilityWeight)
                .environment(\.layoutDirection, layoutDirection)
        )
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// Runs while the host is in a window; a layer out of a window does no work.
    func setRunning(_ running: Bool) {
        wantsRunning = running
        if running {
            // Re-adding is how a backgrounded iOS app gets its animations back.
            band.removeAnimation(forKey: "start")
            band.removeAnimation(forKey: "end")
            startIfNeeded()
        } else {
            band.removeAnimation(forKey: "start")
            band.removeAnimation(forKey: "end")
        }
    }

    private func startIfNeeded() {
        guard band.animation(forKey: "start") == nil else { return }
        band.add(Self.sweep("startPoint", from: Self.start(atPhase: -1), to: Self.start(atPhase: 1)), forKey: "start")
        band.add(Self.sweep("endPoint", from: Self.end(atPhase: -1), to: Self.end(atPhase: 1)), forKey: "end")
    }

    private static func sweep(_ keyPath: String, from: CGPoint, to: CGPoint) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.repeatCount = .infinity
        animation.autoreverses = false
        animation.isRemovedOnCompletion = false
        return animation
    }
}

// MARK: - Breathing dots

/// Three dots that breathe in a travelling wave.
///
/// SwiftUI original (`BreathingDots`), parameter by parameter:
/// - three `Circle()` of 7 x 7, HStack spacing 5  -> `diameter`, `spacing`
/// - fill `.secondary`                            -> `dotColor` (see hosts)
/// - opacity 0.35 -> 1, scale 0.72 -> 1           -> `restOpacity`, `restScale`
/// - `.easeInOut(duration: 0.6)`                  -> `duration`, and the
///   (0.42, 0, 0.58, 1) curve SwiftUI's `.easeInOut` is
/// - `.repeatForever(autoreverses: true)`         -> `repeatCount = .infinity`,
///   `autoreverses = true`
/// - `.delay(index * 0.18)`, applied once at the start (it is the last
///   modifier on the animation)                   -> `beginTime` offset, with
///   `fillMode = .backwards` holding the rest values until it begins
@MainActor
final class BreathingDotsLayers {
    static let diameter: CGFloat = 7
    static let spacing: CGFloat = 5
    static let count = 3
    static let restOpacity: Float = 0.35
    static let restScale: CGFloat = 0.72
    static let duration: CFTimeInterval = 0.6
    static let stagger: CFTimeInterval = 0.18

    /// What the three dots occupy: the same 31 x 7 the HStack gave them.
    static var size: CGSize {
        CGSize(
            width: CGFloat(count) * diameter + CGFloat(count - 1) * spacing,
            height: diameter
        )
    }

    let root = CALayer()
    private let dots: [CALayer]
    private var wantsRunning = false

    init() {
        var made: [CALayer] = []
        for index in 0..<Self.count {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
            dot.position = CGPoint(
                x: CGFloat(index) * (Self.diameter + Self.spacing) + Self.diameter / 2,
                y: Self.diameter / 2
            )
            dot.cornerRadius = Self.diameter / 2
            dot.opacity = Self.restOpacity
            dot.transform = CATransform3DMakeScale(Self.restScale, Self.restScale, 1)
            root.addSublayer(dot)
            made.append(dot)
        }
        dots = made
        root.bounds = CGRect(origin: .zero, size: Self.size)
        root.anchorPoint = .zero
    }

    func setColor(_ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots { dot.backgroundColor = color }
        CATransaction.commit()
    }

    func setRunning(_ running: Bool) {
        wantsRunning = running
        for (index, dot) in dots.enumerated() {
            dot.removeAnimation(forKey: "fade")
            dot.removeAnimation(forKey: "grow")
            guard running else { continue }
            let begin = dot.convertTime(CACurrentMediaTime(), from: nil) + Double(index) * Self.stagger
            dot.add(
                Self.breath("opacity", from: Self.restOpacity, to: Float(1), begin: begin),
                forKey: "fade"
            )
            dot.add(
                Self.breath("transform.scale", from: Self.restScale, to: CGFloat(1), begin: begin),
                forKey: "grow"
            )
        }
    }

    private static func breath(
        _ keyPath: String, from: Any, to: Any, begin: CFTimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.beginTime = begin
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = false
        return animation
    }
}

// MARK: - Hosts

#if os(macOS)

private final class ShimmerHostView: NSView {
    let layers = ShimmerBandLayers()
    var ink: Color = .primary { didSet { refreshColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(layers.root)
        setAccessibilityElement(false)
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        refreshColors()
        needsLayout = true
        layers.setRunning(window != nil)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layers.setInk(NSColor(ink).cgColor)
        }
    }
}

struct ShimmerBandView: NSViewRepresentable {
    let text: String
    let font: Font
    let ink: Color

    func makeNSView(context: Context) -> NSView {
        let view = ShimmerHostView()
        view.ink = ink
        view.layers.update(
            text: text, font: font,
            legibilityWeight: context.environment.legibilityWeight,
            layoutDirection: context.environment.layoutDirection
        )
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ShimmerHostView else { return }
        view.layers.update(
            text: text, font: font,
            legibilityWeight: context.environment.legibilityWeight,
            layoutDirection: context.environment.layoutDirection
        )
        view.ink = ink
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        // It decorates a label that already has its size: take it as offered.
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

private final class DotsHostView: NSView {
    let layers = BreathingDotsLayers()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(layers.root)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { BreathingDotsLayers.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layers.root.position = .zero
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
        needsLayout = true
        layers.setRunning(window != nil)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        // SwiftUI's `.secondary` is the secondary label colour.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layers.setColor(NSColor.secondaryLabelColor.cgColor)
        }
    }
}

struct BreathingDotsView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DotsHostView() }
    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        BreathingDotsLayers.size
    }
}

#else

private final class ShimmerHostView: UIView {
    let layers = ShimmerBandLayers()
    var ink: Color = .primary { didSet { refreshColors() } }
    private var foreground: (any NSObjectProtocol)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(layers.root)
        refreshColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShimmerHostView, _) in
            view.refreshColors()
        }
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
        refreshColors()
        setNeedsLayout()
        layers.setRunning(window != nil)
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
        foreground = nil
        guard window != nil else { return }
        // An app that was backgrounded comes back without its layer animations.
        foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else { return }
                self.layers.setRunning(true)
            }
        }
    }

    func refreshColors() {
        layers.setInk(UIColor(ink).resolvedColor(with: traitCollection).cgColor)
    }
}

struct ShimmerBandView: UIViewRepresentable {
    let text: String
    let font: Font
    let ink: Color

    func makeUIView(context: Context) -> UIView {
        let view = ShimmerHostView()
        view.ink = ink
        view.layers.update(
            text: text, font: font,
            legibilityWeight: context.environment.legibilityWeight,
            layoutDirection: context.environment.layoutDirection
        )
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? ShimmerHostView else { return }
        view.layers.update(
            text: text, font: font,
            legibilityWeight: context.environment.legibilityWeight,
            layoutDirection: context.environment.layoutDirection
        )
        view.ink = ink
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

private final class DotsHostView: UIView {
    let layers = BreathingDotsLayers()
    private var foreground: (any NSObjectProtocol)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(layers.root)
        refreshColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DotsHostView, _) in
            view.refreshColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
    }

    override var intrinsicContentSize: CGSize { BreathingDotsLayers.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        layers.root.position = .zero
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshColors()
        setNeedsLayout()
        layers.setRunning(window != nil)
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
        foreground = nil
        guard window != nil else { return }
        foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else { return }
                self.layers.setRunning(true)
            }
        }
    }

    func refreshColors() {
        // SwiftUI's `.secondary` is the secondary label colour.
        layers.setColor(UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor)
    }
}

struct BreathingDotsView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { DotsHostView() }
    func updateUIView(_ view: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        BreathingDotsLayers.size
    }
}

#endif
