import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A paste of an image or a file is an attachment, not text — the same bargain
/// the Mac's ⌘V makes (`ChatView.didAttachFromPasteboard`). Staging goes
/// through the store's per-conversation drafts, so a pasted screenshot lands in
/// the same strip the ⊕ picker fills and sends with the next message.
enum PasteboardAttachments {
    /// Whether the ⊕ menu and the editor's Paste item should be offered at
    /// all. **Types only.** Reading pasteboard CONTENT raises the system's
    /// "pasted from" banner, and answering "is there an image on the
    /// clipboard" is not something the user asked for — that read waits until
    /// they actually tap Paste.
    static var isAvailable: Bool {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages { return true }
        if pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) { return true }
        return pasteboard.types.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            guard !type.conforms(to: .text), !type.conforms(to: .url) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .pdf)
                || type.conforms(to: .audiovisualContent) || type.conforms(to: .archive)
        }
    }

    /// Stages whatever the pasteboard is carrying. Returns false when the
    /// paste belongs to the text field after all, which is what lets the
    /// editor fall through to `super.paste`.
    @MainActor
    static func didStage(in conversationId: String, store: AppStore) -> Bool {
        let pasteboard = UIPasteboard.general
        // Copied Finder/Files documents attach outright.
        let fileURLs = (pasteboard.urls ?? []).filter(\.isFileURL)
        if !fileURLs.isEmpty {
            store.attach(fileURLs: fileURLs, in: conversationId)
            return true
        }
        // The Mac's rule: image data attaches unless the pasteboard also
        // carries non-URL plain text — a table or rich-text copy ships a
        // rendered image beside its text and should stay a text paste, while
        // a browser's Copy Image only brings the source URL along.
        if let text = pasteboard.string, URL(string: text)?.scheme == nil { return false }
        var hasStaged = false
        for item in pasteboard.items
        where didStage(item: item, in: conversationId, store: store) {
            hasStaged = true
        }
        return hasStaged
    }

    @MainActor
    private static func didStage(
        item: [String: Any], in conversationId: String, store: AppStore
    ) -> Bool {
        // A copy that only registered its file URL per item, rather than one
        // the pasteboard would hand over through `urls`.
        if let url = fileURL(in: item) {
            store.attach(fileURLs: [url], in: conversationId)
            return true
        }
        if let data = data(item, UTType.png) {
            store.attach(
                imageData: data, fileName: "Pasted image.png", contentType: "image/png",
                in: conversationId
            )
            return true
        }
        if let data = data(item, UTType.jpeg) {
            store.attach(
                imageData: data, fileName: "Pasted image.jpeg", contentType: "image/jpeg",
                in: conversationId
            )
            return true
        }
        // TIFF re-encodes — nobody wants a .tiff attachment, on either
        // platform. A pasteboard that handed over a UIImage rather than bytes
        // takes the same road out.
        if let data = data(item, UTType.tiff), let png = UIImage(data: data)?.pngData() {
            store.attach(
                imageData: png, fileName: "Pasted image.png", contentType: "image/png",
                in: conversationId
            )
            return true
        }
        if let image = item.values.compactMap({ $0 as? UIImage }).first, let png = image.pngData() {
            store.attach(
                imageData: png, fileName: "Pasted image.png", contentType: "image/png",
                in: conversationId
            )
            return true
        }
        // Anything else that is a file's worth of bytes: a PDF, a zip, a clip.
        for (identifier, value) in item {
            guard let type = UTType(identifier), let data = value as? Data,
                  type.conforms(to: .data), !type.conforms(to: .text), !type.conforms(to: .url)
            else { continue }
            let name = type.preferredFilenameExtension.map { "Pasted file.\($0)" } ?? "Pasted file"
            store.attach(
                imageData: data, fileName: name,
                contentType: type.preferredMIMEType ?? "application/octet-stream",
                in: conversationId
            )
            return true
        }
        return false
    }

    /// A pasteboard item hands its value over as `Data` most of the time and
    /// as a `UIImage` the rest of it.
    private static func data(_ item: [String: Any], _ type: UTType) -> Data? {
        item[type.identifier] as? Data
    }

    private static func fileURL(in item: [String: Any]) -> URL? {
        let value = item[UTType.fileURL.identifier]
        if let url = value as? URL, url.isFileURL { return url }
        if let data = value as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
            return url
        }
        return nil
    }
}
