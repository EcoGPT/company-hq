import SwiftUI

/// The call-error strip, in the danger tint rather than a bare label — the
/// same shape the Mac's Meetings page uses.
struct CallErrorBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Tokens.Typography.meta)
            Text(text)
                .font(Tokens.Typography.meta)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokens.Palette.danger)
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, Tokens.Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Tokens.Palette.danger.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
        )
    }
}

private struct ReturnToActiveCallKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var returnToActiveCall: () -> Void {
        get { self[ReturnToActiveCallKey.self] }
        set { self[ReturnToActiveCallKey.self] = newValue }
    }
}
