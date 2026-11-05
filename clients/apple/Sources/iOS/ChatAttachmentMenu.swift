import SwiftUI

@Observable
final class ChatAttachmentMenuState {
    enum Action { case photos, files, emoji, paste }

    var isPresented = false
    var canPaste = false
    var selectedAction: Action?

    func select(_ action: Action) {
        isPresented = false
        selectedAction = action
    }
}

/// Lives above the whole conversation so the bottom accessory cannot clip the menu.
struct ChatAttachmentMenu: View {
    let menu: ChatAttachmentMenuState
    @ScaledMetric(relativeTo: .title2) private var rowHeight: CGFloat = 66
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 36
    @ScaledMetric(relativeTo: .title2) private var labelSize: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion

    private let panelShape = RoundedRectangle(cornerRadius: 40, style: .continuous)

    var body: some View {
        GeometryReader { geometry in
            if menu.isPresented {
                ZStack(alignment: .bottomLeading) {
                    Button { menu.isPresented = false } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss attachments")
                    .ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: 0) {
                            option("Photos", symbol: "photo.on.rectangle.fill", color: .pink, action: .photos)
                            option("Files", symbol: "folder.fill", color: .blue, action: .files)
                            option("Emoji", symbol: "face.smiling.fill", color: .orange, action: .emoji)
                            if menu.canPaste {
                                option("Paste", symbol: "document.on.clipboard.fill", color: .purple, action: .paste)
                            }
                        }
                        .padding(.vertical, 22)
                        .padding(.horizontal, 36)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: min(320, geometry.size.width - 24),
                           height: min(rowHeight * (menu.canPaste ? 4 : 3) + 44, geometry.size.height - 24))
                    .hqGlass(in: panelShape)
                    .padding(.leading, 10)
                    .accessibilityIdentifier("chat-attachment-menu")
                    .transition(shouldReduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                }
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { menu.isPresented = false }
            }
        }
        .animation(shouldReduceMotion ? nil : .snappy(duration: 0.22), value: menu.isPresented)
    }

    private func option(_ title: String, symbol: String, color: Color,
                        action: ChatAttachmentMenuState.Action) -> some View {
        Button { menu.select(action) } label: {
            HStack(spacing: 26) {
                icon(symbol: symbol, color: color, action: action)
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: labelSize, weight: .regular))
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer(minLength: 0)
            }
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    @ViewBuilder
    private func icon(symbol: String, color: Color, action: ChatAttachmentMenuState.Action) -> some View {
        if action == .photos {
            ZStack {
                Circle().fill(.white)
                ForEach(0..<8) { index in
                    Ellipse()
                        .fill([Color.orange, .yellow, .green, .mint, .blue, .purple, .pink, .red][index].opacity(0.8))
                        .frame(width: iconSize * 0.28, height: iconSize * 0.44)
                        .offset(y: -iconSize * 0.20)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
            .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 0.5))
        } else {
            Image(systemName: symbol)
                .font(.system(size: iconSize * 0.58, weight: .regular))
                .foregroundStyle(action == .files ? Color.blue : .white)
                .frame(width: iconSize, height: iconSize)
                .background(action == .files ? Color.white : color, in: Circle())
                .overlay(Circle().stroke(.black.opacity(0.06), lineWidth: 0.5))
        }
    }

}
