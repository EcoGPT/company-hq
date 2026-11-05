import SwiftUI

// In-app preview for a Markdown attachment: fetched over the bearer, rendered
// as a document, saved only if asked. AttributedString(markdown:) understands
// just the inline runs, so the blocks — headings, lists, code — are
// reassembled from the parser's presentation intents and laid out by hand.
struct MarkdownPreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let attachment: Attachment
    @State private var text: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(attachment.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Save…") {
                    AttachmentCache.shared.save(attachment, client: store.client)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if let text {
                ScrollView {
                    MarkdownFileView(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 440, idealHeight: 620)
        .task {
            guard let client = store.client,
                  let data = try? await client.attachmentData(id: attachment.id),
                  let decoded = String(bytes: data, encoding: .utf8)
            else { return }
            text = decoded
        }
    }
}
