import SwiftUI

/// The in-app fallback for an incoming ring. CallKit owns the system surface.
struct IncomingCallPhoneView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Tokens.Palette.stage.ignoresSafeArea()
            if let ring = store.incomingCall {
                VStack(spacing: 24) {
                    ScrollView {
                        VStack(spacing: 16) {
                            AvatarView(name: ring.callerName, size: 88)
                            Text(ring.callerName)
                                .font(.largeTitle.weight(.semibold))
                            Text(ring.conversationTitle ?? "HQ Call")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text("Incoming call")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    }
                    HStack(spacing: 48) {
                        answer("Decline", symbol: "phone.down.fill", tint: .red) {
                            Task { await store.declineIncomingCall() }
                        }
                        answer("Answer", symbol: "phone.fill", tint: .green) {
                            Task { await store.answerIncomingCall() }
                        }
                    }
                    .padding(.bottom, 32)
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func answer(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .hqGlass(in: Circle(), tint: tint, interactive: true)
                Text(title).font(.subheadline).fixedSize()
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
