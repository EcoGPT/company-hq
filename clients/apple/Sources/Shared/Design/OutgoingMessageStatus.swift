import SwiftUI

/// Failed sends retain their original request and retry key for this session.
struct OutgoingMessageStatus: View {
    @Environment(AppStore.self) private var store
    let message: Message

    var body: some View {
        if message.id.hasPrefix("pending-") {
            if store.failedOutgoingMessages[message.id] != nil {
                Button { store.retrySend(message) } label: {
                    Label("Not sent · Retry", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .hqGlass(in: Capsule(), interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Retry sending message")
                .accessibilityIdentifier("retry-send-\(message.id)")
                .accessibilityLabel("Message not sent. Retry")
            } else {
                Text("Sending…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
    }
}
