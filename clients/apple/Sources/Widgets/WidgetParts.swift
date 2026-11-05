import AppKit
import SwiftUI
import WidgetKit

/// HQ's palette (Design/Tokens.swift), restated for the extension, which
/// does not compile the app's Shared tree. Flat colours, never a gradient.
enum Palette {
    static let accent = dynamic(light: 0x007AFF, dark: 0x0A84FF)
    static let warning = Color(nsColor: .systemOrange)
    static let inkTertiary = dynamic(light: 0x8F8F8F, dark: 0xAFAFAF)
    /// To do, in the tasks ring: present, but quieter than work in progress.
    static let todo = dynamic(light: 0xD1D1D6, dark: 0x48484A)
    /// The board's list, and the card on it (Tokens.Projects).
    static let listFill = dynamic(light: 0xF4F4F4, dark: 0x1A1A1A)
    static let cardFill = dynamic(light: 0xFFFFFF, dark: 0x2A2A2A)

    /// A person's colour when they have no picture: stable per person.
    static func person(_ id: String) -> Color {
        let hues: [UInt32] = [0x007AFF, 0x0E9F9A, 0xFF9500, 0xAF52DE, 0xFF2D55, 0x34C759, 0x5856D6, 0xA2845E]
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return rgb(hues[sum % hues.count])
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsRGB(isDark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> Color { Color(nsColor: nsRGB(hex)) }

    private static func nsRGB(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Type

/// Three text styles, nothing else: the big rounded number a widget leads
/// with, a primary line, and a quiet one. Colour says the rest.
extension View {
    func heroText(size: CGFloat = 32) -> some View {
        font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .widgetAccentable()
    }

    func primaryText() -> some View {
        font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
    }

    func secondaryText() -> some View {
        font(.system(size: 13)).foregroundStyle(.secondary)
    }

    /// Every HQ widget sits on the system's own widget background.
    func hqWidgetBackground() -> some View {
        containerBackground(.background, for: .widget)
    }
}

// MARK: - Marks

/// A task's circle. Blocked is dashed. It only marks: the widgets are read-only.
struct TaskMark: View {
    let task: WidgetSummary.WorkTask

    var body: some View {
        Circle()
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.3, dash: task.isBlocked ? [2, 2] : []))
            .frame(width: 14, height: 14)
    }
}

// MARK: - Faces and lines

struct Face: View {
    let name: String
    let personId: String
    var avatarId: String?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let avatarId, let data = WidgetShelf.avatar(personId: personId, avatarId: avatarId),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Palette.person(personId)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(name)
    }
}

/// Signed out, or nothing to show yet.
struct WidgetMessage: View {
    let text: String

    var body: some View {
        Text(text).secondaryText()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
