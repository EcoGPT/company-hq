import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The Files pin, in the web Library's design language: the folder
// name as the page title, folder chips, then a grouped card of whole-row
// press targets — thumb square, name, quiet date and size, actions revealed
// on hover. Grid mode is the web Library's card grid. the team shapes the tree;
// Archive ends the chips.
struct FilesView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("hq-files-view", store: PresentationDefaults.current) private var viewMode = "list"
    let page: FilesPage
    @State private var openedDocument: ShelfDocument?
    @State private var preview: AttachmentPreviewRequest?
    @State private var openError: String?

    private let chipColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 250), spacing: Tokens.Space.x2),
    ]
    private let cardColumns = [
        GridItem(.adaptive(minimum: 168, maximum: 220), spacing: Tokens.Space.x3),
    ]

    private var currentFolderId: String? { page.trail.last?.id }

    private var subfolders: [Folder] {
        page.folders
            .filter { $0.parentFolderId == currentFolderId }
            .sorted { left, right in
                if left.isArchive != right.isArchive { return right.isArchive }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    /// Documents and files, one library, newest activity first.
    private var entries: [LibraryEntry] {
        let docs = page.documents
            .filter { $0.folderId == currentFolderId }
            .map(LibraryEntry.document)
        let attached = page.files
            .filter { $0.folderId == currentFolderId }
            .map(LibraryEntry.file)
        return (docs + attached).sorted { $0.activityDate > $1.activityDate }
    }

    private var isEmptyLibrary: Bool {
        !page.isLoading && page.loadError == nil && page.folders.filter { !$0.isArchive }.isEmpty
            && page.documents.isEmpty && page.files.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    if !page.trail.isEmpty {
                        breadcrumbs
                    }
                    PageHeader(title: page.trail.last?.name ?? "Files") {
                        IconSegmentedControl(
                            options: [
                                .init(id: "list", symbol: "list.bullet", help: "List view"),
                                .init(id: "grid", symbol: "square.grid.2x2", help: "Grid view"),
                            ],
                            selection: $viewMode
                        )
                    }
                }
                if page.isLoading {
                    ProgressView("Loading files…").frame(maxWidth: .infinity).padding()
                }
                if let loadError = page.loadError {
                    VStack(spacing: 10) {
                        Text(loadError).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await reload() } }.buttonStyle(QuietCapsuleButtonStyle())
                    }.frame(maxWidth: .infinity).padding()
                }
                if isEmptyLibrary {
                    EmptyStateText(
                        "Nothing here yet — attach files in threads."
                    )
                }
                if !page.isLoading, page.loadError == nil, !isEmptyLibrary, subfolders.isEmpty, entries.isEmpty {
                    EmptyStateText("This folder is empty.")
                }
                if !subfolders.isEmpty {
                    LazyVGrid(columns: chipColumns, alignment: .leading, spacing: Tokens.Space.x2) {
                        ForEach(subfolders) { folder in
                            FolderChip(folder: folder) { page.trail.append(folder) }
                        }
                    }
                }
                if !entries.isEmpty {
                    if viewMode == "grid" {
                        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: Tokens.Space.x3) {
                            ForEach(entries) { entry in
                                LibraryCard(entry: entry) { open(entry) }
                            }
                        }
                    } else {
                        // Lazy so a long folder does not mount (and download for)
                        // every row at once; the eager rule is the transcript's.
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                LibraryRow(entry: entry) { open(entry) }
                                if entry.id != entries.last?.id {
                                    RowDivider(inset: 62)
                                }
                            }
                        }
                        .hqCard()
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.x5)
            .padding(.vertical, Tokens.Space.x5)
            .frame(maxWidth: Tokens.Layout.pageContentWidth)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(page.trail.last?.name ?? "Files")
        // The 28pt page title carries the name; a toolbar twin above it
        // would say it twice.
        .toolbar(removing: .title)
        .background(Tokens.Palette.surface)
        .task {
            await reload()
            applyFixtureRoute()
        }
        .sheet(item: $openedDocument) { document in
            ShelfReader(document: document)
        }
        .sheet(item: $preview) { AttachmentPreviewSheet(request: $0) }
        .alert("Couldn’t open document", isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(openError ?? "") }
    }

    /// The way back: a chevron circle, then the path so far. The current
    /// folder is the page title below, not a crumb.
    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Space.x2) {
                Button {
                    page.trail.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(Tokens.Typography.buttonSmall)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(Tokens.Palette.surfaceHover, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back")
                Button("Files") { page.trail.removeAll() }
                    .buttonStyle(.plain)
                    .font(Tokens.Typography.meta)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                ForEach(Array(page.trail.dropLast().enumerated()), id: \.element.id) { index, crumb in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                    Button(crumb.name) { page.trail.removeSubrange((index + 1)...) }
                        .buttonStyle(.plain)
                        .font(Tokens.Typography.meta)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                }
            }
        }
    }

    private func reload() async {
        page.isLoading = !page.hasLoaded
        page.loadError = nil
        guard let client = store.client else {
            page.isLoading = false
            page.loadError = "Sign in to load your files."
            return
        }
        do {
            async let loadedFolders = client.library()
            async let loadedDocuments = client.documents()
            async let loadedFiles = client.files()
            let result = try await (loadedFolders, loadedDocuments, loadedFiles)
            (page.folders, page.documents, page.files) = result
            page.keepTrail()
            page.hasLoaded = true
        } catch {
            // Leaving the page cancels its read; the next visit's read takes over.
            if Task.isCancelled { return }
            page.loadError = page.hasLoaded
                ? "Couldn’t refresh. Showing saved data."
                : "Couldn’t load files. Check your connection and try again."
        }
        page.isLoading = false
    }

    /// A fixture launch opens `HQ_UI_ROUTE=folder:<id>` once.
    private func applyFixtureRoute() {
        #if DEBUG
        guard HQSimulatorFixture.isEnabled, !FixtureRoute.isApplied,
              let raw = ProcessInfo.processInfo.environment["HQ_UI_ROUTE"], raw.hasPrefix("folder:"),
              let folder = page.folders.first(where: { $0.id == raw.dropFirst(7) }) else { return }
        FixtureRoute.isApplied = true
        page.trail = [folder]
        #endif
    }

    private func open(_ entry: LibraryEntry) {
        switch entry {
        case .document(let summary):
            guard let client = store.client else { return }
            Task {
                do { openedDocument = try await client.document(slug: summary.slug) }
                catch { openError = error.localizedDescription }
            }
        case .file(let file):
            preview = AttachmentPreviewRequest(file.attachment)
        }
    }
}

/// What Files read and the folder open in it, kept for the session
/// (`PageMemory`): a return draws them and refreshes behind.
@MainActor @Observable
final class FilesPage {
    var folders: [Folder] = []
    var documents: [ShelfDocumentSummary] = []
    var files: [HubFile] = []
    var trail: [Folder] = []
    /// A read has answered, so a reload refreshes behind what is shown.
    var hasLoaded = false
    var isLoading = true
    var loadError: String?

    /// The open trail, re-read by id from the folders just read: a renamed
    /// folder shows its new name, and the trail stops above one that is gone.
    func keepTrail() {
        let byId = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [Folder] = []
        for crumb in trail {
            guard let folder = byId[crumb.id] else { break }
            kept.append(folder)
        }
        trail = kept
    }
}

extension ShelfDocument: Identifiable {
    var id: String { slug }
}

// MARK: - The unified library entry

enum LibraryEntry: Identifiable {
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
        ISO8601.parse(activityDate).formatted(.dateTime.month(.abbreviated).day())
    }

    var sizeLabel: String? {
        guard case .file(let file) = self else { return nil }
        return ByteCountFormatStyle.FormatInput(file.byteSize)
            .formatted(.byteCount(style: .file))
    }

    var threadId: String? {
        if case .file(let file) = self { return file.conversationId }
        return nil
    }

    var imageFile: HubFile? {
        if case .file(let file) = self, file.contentType.hasPrefix("image/") { return file }
        return nil
    }
}

// MARK: - Pieces

/// Folder chip: icon + name on the hover surface; the Archive reads muted.
private struct FolderChip: View {
    let folder: Folder
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: folder.isArchive ? "archivebox.fill" : "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        folder.isArchive ? Tokens.Palette.inkTertiary : Tokens.Palette.accent
                    )
                Text(folder.name)
                    .font(Tokens.Typography.rowEmphasis)
                    .foregroundStyle(folder.isArchive ? Tokens.Palette.inkSecondary : Tokens.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Space.x3)
            .frame(height: 44)
            .background(
                isHovering ? Tokens.Palette.surfaceActive : Tokens.Palette.surfaceHover,
                in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The web Library's list row: whole-row press target — thumb square, name,
/// quiet date and size, actions on hover.
private struct LibraryRow: View {
    @Environment(AppStore.self) private var store
    let entry: LibraryEntry
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Tokens.Space.x2) {
            Button(action: onOpen) {
                HStack(spacing: Tokens.Space.x3) {
                    EntryThumb(entry: entry, side: 34, corner: Tokens.Radius.thumb)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                            .lineLimit(2)
                        Text([entry.dateLabel, entry.sizeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(Tokens.Typography.meta)
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                if entry.imageFile != nil || entry.sizeLabel != nil {
                    hoverAction("square.and.arrow.down", help: "Download") {
                        if case .file(let file) = entry {
                            FileFetcher.download(file, client: store.client)
                        }
                    }
                }
                if let threadId = entry.threadId {
                    hoverAction("bubble.left", help: "Open thread") {
                        store.openConversation(threadId)
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Tokens.Palette.surfaceHover : .clear)
        .onHover { isHovering = $0 }
        .contextMenu {
            if let threadId = entry.threadId {
                Button("Open Thread") { store.openConversation(threadId) }
            }
        }
    }

    private func hoverAction(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Tokens.Typography.buttonSmall)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .frame(width: 26, height: 26)
                .background(Tokens.Palette.surfaceActive, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Grid mode: the web Library's bordered card — preview pane, then name.
private struct LibraryCard: View {
    @Environment(AppStore.self) private var store
    let entry: LibraryEntry
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                EntryThumb(entry: entry, side: 0, corner: 0)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipped()
                RowDivider(inset: 0)
                HStack(spacing: 6) {
                    Image(systemName: entry.glyph)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(entry.tint)
                    Text(entry.name)
                        .font(Tokens.Typography.captionEmphasis)
                        .foregroundStyle(Tokens.Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.dateLabel)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                }
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 9)
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Glass.cardRadius, style: .continuous))
            .hqGlassCard(interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let threadId = entry.threadId {
                Button("Open Thread") { store.openConversation(threadId) }
            }
        }
    }
}

/// The thumb square: a real thumbnail for images, a tinted glyph otherwise.
/// side == 0 means fill the available space (grid preview pane).
private struct EntryThumb: View {
    @Environment(AppStore.self) private var store
    let entry: LibraryEntry
    let side: CGFloat
    let corner: CGFloat
    @State private var thumbnail: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(entry.tint.opacity(0.10))
            if let thumbnail {
                Image(platform: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: entry.glyph)
                    .font(side == 0 ? .system(size: 32) : .system(size: 14))
                    .foregroundStyle(entry.tint.opacity(0.8))
            }
        }
        .frame(width: side == 0 ? nil : side, height: side == 0 ? nil : side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: entry.imageFile?.id) { await load() }
    }

    private func load() async {
        thumbnail = nil
        guard let file = entry.imageFile, file.byteSize < 8_000_000 else { return }
        // The list's 34pt square needs 160 px, not the grid pane's 900.
        let image = if side > 0 {
            await AttachmentCache.shared.thumbnail(for: file.attachment, client: store.client)
        } else {
            await AttachmentCache.shared.image(for: file.attachment, client: store.client)
        }
        guard !Task.isCancelled else { return }
        thumbnail = image
    }
}

/// Fetches ride the bearer; nothing here is a shareable URL.
@MainActor
enum FileFetcher {
    static func download(_ file: HubFile, client: HQClient?) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        fetch(file, client: client, to: downloads) { url in
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #endif
        }
    }

    private static func fetch(
        _ file: HubFile, client: HQClient?, to folder: URL, then handle: @escaping (URL) -> Void
    ) {
        guard let client else { return }
        Task {
            guard let data = try? await client.attachmentData(id: file.id) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(file.fileName)
            guard (try? data.write(to: destination)) != nil else { return }
            handle(destination)
        }
    }
}

private struct ShelfReader: View {
    @Environment(\.dismiss) private var dismiss
    let document: ShelfDocument

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack {
                Text(document.title)
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                MarkdownFileView(text: document.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Updated by \(document.updatedByName).")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkTertiary)
        }
        .padding(Tokens.Space.x5)
        .frame(minWidth: 460, minHeight: 420)
    }
}
