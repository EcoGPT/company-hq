import SwiftUI

/// The same circular shortcut and caption on phone and desktop.
struct WorkspaceShortcutLabel: View {
    let title: String
    let symbol: String
    let color: Color
    var count = 0
    var isCompact = false
    var isSelected = false
    @ScaledMetric(relativeTo: .caption) private var iconSize = Tokens.Home.shortcutDiameter
    @ScaledMetric(relativeTo: .caption) private var itemWidth = Tokens.Home.shortcutWidth

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: min(iconSize, 56) * 0.43, weight: .medium))
                .foregroundStyle(color)
                .frame(width: min(iconSize, 56), height: min(iconSize, 56))
                .overlay {
                    if isSelected { Circle().strokeBorder(color.opacity(0.7), lineWidth: 2) }
                }
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count, format: .number)
                            .font(.caption2.weight(.semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(color, in: Capsule())
                            .fixedSize().allowsHitTesting(false)
                    }
                }
                .hqGlass(in: Circle(), tint: color.opacity(0.22), interactive: true)
            if !isCompact {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: isCompact ? min(iconSize, 56) : itemWidth)
        .contentShape(Rectangle())
    }
}

extension HomePreferences.Shortcut {
    var destination: AppStore.Destination {
        switch self {
        case .calls: .meetings
        case .tasks: .tasks
        case .files: .files
        }
    }
    var color: Color {
        switch self {
        case .calls: Tokens.Palette.live
        case .tasks: Tokens.Palette.accent
        case .files: .gray
        }
    }
}

