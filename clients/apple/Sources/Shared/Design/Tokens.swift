#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// The HQ design language: the web app's measured token system (surface and
// ink ladders, hairline borders, capsule geometry) carried onto macOS with
// iOS 26 structure — continuous corners, grouped cards, Liquid Glass where
// the OS offers it. The dark surfaces follow a #212121 lineage, not iOS's
// pure black — which is why the
// iPhone app is NOT black in dark mode either: the platforms diverge from
// stock on purpose, and one palette serves both clients.
//
// No view hardcodes a colour, size, or radius: a missing token is added here.
enum Tokens {
    enum Home {
        static let shortcutDiameter: CGFloat = 44
        static let shortcutWidth: CGFloat = 76
        static let pinDiameter: CGFloat = 72
        // Mac sidebar pins sit on the shortcut grid; the phone keeps pinDiameter.
        static let desktopPinDiameter: CGFloat = 44
        static let gutter: CGFloat = 20
        // Centers the 76pt shortcut cell in the 90pt sidebar rail.
        static let sidebarGutter: CGFloat = 7
        static let desktopHeaderHeight: CGFloat = 64
        static let desktopInputHeight: CGFloat = 36
        static let itemSpacing: CGFloat = 8
    }

    enum Palette {
        static let messageCanvas = adaptive(light: 0xFFFFFF, dark: 0x212121)
        static let messageIncoming = adaptive(light: 0xDEDEDF, dark: 0x3A3A3C)
        static let messageOutgoing = adaptive(light: 0x0062ED, dark: 0x0A84FF)
        static let surface = adaptive(light: 0xFCFCFC, dark: 0x212121)
        static let surfaceSunken = adaptive(light: 0xF9F9F9, dark: 0x171717)
        static let surfaceInput = adaptive(light: 0xFFFFFF, dark: 0x2F2F2F)
        static let surfaceHover = adaptive(light: 0xF3F3F3, dark: 0x2A2A2A)
        static let surfaceActive = adaptive(light: 0xE8E8E8, dark: 0x3A3A3A)
        static let segmentTrack = adaptive(light: 0xECECEC, dark: 0x2F2F2F)
        static let segmentChip = adaptive(light: 0xFFFFFF, dark: 0x424242)

        static let ink = adaptive(light: 0x0D0D0D, dark: 0xFFFFFF)
        static let inkSecondary = adaptive(light: 0x5D5D5D, dark: 0xCDCDCD)
        static let inkTertiary = adaptive(light: 0x8F8F8F, dark: 0xAFAFAF)

        static let borderLight = adaptive(
            light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.05
        )
        static let border = adaptive(
            light: 0x000000, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.15
        )

        // The web's neutral-first CTA: near-black in light, white in dark.
        // The accent stays reserved for creation and selection, so
        // blue never becomes the default button colour.
        static let action = adaptive(light: 0x0D0D0D, dark: 0xFFFFFF)
        static let actionInk = adaptive(light: 0xFFFFFF, dark: 0x0D0D0D)
        static let accent = adaptive(light: 0x007AFF, dark: 0x0A84FF)
        static let danger = adaptive(light: 0xFF002A, dark: 0xFF6B6B)
        // Success green doubles as the meetings identity — the live colour.
        static let live = adaptive(light: 0x0F9D58, dark: 0x2FBF71)
        static let callSurface = adaptive(light: 0x188553, dark: 0x165C3D)
        // The platform's own system orange, named explicitly on each side:
        // SwiftUI's `Color.orange` resolves to it too, but the Mac app is
        // live and this token should not move by a shade on a refactor.
        #if os(macOS)
        static let warning = Color(nsColor: .systemOrange)
        #else
        static let warning = Color(uiColor: .systemOrange)
        #endif
        // One rung below warning: the amber a mid-priority state wears for "this
        // week", where the orange above already means "today". Named
        // on each side for the same reason `warning` is.
        #if os(macOS)
        static let caution = Color(nsColor: .systemYellow)
        #else
        static let caution = Color(uiColor: .systemYellow)
        #endif
        // The Operations category's teal on the Projects board. Product is
        // the accent and Marketing the warning orange; this is the third.
        static let operations = adaptive(light: 0x0E9F9A, dark: 0x30C8C2)
        // Status has no colour of its own — it reads what is running, and
        // attention is already the warning colour on every other surface.
        static let statusAccent = warning

        // The camera stage keeps one committed dark look in both themes,
        // like the web's fixed-polarity surfaces (imageViewerStage et al).
        static let stage = adaptive(light: 0x161616, dark: 0x161616)
        static let stageInk = Color.white

        static let cardShadow = adaptive(
            light: 0x000000, lightAlpha: 0.05, dark: 0x000000, darkAlpha: 0.35
        )
        static let cardHoverShadow = adaptive(
            light: 0x000000, lightAlpha: 0.10, dark: 0x000000, darkAlpha: 0.50
        )
    }

    // The Analytics chart series: one fixed color per platform, drawn
    // from the palette so a series never invents a new hue. Total is ink —
    // the headline line — and the platforms sit under it.
    // One hierarchy, two calibrations. The Mac sits on the web's scale (28pt
    // medium listing titles — 500, never 600 — 15 semibold card titles, 13
    // body rows); the phone is a touch device read at arm's length, so every
    // rung moves up to the iOS reading sizes a finger-sized row needs. Same
    // names, same three-tier ink ladder doing the work weight would; only the
    // numbers differ, so shared components need no platform branch of their own.
    enum Typography {
        #if os(macOS)
        static let pageTitle = Font.system(size: 28, weight: .medium)
        static let pageTitleTracking: CGFloat = -0.6
        static let sheetTitle = Font.system(size: 17, weight: .semibold)
        static let cardTitle = Font.system(size: 15, weight: .semibold)
        static let sectionLabel = Font.system(size: 13)
        static let row = Font.system(size: 13)
        static let rowEmphasis = Font.system(size: 13, weight: .medium)
        static let meta = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let captionEmphasis = Font.system(size: 11, weight: .medium)
        static let button = Font.system(size: 13, weight: .medium)
        static let buttonSmall = Font.system(size: 12, weight: .medium)
        static let badge = Font.system(size: 10, weight: .bold)
        static let dateTileWeekday = Font.system(size: 9, weight: .semibold)
        static let dateTileDay = Font.system(size: 16, weight: .semibold)
        #else
        static let pageTitle = Font.largeTitle.bold()
        static let pageTitleTracking: CGFloat = -0.6
        static let sheetTitle = Font.headline
        static let cardTitle = Font.headline
        static let sectionLabel = Font.subheadline
        static let row = Font.body
        static let rowEmphasis = Font.body.weight(.medium)
        static let meta = Font.subheadline
        static let caption = Font.caption
        static let captionEmphasis = Font.caption.weight(.medium)
        static let button = Font.body.weight(.medium)
        static let buttonSmall = Font.subheadline.weight(.medium)
        static let badge = Font.caption2.bold()
        static let dateTileWeekday = Font.caption2.weight(.semibold)
        static let dateTileDay = Font.title3.weight(.semibold)
        #endif
    }

    /// A photo bubble and a document card in a transcript. The phone gets
    /// more room because the bubble column IS the screen there.
    enum Attachment {
        static let iconSize: CGFloat = 40
        static let draftWidth: CGFloat = 220
        static let accessibleDraftWidth: CGFloat = 320
        #if os(macOS)
        static let imageMaxWidth: CGFloat = 260
        static let imageMaxHeight: CGFloat = 320
        static let cardWidth: CGFloat = 240
        #else
        static let imageMaxWidth: CGFloat = 280
        static let imageMaxHeight: CGFloat = 360
        static let cardWidth: CGFloat = 280
        #endif
    }

    /// A link preview card: image over title over host. Wider on a phone,
    /// where the bubble column is the whole screen.
    enum LinkCard {
        #if os(macOS)
        static let width: CGFloat = 260
        static let imageHeight: CGFloat = 136
        static let title = Font.system(size: 12, weight: .semibold)
        #else
        static let width: CGFloat = 280
        static let imageHeight: CGFloat = 148
        static let title = Font.system(size: 15, weight: .semibold)
        #endif
    }

    /// A tapback balloon's glyphs. The balloon geometry is identical on both
    /// platforms; only what is written inside it is read at a different
    /// distance.
    enum Tapback {
        #if os(macOS)
        static let emoji = Font.system(size: 12)
        static let textGlyph = Font.system(size: 9, weight: .heavy)
        static let count = Font.system(size: 10, weight: .medium)
        #else
        static let emoji = Font.system(size: 15)
        static let textGlyph = Font.system(size: 11, weight: .heavy)
        static let count = Font.system(size: 12, weight: .medium)
        #endif
    }

    // The transcript's own measurements. Messages' bubble geometry is a
    // continuous 18pt corner on both platforms; only the text size and the
    // padding around it change, because a phone bubble is read at arm's
    // length and a Mac bubble at desk distance.
    enum Bubble {
        #if os(iOS)
        static let radius: CGFloat = 22
        #else
        static let radius: CGFloat = 18
        #endif
        /// A bubble never grows past this, the way Messages caps one instead
        /// of letting it run the width of the window. The cap is also what
        /// holds the transcript still when a side panel narrows the column:
        /// only the empty gutter changes width, never a line of text.
        static let maxWidth: CGFloat = 420
        /// A sender's face, and the lane its width reserves: an indicator
        /// that draws no face still starts where the message will.
        static let avatar: CGFloat = 28
        static let avatarGutter: CGFloat = 34

        #if os(macOS)
        static let text = Font.system(size: 14)
        /// The same face as `text`, for the AppKit text view a Mac bubble
        /// draws so its content can be selected.
        static let textFont = NSFont.systemFont(ofSize: 14)
        static let paddingHorizontal: CGFloat = 13
        static let paddingVertical: CGFloat = 8
        /// The far side always keeps this much air, so a bubble gives way
        /// rather than touching the opposite edge on a column too narrow for
        /// the cap. On a phone this, not the cap, is what binds.
        static let farGutter: CGFloat = 80
        static let quoteText = Font.system(size: 12)
        static let quoteMaxWidth: CGFloat = 260
        #else
        static let text = Font.body
        static let paddingHorizontal: CGFloat = 14
        static let paddingVertical: CGFloat = 8
        static let farGutter: CGFloat = 56
        static let quoteText = Font.subheadline
        static let quoteMaxWidth: CGFloat = 240
        #endif
    }

    // The shared 4pt rhythm; x4 = 16 is the card gutter, x5 = 24 separates
    // groups and is the page gutter.
    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x5: CGFloat = 24
        static let x6: CGFloat = 32
    }

    enum Radius {
        static let thumb: CGFloat = 8
        static let row: CGFloat = 10
        static let chip: CGFloat = 12
        static let gridCard: CGFloat = 14
        static let card: CGFloat = 16
        static let glassStrokeWidth: CGFloat = 1
    }

    /// One quiet capsule mark, the same geometry on every surface that wears
    /// one — a task's state, a link's state, an alert's severity, a signal's
    /// level. The tint is the chip's own colour; this is only how much of it
    /// sits behind the words.
    enum Chip {
        static let paddingHorizontal: CGFloat = 7
        static let paddingVertical: CGFloat = 2
        static let tintOpacity: Double = 0.14
    }

    /// The Projects boards, drawn the way Trello draws them: a home
    /// that is itself a board, a board of lists, a list of cards, and a card
    /// dialog.
    /// The Mac takes the approved mock's sizes; the phone reads each rung a
    /// little larger, at arm's length.
    enum Projects {
        #if os(macOS)
        static let boardGutter: CGFloat = 16
        static let listWidth: CGFloat = 262
        /// The home's lists are a touch wider: a project card carries a name.
        static let homeListWidth: CGFloat = 272
        static let boardBarHeight: CGFloat = 52
        static let barTitle = Font.system(size: 13, weight: .semibold)
        static let boardName = Font.system(size: 15, weight: .semibold)
        static let listTitle = Font.system(size: 13, weight: .semibold)
        static let listCount = Font.system(size: 12, weight: .medium)
        static let cardTitle = Font.system(size: 13)
        static let cardMeta = Font.system(size: 11.5)
        /// A card's `HQ-<n>`, quiet at the left of its foot.
        static let cardRef = Font.system(size: 11, design: .monospaced)
        static let cardLabel = Font.system(size: 10.5, weight: .semibold)
        static let addRow = Font.system(size: 13)
        static let claim = Font.system(size: 12, weight: .semibold)
        static let tier = Font.system(size: 10.5, weight: .semibold)
        static let dialogTitle = Font.system(size: 19, weight: .semibold)
        static let dialogIn = Font.system(size: 12.5)
        static let dialogInEmphasis = Font.system(size: 12.5, weight: .semibold)
        static let fieldLabel = Font.system(size: 11, weight: .semibold)
        static let body = Font.system(size: 13)
        static let blockTitle = Font.system(size: 13.5, weight: .semibold)
        static let quiet = Font.system(size: 12.5)
        static let mono = Font.system(size: 11.5, design: .monospaced)
        static let pill = Font.system(size: 11, weight: .semibold)
        static let feedEvent = Font.system(size: 12.5)
        static let feedName = Font.system(size: 13, weight: .semibold)
        static let feedWhen = Font.system(size: 11.5)
        static let send = Font.system(size: 12, weight: .semibold)
        static let ctaSmall = Font.system(size: 12.5, weight: .semibold)
        static let spark = Font.system(size: 13, design: .monospaced)
        #else
        static let boardGutter: CGFloat = 14
        static let listWidth: CGFloat = 300
        static let homeListWidth: CGFloat = 300
        static let boardBarHeight: CGFloat = 52
        static let barTitle = Font.system(size: 15, weight: .semibold)
        static let boardName = Font.system(size: 17, weight: .semibold)
        static let listTitle = Font.system(size: 15, weight: .semibold)
        static let listCount = Font.system(size: 13, weight: .medium)
        static let cardTitle = Font.system(size: 15)
        static let cardMeta = Font.system(size: 12.5)
        static let cardRef = Font.system(size: 12, design: .monospaced)
        static let cardLabel = Font.system(size: 11, weight: .semibold)
        static let addRow = Font.system(size: 15)
        static let claim = Font.system(size: 13, weight: .semibold)
        static let tier = Font.system(size: 11.5, weight: .semibold)
        static let dialogTitle = Font.system(size: 21, weight: .semibold)
        static let dialogIn = Font.system(size: 13.5)
        static let dialogInEmphasis = Font.system(size: 13.5, weight: .semibold)
        static let fieldLabel = Font.system(size: 12, weight: .semibold)
        static let body = Font.system(size: 15)
        static let blockTitle = Font.system(size: 15, weight: .semibold)
        static let quiet = Font.system(size: 13.5)
        static let mono = Font.system(size: 12.5, design: .monospaced)
        static let pill = Font.system(size: 12, weight: .semibold)
        static let feedEvent = Font.system(size: 13)
        static let feedName = Font.system(size: 14, weight: .semibold)
        static let feedWhen = Font.system(size: 12)
        static let send = Font.system(size: 14, weight: .semibold)
        static let ctaSmall = Font.system(size: 14, weight: .semibold)
        static let spark = Font.system(size: 14, design: .monospaced)
        #endif
        /// The bar's glass circles. The phone's is the 44pt touch size; the
        /// bar (52pt) still fits it.
        #if os(iOS)
        static let barButton: CGFloat = 44
        #else
        static let barButton: CGFloat = 32
        #endif
        static let backlogOpacity: Double = 0.55
        static let listGap: CGFloat = 12
        static let listRadius: CGFloat = 14
        static let listPadding: CGFloat = 8
        static let cardGap: CGFloat = 8
        static let cardRadius: CGFloat = 10
        static let faceSize: CGFloat = 24
        static let faceOverlap: CGFloat = 6
        static let cardFace: CGFloat = 22
        static let fieldFace: CGFloat = 26
        /// The Live list's age mark: a static dot, its ring's weight
        /// and the dash of the oldest. Nothing about it animates.
        static let liveDot: CGFloat = 9
        static let liveRing: CGFloat = 1.5
        static let liveDash: [CGFloat] = [2, 2]
        /// The Live list's and the catalog's side gutter.
        static let liveGutter: CGFloat = 20
        /// A card's padding: Trello's generous card, never cramped.
        static let cardPaddingH: CGFloat = 12
        static let cardPaddingV: CGFloat = 10
        /// Below this width a card fills the screen instead of opening in
        /// the panel beside its board.
        static let panelBelow: CGFloat = 720
        /// The right panel a card (or a board's comments) opens in.
        static let panelWidth: CGFloat = 440
        static let ref = Font.system(size: 11, design: .monospaced)

        /// The card panel: one glass sheet, a bold title, and a gutter the
        /// feed's faces share.
        static let panelGutter: CGFloat = 36
        static let panelFace: CGFloat = 28
        /// The glass pane's inset inside its frame: the sidebar's 8pt.
        static let panelMargin: CGFloat = 8
        /// A translucent well on the panel's glass: its chips, a comment's
        /// box, the description while it is edited. Never glass on glass.
        static let panelWell = adaptive(light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.08)
        #if os(macOS)
            static let panelTitle = Font.system(size: 20, weight: .bold)
            static let panelSection = Font.system(size: 14, weight: .semibold)
            static let panelLabel = Font.system(size: 12, weight: .semibold)
            static let panelBody = Font.system(size: 13.5)
            static let panelButton = Font.system(size: 13, weight: .medium)
        #else
            static let panelTitle = Font.system(size: 22, weight: .bold)
            static let panelSection = Font.system(size: 16, weight: .semibold)
            static let panelLabel = Font.system(size: 13, weight: .semibold)
            static let panelBody = Font.system(size: 15)
            static let panelButton = Font.system(size: 15, weight: .medium)
        #endif

        /// The list behind the cards, and the card on it.
        static let listFill = adaptive(light: 0xF4F4F4, dark: 0x1A1A1A)
        static let cardFill = adaptive(light: 0xFFFFFF, dark: 0x2A2A2A)
        static let wash = adaptive(light: 0x000000, lightAlpha: 0.035, dark: 0xFFFFFF, darkAlpha: 0.045)
        /// A list a dragged card is over, and the gap it would land in.
        static let listDropFill = adaptive(light: 0xE9EEF6, dark: 0x1D2530)
        static let dropGap = adaptive(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.1)

        /// A category's colour, flat — never a gradient: full strength in a
        /// home list's square, a tint behind a board's label.
        enum Category {
            static let product = Palette.accent
            static let operations = adaptive(light: 0x0E9F9A, dark: 0x30C8C2)
            static let marketing = Palette.warning
            static let support = adaptive(light: 0xAF52DE, dark: 0xBF5AF2)
            static let none = adaptive(light: 0x8F8F8F, dark: 0x8F8F8F)
            static let alerts = Palette.danger
        }
    }

    enum Glass {
        static let spacing: CGFloat = 8
        static let cardRadius: CGFloat = 20
        static let scrollInset: CGFloat = 8
    }

    enum Motion {
        static let fast: Double = 0.10
        static let base: Double = 0.18
        static let press: Double = 0.12
    }

    enum Layout {
        static let pageContentWidth: CGFloat = 680

        #if os(macOS)
        static let rowMinHeight: CGFloat = 40
        static let controlHeight: CGFloat = 30
        static let controlHeightSmall: CGFloat = 26
        static let filterVisualHeight: CGFloat = 26
        #else
        // Apple's 44pt minimum: every rung here is something a finger hits.
        static let rowMinHeight: CGFloat = 60
        static let controlHeight: CGFloat = 44
        static let controlHeightSmall: CGFloat = 36
        static let filterVisualHeight: CGFloat = 32
        #endif
    }

    // One token resolves per appearance on both platforms. SwiftUI's own
    // `Color(light:dark:)` does not exist, and a `@Environment`-read variant
    // would not work in the static constants views reference — so each
    // platform's dynamic colour type does the resolving.
    private static func adaptive(
        light: UInt32, lightAlpha: CGFloat = 1,
        dark: UInt32, darkAlpha: CGFloat = 1
    ) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#else
private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif
