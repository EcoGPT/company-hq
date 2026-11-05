import SwiftUI

// The shared page furniture every HQ pin is built from: the 28pt page
// header, grouped cards with hairline edges, inset rows, capsule buttons.
// The vocabulary is the web app's (hover = surfaceHover, one muted sentence
// for empty states, capsules for every control); the construction is iOS's
// (continuous corners, grouped cards, glass on macOS 26).

// MARK: - Page scaffold

/// The web listing-page title: 28pt medium, tight tracking, with the page's
/// actions on the trailing edge — never a toolbar row of its own.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.x3) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                trailing.fixedSize()
            }
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                heading
                trailing
            }
        }
        .hqGlassContainer()
    }

    private var heading: some View {
        Text(title)
            .font(Tokens.Typography.pageTitle)
            .tracking(Tokens.Typography.pageTitleTracking)
            .foregroundStyle(Tokens.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A section's name above its card — lighter than the rows it introduces,
/// no uppercase, no letterspacing (the web rule).
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Tokens.Typography.sectionLabel)
            .foregroundStyle(Tokens.Palette.inkTertiary)
            .padding(.leading, Tokens.Space.x2)
    }
}

/// One muted sentence, centered, nothing else — the web's whole empty-state
/// language. No icons, no illustrations.
struct EmptyStateText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(Tokens.Typography.row)
            .foregroundStyle(Tokens.Palette.inkSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.Space.x6)
    }
}

// MARK: - Cards

extension View {
    /// A readable content group. Floating cards use hqGlassCard instead.
    func hqCard(cornerRadius: CGFloat = Tokens.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(shape)
            .background(Tokens.Palette.surfaceInput, in: shape)
            .overlay(shape.strokeBorder(Tokens.Palette.borderLight, lineWidth: 1))

    }
}

/// The hairline between rows in a card, inset past the row's leading art
/// so the line hangs from the text column like iOS grouped lists.
struct RowDivider: View {
    var inset: CGFloat = Tokens.Space.x4

    var body: some View {
        Rectangle()
            .fill(Tokens.Palette.borderLight)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

// MARK: - Small pieces

/// The iOS Settings-style icon tile: a continuous rounded square wearing a
/// tint gradient and a white symbol. Neutral style for quiet rows.
struct IconTile: View {
    enum Style {
        case tinted(Color)
        case neutral
    }

    let symbol: String
    let style: Style
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            switch style {
            case .tinted(let tint):
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(tint.gradient)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            case .neutral:
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(Tokens.Palette.surfaceHover)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.40, weight: .medium))
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A count in a quiet capsule, for card headers.
struct CountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Tokens.Typography.captionEmphasis)
            .foregroundStyle(Tokens.Palette.inkSecondary)
            .padding(.horizontal, Tokens.Space.x2)
            .padding(.vertical, 2)
            .background(Tokens.Palette.surfaceHover, in: Capsule())
    }
}

/// The calendar-app date lozenge: weekday over day-of-month. `nil` renders
/// the open-room variant (no date, just the calendar mark).
struct CalendarDateTile: View {
    let date: Date?
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                .fill(Tokens.Palette.surfaceHover)
            if let date {
                VStack(spacing: 0) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(Tokens.Typography.dateTileWeekday)
                        .foregroundStyle(Tokens.Palette.danger)
                    Text(date.formatted(.dateTime.day()))
                        .font(Tokens.Typography.dateTileDay)
                        .foregroundStyle(Tokens.Palette.ink)
                }
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        }
        .frame(width: size, height: size)
        #if os(iOS)
        .dynamicTypeSize(...DynamicTypeSize.large)
        #endif
    }
}

/// The pulsing live mark: a green dot with LIVE beside it. The pulse runs
/// only while the window is drawn — HQ hides all day behind ⌘⇧E, and a
/// repeatForever in a hidden window still animates at full frame rate.
struct LiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    var body: some View {
        WindowVisibilityReader { isVisible in
            HStack(spacing: Tokens.Space.x1) {
                // The pulsing dot LEAVES the tree while the window is not
                // being drawn — a running repeatForever is not reliably
                // superseded in place, but a removed view's animation dies
                // with it, and reinsertion restarts it through onAppear.
                if isVisible && !shouldReduceMotion {
                    BreathingLiveDot()
                } else {
                    Circle()
                        .fill(Tokens.Palette.live)
                        .frame(width: 7, height: 7)
                }
                Text("LIVE")
                    .font(Tokens.Typography.badge)
                    .foregroundStyle(Tokens.Palette.live)
            }
        }
    }
}

private struct BreathingLiveDot: View {
    @State private var isBreathing = false

    var body: some View {
        Circle()
            .fill(Tokens.Palette.live)
            .frame(width: 7, height: 7)
            .opacity(isBreathing ? 0.4 : 1)
            .animation(
                .easeInOut(duration: 1).repeatForever(autoreverses: true),
                value: isBreathing
            )
            .onAppear { isBreathing = true }
    }
}

// MARK: - Buttons

/// Tracks hover and enablement for button styles, which cannot hold state
/// or read the environment themselves.
private struct HoverReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion

    var body: some View {
        content(isHovering && isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 }
            .transaction { if shouldReduceMotion { $0.animation = nil } }
    }
}

private extension View {
    func pressFeedback(_ isPressed: Bool) -> some View {
        scaleEffect(isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: Tokens.Motion.press), value: isPressed)
    }
}

/// The web's neutral primary CTA: near-black capsule in light, white in
/// dark, hover dims to 90%.
struct ActionCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { isHovering in
            configuration.label
                .font(Tokens.Typography.button)
                .foregroundStyle(Tokens.Palette.actionInk)
                .padding(.horizontal, Tokens.Space.x4)
                .hqControlHeight(Tokens.Layout.controlHeight)
                .hqGlass(in: Capsule(), tint: Tokens.Palette.action, interactive: true)
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.8 : isHovering ? 0.9 : 1)
                .pressFeedback(configuration.isPressed)
        }
    }
}

/// A tinted capsule that is still glass on macOS 26; below, a flat tint
/// with the hand-drawn rim. White label either way.
struct TintedCapsuleButtonStyle: ButtonStyle {
    let tint: Color
    var height: CGFloat = Tokens.Layout.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { isHovering in
            let label = configuration.label
                .font(Tokens.Typography.button)
                .foregroundStyle(.white)
                .padding(.horizontal, Tokens.Space.x4)
                .hqControlHeight(height)
            label
                .hqGlass(in: Capsule(), tint: tint, interactive: true)
                .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : isHovering ? 0.92 : 1)
            .pressFeedback(configuration.isPressed)
        }
    }
}

/// The quiet secondary control: surfaceHover capsule, surfaceActive on
/// hover — the web's whole interaction language.
struct QuietCapsuleButtonStyle: ButtonStyle {
    var height: CGFloat = Tokens.Layout.controlHeight
    var ink: Color = Tokens.Palette.ink

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { isHovering in
            configuration.label
                .font(Tokens.Typography.button)
                .foregroundStyle(ink)
                .padding(.horizontal, Tokens.Space.x3)
                .hqControlHeight(height)
                .hqGlass(in: Capsule(), interactive: true)
                .opacity(configuration.isPressed ? 0.8 : isHovering ? 0.9 : 1)
                .contentShape(Capsule())
                .pressFeedback(configuration.isPressed)
        }
    }
}

/// A bare row press target that highlights on hover, clipped by its card.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { isHovering in
            configuration.label
                .background(
                    isHovering || configuration.isPressed
                        ? Tokens.Palette.surfaceHover : .clear
                )
        }
    }
}

// MARK: - Segmented control

/// The web mode-switch: a capsule track holding capsule chips, the selected
/// chip lighter than its track in both themes.
struct IconSegmentedControl: View {
    struct Option {
        let id: String
        let symbol: String
        let help: String
    }

    let options: [Option]
    @Binding var selection: String

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(options, id: \.id) { option in
                Image(systemName: option.symbol)
                    .help(option.help)
                    .accessibilityLabel(option.help)
                    .tag(option.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The web mode-switch with words instead of icons — for segments that are
/// tabs ("Data" | "Chat"), not tools.
struct TextSegmentedControl: View {
    struct Option {
        let id: String
        let title: String
    }

    let options: [Option]
    @Binding var selection: String

    var body: some View {
        Picker("Section", selection: $selection) {
            ForEach(options, id: \.id) { option in
                Text(option.title).tag(option.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// A scrolling row of filter chips — a list's categories. Selected wears the web's neutral action capsule; the rest
/// are quiet capsules, hover language and all.
struct FilterChipRow: View {
    struct Option: Hashable {
        let id: String
        let title: String
    }

    @ScaledMetric(relativeTo: .caption) private var visualHeight = Tokens.Layout.filterVisualHeight

    let options: [Option]
    @Binding var selection: String
    /// Where the first chip starts: a list whose rows sit on a wider gutter
    /// passes it, so the chips line up with the rows under them.
    var inset: CGFloat = Tokens.Space.x3

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Glass.spacing) {
                ForEach(options, id: \.id) { option in
                    chip(option)
                }
            }
            .padding(.horizontal, inset)
            .hqGlassContainer()
        }
        .scrollClipDisabled()
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chip(_ option: Option) -> some View {
        let isSelected = selection == option.id
        return Button {
            selection = option.id
        } label: {
            Text(option.title)
                .font(Tokens.Typography.captionEmphasis)
                .foregroundStyle(isSelected ? Tokens.Palette.accent : Tokens.Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Tokens.Space.x3)
                .frame(minHeight: visualHeight)
                .hqGlass(in: Capsule(), tint: isSelected ? Tokens.Palette.accent.opacity(0.18) : .clear, interactive: true)
                .hqMinimumControlTarget()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Chat primitives

/// The message bubble's geometry and colours, in one place. The Mac and phone
/// chat views both draw through this, so "the same as a chat bubble"
/// stays true by construction instead of by two views agreeing to match.
struct ChatBubble<Content: View>: View {
    let isOwn: Bool
    var isMuted = false
    @ViewBuilder var content: Content

    static var radius: CGFloat { 18 }

    var body: some View {
        content
            .font(.system(size: 14))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    }

    private var foreground: some ShapeStyle {
        if isMuted { return AnyShapeStyle(.secondary) }
        return isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
    }

    private var background: some ShapeStyle {
        if isMuted { return AnyShapeStyle(.quinary) }
        return isOwn ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(.quinary)
    }
}

private extension View {
    @ViewBuilder
    func hqControlHeight(_ height: CGFloat) -> some View {
        #if os(iOS)
        self.padding(.vertical, 8).frame(minHeight: max(height, 44))
        #else
        self.frame(height: height)
        #endif
    }
}
