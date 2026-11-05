import SwiftUI

// A call ringing. FaceTime's notification shape, deliberately
//: a compact banner in the top-right corner — avatar,
// who and where from, and the two answers as plain circles — not a card in
// the middle of the screen. It floats above everything because a call is
// the one thing in HQ that expires — forty-five seconds and it is a missed
// call instead.
struct IncomingCallView: View {
    @Environment(AppStore.self) private var store

    static let bannerSize = CGSize(width: 360, height: 72)

    var body: some View {
        if let ring = store.incomingCall {
            HStack(spacing: Tokens.Space.x3) {
                AvatarView(name: ring.callerName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ring.callerName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .lineLimit(1)
                    Text(ring.conversationTitle.map { "HQ · \($0)" } ?? "HQ Call")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.x2)
                AnswerButton(
                    symbol: "phone.down.fill",
                    tint: Tokens.Palette.danger,
                    label: "Decline"
                ) {
                    Task { await store.declineIncomingCall() }
                }
                AnswerButton(symbol: "phone.fill", tint: Tokens.Palette.live, label: "Join") {
                    // The store opens the stage: this banner is an AppKit
                    // window with no scene to ask.
                    Task { await store.answerIncomingCall() }
                }
            }
            .padding(.horizontal, Tokens.Space.x4)
            .frame(
                width: Self.bannerSize.width, height: Self.bannerSize.height
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            // The window is torn down the moment the ring resolves; this is
            // only ever a frame of nothing on the way out.
            Color.clear
        }
    }
}

private struct AnswerButton: View {
    let symbol: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
