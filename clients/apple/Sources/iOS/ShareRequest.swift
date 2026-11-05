import Foundation

/// One thing to hand to `ShareSheet` (in `AttachmentViews`), as a
/// `sheet(item:)` payload. Identity is per-request, never the content:
/// sharing the same recording or the same link twice has to present
/// the sheet twice.
struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]

    init(_ items: [Any]) {
        self.items = items
    }
}
