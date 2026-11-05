import SwiftUI

private struct ToggleConversationDetailsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var toggleConversationDetails: () -> Void {
        get { self[ToggleConversationDetailsKey.self] }
        set { self[ToggleConversationDetailsKey.self] = newValue }
    }
}

/// The panel appears at its final size in the same update as its width reservation.
struct DesktopDetailPanel<Panel: View>: View {
    let isPresented: Bool
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        ZStack(alignment: .trailing) {
            if isPresented {
                HStack(spacing: 0) {
                    Rectangle().fill(.separator).frame(width: 1)
                    panel().frame(width: 320)
                }
                .frame(maxHeight: .infinity)
                .transition(.identity)
            }
        }
        .frame(width: 321)
        .frame(maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
