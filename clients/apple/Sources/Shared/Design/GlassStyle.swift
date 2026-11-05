import SwiftUI

extension View {
    @ViewBuilder
    func hqMinimumControlTarget() -> some View {
        #if os(iOS)
        self.frame(minWidth: 44, minHeight: 44)
        #else
        self.frame(minWidth: 24, minHeight: 24)
        #endif
    }

    @ViewBuilder
    func hqGlassContainer() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: Tokens.Glass.spacing) { self }
        } else {
            self
        }
    }

    /// Cards share native optical depth; never layer a custom drop shadow over glass.
    func hqGlassCard(interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Glass.cardRadius, style: .continuous)
        return clipShape(shape).hqGlass(in: shape, interactive: interactive)
    }

    func hqCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(Tokens.Palette.surface)
    }

    /// A neutral editor surface. Native glass owns its edge and elevation;
    /// material and opaque fallbacks retain a contrast outline.
    func hqComposerGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(HQComposerGlass(shape: shape, isInteractive: interactive))
    }

    /// One native glass treatment for floating controls on both platforms, with a material
    /// fallback and an opaque surface when Reduce Transparency is enabled.
    func hqGlass<S: Shape>(in shape: S, tint: Color = .clear, interactive: Bool = false) -> some View {
        modifier(HQGlass(shape: shape, tint: tint, isInteractive: interactive))
    }
}

private struct HQGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var shouldReduceTransparency
    let shape: S
    let tint: Color
    let isInteractive: Bool

    private var shouldUseOpaqueSurface: Bool {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            // Any debug launch, fixture or live: cacheDisplay cannot capture glass.
            if ProcessInfo.processInfo.environment["HQ_UI_OPAQUE"] == "1" {
                return true
            }
        #endif
        return shouldReduceTransparency
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if shouldUseOpaqueSurface {
            content
                .background(tint, in: shape)
                .background(Tokens.Palette.surfaceInput, in: shape)
                .overlay(shape.stroke(Tokens.Palette.borderLight, lineWidth: 1))
        } else if #available(macOS 26.0, iOS 26.0, *) {
            let glass: Glass = tint == .clear ? .regular : .regular.tint(tint)
            content.glassEffect(isInteractive ? glass.interactive() : glass, in: shape)
        } else {
            content.background(tint, in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Tokens.Palette.borderLight, lineWidth: 1))
        }
    }
}

private struct HQComposerGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var shouldReduceTransparency
    let shape: S
    let isInteractive: Bool

    private var shouldUseOpaqueSurface: Bool {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if ProcessInfo.processInfo.environment["HQ_UI_OPAQUE"] == "1" { return true }
        #endif
        return shouldReduceTransparency
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if shouldUseOpaqueSurface {
            content
                .background(Tokens.Palette.surfaceInput, in: shape)
                .overlay(shape.stroke(Tokens.Palette.borderLight, lineWidth: 1))
        } else if #available(macOS 26.0, iOS 26.0, *) {
            content
                .glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Tokens.Palette.borderLight, lineWidth: 0.5))
        }
    }
}
