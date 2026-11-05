import SwiftUI

/// Persistent call chrome, shared across pages and platforms.
struct CallReturnStrip: View {
    @Environment(AppStore.self) private var store
    let onReturn: () -> Void

    var body: some View {
        if let call = store.activeCall {
            Button(action: onReturn) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .medium))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(for: call))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text("\(headcount(call)) · Tap to return")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Tokens.Home.gutter)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Tokens.Palette.callSurface.ignoresSafeArea(.container, edges: .top))
            .accessibilityLabel("Return to \(title(for: call)), \(headcount(call))")
            .accessibilityIdentifier("active-call-return")
        }
    }

    private func title(for call: Call) -> String {
        if let title = call.title, !title.isEmpty { return title }
        guard let conversation = store.conversation(call.conversationId) else {
            return "In a call"
        }
        return store.displayName(for: conversation)
    }

    private func headcount(_ call: Call) -> String {
        let count = call.presentParticipants.count
        return count == 1 ? "1 person" : "\(count) people"
    }
}
