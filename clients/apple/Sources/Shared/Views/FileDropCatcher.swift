import AppKit
import SwiftUI
import UniformTypeIdentifiers

// SwiftUI's onDrop can only unwrap what NSItemProvider models — and the drags
// people actually make are richer: a dragged screenshot thumbnail is a file
// PROMISE (so is an image pulled off Safari, Photos, or a Mail attachment),
// and some apps offer only raw image bytes. This AppKit destination accepts
// promises, real file URLs, and raw image data, in that order of preference,
// so one drag never attaches twice.
struct FileDropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onFiles: ([URL]) -> Void
    let onImageData: (_ data: Data, _ fileName: String, _ contentType: String) -> Void

    func makeNSView(context: Context) -> DropCatcherNSView {
        let view = DropCatcherNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: DropCatcherNSView, context: Context) {
        update(view)
    }

    private func update(_ view: DropCatcherNSView) {
        view.onTargeted = { isTargeted = $0 }
        view.onFiles = onFiles
        view.onImageData = onImageData
    }
}

final class DropCatcherNSView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onImageData: ((Data, String, String) -> Void)?

    // The source app writes promised files on this queue, off the main thread.
    // Built on the first promise received: every sidebar row, pin and rail
    // cell owns a catcher, and almost none ever see a drop.
    private lazy var promiseQueue = OperationQueue()

    private static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    private static let draggedTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + [.fileURL, .png, .tiff, jpeg]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Clicks fall through to the chat; only drags land here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receive(promises: receivers)
            return true
        }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
        }
        return didAttachImageData(from: pasteboard)
    }

    private func receive(promises: [NSFilePromiseReceiver]) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-drops-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for receiver in promises {
            receiver.receivePromisedFiles(
                atDestination: destination, operationQueue: promiseQueue
            ) { url, error in
                guard error == nil else { return }
                Task { @MainActor [weak self] in self?.onFiles?([url]) }
            }
        }
    }

    private func didAttachImageData(from pasteboard: NSPasteboard) -> Bool {
        if let data = pasteboard.data(forType: .png) {
            onImageData?(data, "Dropped image.png", "image/png")
            return true
        }
        if let data = pasteboard.data(forType: Self.jpeg) {
            onImageData?(data, "Dropped image.jpeg", "image/jpeg")
            return true
        }
        // TIFF is the lingua franca of old-school image drags, but nobody
        // wants a .tiff attachment — re-encode.
        if let data = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            onImageData?(png, "Dropped image.png", "image/png")
            return true
        }
        return false
    }
}
