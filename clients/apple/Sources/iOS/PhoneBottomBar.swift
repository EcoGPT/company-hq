import SwiftUI

/// One bottom accessory layout for chat composers. The system bar
/// supplies scroll-edge treatment while the editor can grow above the keyboard.
struct PhoneBottomBar<Bar: View>: ViewModifier {
    @ViewBuilder var bar: () -> Bar
    @State private var measuredHeight: CGFloat = 48

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            // Search rests 28pt from the screen edge. Reclaim only part of
            // the home-indicator inset; never reclaim keyboard clearance.
            let bottomAdjustment = geometry.safeAreaInsets.bottom <= 34
                ? min(14, geometry.safeAreaInsets.bottom) : 0
            if #available(iOS 26.0, *) {
                content.safeAreaBar(edge: .bottom, spacing: 0) {
                    controls(height: geometry.size.height)
                        .padding(.bottom, -bottomAdjustment)
                }
            } else {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    controls(height: geometry.size.height)
                }
            }
        }
    }

    private func controls(height: CGFloat) -> some View {
        ScrollView {
            bar()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom)
        .frame(height: min(measuredHeight, max(48, height - 44)))
        .frame(maxWidth: .infinity)
    }
}
