import SwiftUI

/// The Drive: folders, and inside them one library — the shared
/// documents and the threads' attachments together, newest activity first,
/// exactly as the Mac reads it. Read-and-open on a phone; filing is desk work.
///
/// **Why there is no segmented Documents/Files split.** The surface is a
/// folder tree — folders inside folders, documents and files placed in them —
/// one tree holding both kinds, which is the shape the Mac's merged list
/// already has. Two tabs would not just be a different look: a Documents tab
/// that ignored `folderId` would hide a document filed into a folder and list
/// it at the root forever. One list per folder keeps the two clients agreeing
/// about where a document lives.
struct FilesView: View {
    @Environment(AppStore.self) private var store
    // The Mac's key, deliberately: same preference, same name, so the two
    // clients read as one app to anyone who uses both.
    @AppStorage("hq-files-view") private var viewMode = "list"
    @State private var folders: [Folder] = []
    @State private var files: [HubFile] = []
    @State private var documents: [ShelfDocumentSummary] = []
    @State private var trail: [Folder] = []
    @State private var preview: AttachmentPreviewRequest?
    @State private var openDocument: ShelfSlug?
    @State private var didFail = false

    private let cardColumns = [
        GridItem(.adaptive(minimum: 104, maximum: 168), spacing: Tokens.Space.x3),
    ]

    private var currentFolderId: String? { trail.last?.id }

    private var subfolders: [Folder] {
        folders
            .filter { $0.parentFolderId == currentFolderId }
            .sorted { left, right in
                if left.isArchive != right.isArchive { return right.isArchive }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    /// Documents and files, one library, newest activity first.
    private var entries: [LibraryItem] {
        let docs = documents.filter { $0.folderId == currentFolderId }.map(LibraryItem.document)
        let attached = files.filter { $0.folderId == currentFolderId }.map(LibraryItem.file)
        return (docs + attached).sorted { $0.activityDate > $1.activityDate }
    }

    var body: some View {
        List {
            Group {
                if !trail.isEmpty {
                    Section {
                        Button {
                            trail.removeLast()
                        } label: {
                            Label(trail.dropLast().last?.name ?? "Files", systemImage: "chevron.left")
                                .font(Tokens.Typography.row)
                        }
                    }
                }
                if !subfolders.isEmpty {
                    Section("Folders") {
                        ForEach(subfolders) { folder in
                            Button { trail.append(folder) } label: { folderRow(folder) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Section(trail.last?.name ?? "All items") {
                    if entries.isEmpty {
                        VStack(spacing: Tokens.Space.x3) {
                            EmptyStateText(didFail ? "The Drive could not be read." : "Nothing here yet.")
                            if didFail {
                                Button("Try Again") { Task { await load() } }
                                    .buttonStyle(QuietCapsuleButtonStyle())
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else if viewMode == "grid" {
                        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: Tokens.Space.x3) {
                            ForEach(entries) { entry in
                                LibraryCardView(item: entry) { open(entry) }
                            }
                        }
                        .padding(.vertical, Tokens.Space.x2)
                        .listRowInsets(EdgeInsets(
                            top: 0, leading: Tokens.Space.x4, bottom: 0, trailing: Tokens.Space.x4
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(entries) { entry in
                            LibraryRowView(item: entry) { open(entry) }
                        }
                    }
                }
            }
            .listRowBackground(Tokens.Palette.surface)
        }
        .hqCanvas()
        .navigationTitle(trail.last?.name ?? "Files")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("View", selection: $viewMode) {
                        Label("List", systemImage: "list.bullet").tag("list")
                        Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                    }
                } label: {
                    Image(systemName: viewMode == "grid" ? "square.grid.2x2" : "list.bullet")
                }
                .accessibilityLabel("File view")
                .accessibilityValue(viewMode == "grid" ? "Grid" : "List")
            }
        }
        .fullScreenCover(item: $preview) { request in
            AttachmentPreviewSheet(request: request).environment(store)
        }
        .sheet(item: $openDocument) { document in
            ShelfDocumentSheet(slug: document.id).environment(store)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func folderRow(_ folder: Folder) -> some View {
        HStack(spacing: Tokens.Space.x3) {
            IconTile(
                symbol: folder.isArchive ? "archivebox.fill" : "folder.fill",
                style: .tinted(folder.isArchive ? Tokens.Palette.inkTertiary : Tokens.Palette.accent),
                size: 38
            )
            Text(folder.name)
                .font(Tokens.Typography.row)
                .foregroundStyle(Tokens.Palette.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Palette.inkTertiary)
        }
    }

    private func open(_ item: LibraryItem) {
        switch item {
        case .document(let summary):
            openDocument = ShelfSlug(id: summary.slug)
        case .file(let file):
            // The Drive lists files; the previewer wants an attachment. They
            // are the same row on the wire — the id is the attachment's.
            preview = AttachmentPreviewRequest(file.attachment)
        }
    }

    private func load() async {
        guard let client = store.client else { return }
        do {
            async let foldersTask = client.library()
            async let filesTask = client.files()
            async let documentsTask = client.documents()
            (folders, files, documents) = try await (foldersTask, filesTask, documentsTask)
            didFail = false
        } catch {
            didFail = true
        }
    }
}

// MARK: - The unified library entry

/// One thing in the library, whichever kind it is. The Mac has the same idea
/// in its own view layer (`LibraryEntry`); that file is `Sources/Shared/Views`,
/// which the phone target excludes, so this is the phone's copy under its own
/// name — the shape is small and the alternative is lifting a Mac view file
/// into `Shared/`.
enum LibraryItem: Identifiable {
    case document(ShelfDocumentSummary)
    case file(HubFile)

    var id: String {
        switch self {
        case .document(let summary): return "doc-" + summary.slug
        case .file(let file): return "file-" + file.id
        }
    }

    var name: String {
        switch self {
        case .document(let summary): return summary.title
        case .file(let file): return file.fileName
        }
    }

    var glyph: String {
        switch self {
        case .document(let summary):
            return summary.slug == "filing-system" ? "books.vertical.fill" : "doc.text.fill"
        case .file(let file):
            if file.contentType.hasPrefix("image/") { return "photo.fill" }
            if file.contentType.hasPrefix("video/") { return "film.fill" }
            if file.contentType.contains("pdf") { return "doc.richtext.fill" }
            if file.contentType.hasPrefix("text/") { return "doc.plaintext.fill" }
            return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .document: return Tokens.Palette.accent
        case .file(let file):
            if file.contentType.hasPrefix("image/") { return .purple }
            if file.contentType.hasPrefix("video/") { return .orange }
            if file.contentType.contains("pdf") { return .red }
            return Tokens.Palette.inkSecondary
        }
    }

    var activityDate: String {
        switch self {
        case .document(let summary): return summary.updatedAt
        case .file(let file): return file.createdAt
        }
    }

    var dateLabel: String {
        RelativeStamp.list(ISO8601.parse(activityDate))
    }

    /// Who last touched it, and how big it is when that is a real number.
    var subtitle: String {
        switch self {
        case .document(let summary):
            return "\(summary.updatedByName) · \(dateLabel)"
        case .file(let file):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(file.byteSize), countStyle: .file
            )
            return "\(file.uploaderName) · \(size) · \(dateLabel)"
        }
    }

    var threadId: String? {
        if case .file(let file) = self { return file.conversationId }
        return nil
    }

    /// The attachment to draw a real thumbnail from — images only, and only
    /// the ones small enough that a library scroll is not a download storm.
    var thumbnailAttachment: Attachment? {
        guard case .file(let file) = self,
              file.contentType.hasPrefix("image/"),
              file.byteSize < 8_000_000
        else { return nil }
        return file.attachment
    }
}

// MARK: - Pieces

/// The thumb square: the picture itself for images, a tinted glyph otherwise.
/// Bytes come through `AttachmentCache` — the same store the transcript's
/// photos use, memory plus the on-disk `AttachmentFileCache` — so a file
/// already seen in a thread draws here without touching the network.
/// `side == 0` means fill the space it is given (the grid card's preview).
private struct LibraryThumb: View {
    @Environment(AppStore.self) private var store
    let item: LibraryItem
    let side: CGFloat
    let corner: CGFloat

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Rectangle().fill(item.tint.opacity(0.12))
            if let image {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.glyph)
                    .font(.system(size: side == 0 ? 28 : side * 0.42, weight: .medium))
                    .foregroundStyle(item.tint.opacity(0.85))
            }
        }
        .frame(width: side == 0 ? nil : side, height: side == 0 ? nil : side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: item.thumbnailAttachment?.id) {
            image = nil
            guard let attachment = item.thumbnailAttachment else { return }
            // The list's 40pt square needs 160 px, not the grid card's 900.
            let loaded = if side > 0 {
                await AttachmentCache.shared.thumbnail(for: attachment, client: store.client)
            } else {
                await AttachmentCache.shared.image(for: attachment, client: store.client)
            }
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// List mode: thumb, name, the quiet who/size/when line.
private struct LibraryRowView: View {
    @Environment(AppStore.self) private var store
    let item: LibraryItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Tokens.Space.x3) {
                LibraryThumb(item: item, side: 40, corner: Tokens.Radius.thumb)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(item.subtitle)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { LibraryMenu(item: item) }
    }
}

/// Grid mode: the Mac's library card — preview pane, then name and date.
private struct LibraryCardView: View {
    @Environment(AppStore.self) private var store
    let item: LibraryItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                LibraryThumb(item: item, side: 0, corner: 0)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .clipped()
                HStack(spacing: 5) {
                    Image(systemName: item.glyph)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(item.tint)
                    Text(item.name)
                        .font(Tokens.Typography.captionEmphasis)
                        .foregroundStyle(Tokens.Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Tokens.Space.x2)
                .padding(.vertical, 7)
            }
            .background(Tokens.Palette.surfaceInput)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.gridCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.gridCard, style: .continuous)
                    .strokeBorder(Tokens.Palette.borderLight, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { LibraryMenu(item: item) }
    }
}

/// The long-press menu, one definition for both modes. Opening the thread
/// writes the conversation through `store.destination`, which is the phone
/// split view's selection — Files leaves the detail column and the transcript
/// takes it (`RootView`).
private struct LibraryMenu: View {
    @Environment(AppStore.self) private var store
    let item: LibraryItem

    var body: some View {
        if let threadId = item.threadId {
            Button {
                store.openConversation(threadId)
            } label: {
                Label("Open Thread", systemImage: "bubble.left")
            }
        }
    }
}

private struct ShelfSlug: Identifiable {
    let id: String
}

private struct ShelfDocumentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let slug: String
    @State private var document: ShelfDocument?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let document {
                    MarkdownFileView(text: document.content)
                        .padding(Tokens.Space.x4)
                } else {
                    ProgressView().padding(Tokens.Space.x6)
                }
            }
            .background(Tokens.Palette.surface)
            .scrollContentBackground(.hidden)
            .navigationTitle(document?.title ?? "Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { document = try? await store.client?.document(slug: slug) }
    }
}
