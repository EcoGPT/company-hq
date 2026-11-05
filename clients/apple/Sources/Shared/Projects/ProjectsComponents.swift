import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// The small pieces every board shares: the bar's glass circles, the stack of
// member faces, a board's colour and label, the tier chip and Claim, and the
// room's way into a card. Nothing here animates.

// MARK: - Categories

enum ProjectsCategory {
    /// A board's colour, by its category: flat, one per category.
    static func color(for category: String?) -> Color {
        switch category {
        case "Product": Tokens.Projects.Category.product
        case "Operations": Tokens.Projects.Category.operations
        case "Marketing": Tokens.Projects.Category.marketing
        default: Tokens.Projects.Category.none
        }
    }
}

/// A board's name on a flat tint of its colour — the card dialog's Board
/// field, and the project a My tasks card came from.
struct BoardLabel: View {
    let name: String
    let color: Color
    var isSmall = false

    var body: some View {
        Text(name)
            .font(isSmall ? Tokens.Projects.cardLabel : Tokens.Projects.claim)
            .foregroundStyle(color.mix(with: Tokens.Palette.ink, by: 0.25))
            .lineLimit(1)
            .padding(.horizontal, isSmall ? 6 : 10)
            .padding(.vertical, isSmall ? 2 : 4)
            .background(
                color.opacity(Tokens.Chip.tintOpacity + 0.04),
                in: RoundedRectangle(cornerRadius: isSmall ? 4 : 6, style: .continuous))
    }
}

/// A home list's mark: its category's colour, full strength.
struct CategorySquare: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

// MARK: - Touch size

extension View {
    /// The phone's 44pt hit area (`hqMinimumControlTarget`) and the shape that
    /// takes the tap across all of it; the drawn control keeps its size. The
    /// Mac is left exactly as it was.
    @ViewBuilder
    func projectsPhoneTarget<S: Shape>(_ shape: S = Rectangle()) -> some View {
        #if os(iOS)
        self.hqMinimumControlTarget().contentShape(shape)
        #else
        self
        #endif
    }
}

// MARK: - Bar

/// A glass circle in a board's bar: back, and the board's "…".
struct BarCircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { BarCircleGlyph(symbol: symbol) }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)
    }
}

struct BarCircleGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Tokens.Palette.ink)
            .frame(width: Tokens.Projects.barButton, height: Tokens.Projects.barButton)
            .hqGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }
}

/// The bar's "…": the board's own verbs, behind one glass circle.
struct BarMenu<Items: View>: View {
    var label = "Board menu"
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            BarCircleGlyph(symbol: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The faces on a board: overlapping, each ringed in the page's surface.
struct FaceStack: View {
    let names: [String]
    var size: CGFloat = Tokens.Projects.faceSize

    var body: some View {
        HStack(spacing: -Tokens.Projects.faceOverlap) {
            ForEach(names, id: \.self) { name in
                AvatarView(name: name, isGroup: false, size: size)
                    .background(Circle().fill(Tokens.Palette.surface).padding(-2))
                    .help(name)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.joined(separator: ", "))
    }
}

/// A person's face on a card or in a field; a dashed ring for the assistant
/// (a bot), which holds what nobody has taken yet.
struct CardFace: View {
    @Environment(AppStore.self) private var store
    let name: String
    let personId: String?
    var size: CGFloat = Tokens.Projects.cardFace

    var body: some View {
        if let personId, store.people[personId]?.kind == "bot" {
            Circle()
                .strokeBorder(Tokens.Palette.inkTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: size, height: size)
                .help("Nobody yet")
                .accessibilityLabel("Nobody yet")
        } else {
            AvatarView(name: name, isGroup: false, size: size)
                .help(name)
                .accessibilityLabel(name)
        }
    }
}

// MARK: - Pasteboard

enum ProjectsPasteboard {
    static func copy(_ value: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        #else
            UIPasteboard.general.string = value
        #endif
    }
}
