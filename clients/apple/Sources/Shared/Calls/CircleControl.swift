import SwiftUI

// Shared with the green room — so the pre-join toggles are the same controls
// the call itself shows — and with the phone, so a call looks like a call on
// either device.
struct CircleControlLabel: View {
    let symbol: String
    let isOn: Bool
    var isActive = false
    var isDestructive = false

    var body: some View {
        let shape = isDestructive ? AnyShape(Capsule()) : AnyShape(Circle())
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: isDestructive ? 58 : 44, height: 44)
            .hqGlass(
                in: shape, tint: isDestructive ? .red : isActive ? .blue : !isOn ? .red : .clear, interactive: true
            )
            .environment(\.colorScheme, .dark)
            .contentShape(shape)
    }
}

struct CircleControl: View {
    let symbol: String
    let isOn: Bool
    var isActive = false
    var isDestructive = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleControlLabel(
                symbol: symbol,
                isOn: isOn,
                isActive: isActive,
                isDestructive: isDestructive
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
