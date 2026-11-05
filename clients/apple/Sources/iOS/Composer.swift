import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reply, attachment, and editor controls in the system bottom accessory bar.
/// The measured height also gates the transcript's initial bottom anchor.
struct ChatBottomStack: View {
    @Environment(AppStore.self) private var store
    let conversationId: String
    @Binding var height: CGFloat
    let attachmentMenu: ChatAttachmentMenuState

    var body: some View {
        VStack(spacing: 8) {
            ReplyBar(conversationId: conversationId)
            AttachmentDraftStrip(conversationId: conversationId)
            ComposerView(conversationId: conversationId, attachmentMenu: attachmentMenu)
        }
        .hqGlassContainer()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            height = newHeight
        }
    }
}

private struct ReplyBar: View {
    @Environment(AppStore.self) private var store
    let conversationId: String

    /// The composer never remounts on a thread switch, so a reply started in
    /// one chat would show in the next. The target stays on the store (that
    /// chat shows it again on return); only its own conversation draws it,
    /// as the Mac does and as `AppStore.send` already assumes.
    var body: some View {
        if let target = store.replyTarget, target.conversationId == conversationId {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replying to \(target.senderName)")
                        .font(Tokens.Typography.captionEmphasis)
                        .lineLimit(1)
                    Text(store.plainText(target.previewText))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    store.replyTarget = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel reply")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .hqComposerGlass(in: RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 12)
        }
    }
}

/// Messages proportions: an attachment circle followed by a growing text field.
/// The send arrow occupies the field's trailing slot when a draft is ready.
private struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let conversationId: String
    @State private var isImporterOpen = false
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var isPhotoPickerOpen = false
    let attachmentMenu: ChatAttachmentMenuState
    @State private var isEmojiPickerOpen = false
    @State private var focusRequest = 0

    /// The draft lives in the store, keyed by conversation: this view never
    /// remounts on a thread switch, so view-local text would follow the user
    /// from one chat into the next.
    private var draft: Binding<String> {
        Binding(
            get: { store.draftText(for: conversationId) },
            set: { store.setDraftText($0, for: conversationId) }
        )
    }

    private var canSend: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.drafts(in: conversationId).isEmpty
    }

    private var maximumLines: Int {
        if verticalSizeClass == .compact { return dynamicTypeSize.isAccessibilitySize ? 1 : 2 }
        return dynamicTypeSize.isAccessibilitySize ? 2 : 6
    }

    private var placeholder: String {
        guard let conversation = store.conversation(conversationId)
        else { return "Send a message" }
        return "Send a message to \(store.displayName(for: conversation))"
    }

    private var mentions: MentionSuggestions {
        store.mentionSuggestions(draft: draft.wrappedValue, conversationId: conversationId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            if !mentions.visible.isEmpty {
                MentionPicker(candidates: mentions.visible) { candidate in
                    draft.wrappedValue = mentions.applying(candidate)
                    focusRequest &+= 1
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                attachButton
                fieldRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if HQSimulatorFixture.isEnabled, ProcessInfo.processInfo.environment["HQ_UI_KEYBOARD"] == "1" {
                focusRequest += 1
            }
        }
        #endif
        .onChange(of: attachmentMenu.selectedAction) { _, action in
            guard let action else { return }
            attachmentMenu.selectedAction = nil
            switch action {
            case .photos: isPhotoPickerOpen = true
            case .files: isImporterOpen = true
            case .emoji: isEmojiPickerOpen = true
            case .paste: _ = PasteboardAttachments.didStage(in: conversationId, store: store)
            }
        }
        .photosPicker(
            isPresented: $isPhotoPickerOpen, selection: $photoPicks,
            maxSelectionCount: 10, matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoPicks) { _, picks in
            guard !picks.isEmpty else { return }
            let claimed = picks
            photoPicks = []
            Task { await attach(claimed) }
        }
        .fileImporter(
            isPresented: $isImporterOpen, allowedContentTypes: [.item], allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            store.attach(fileURLs: urls, in: conversationId)
        }
        // The Mac hands this to `NSApp.orderFrontCharacterPalette`, which
        // inserts at the caret. iOS has no equivalent — the emoji plane of the
        // system keyboard cannot be summoned by an app — so HQ brings its own
        // palette, and it appends: a picker that covers the field cannot show
        // the caret it would be inserting at anyway.
        .sheet(isPresented: $isEmojiPickerOpen) {
            EmojiPickerSheet { emoji in draft.wrappedValue += emoji }
        }
    }

    private var attachButton: some View {
        Button {
            attachmentMenu.canPaste = PasteboardAttachments.isAvailable
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            attachmentMenu.isPresented = true
        } label: {
            composerCircle("plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach a file")
    }

    private func composerCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Tokens.Palette.ink)
            .frame(width: 44, height: 44)
            .hqComposerGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }

    private static let fieldShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // A native UITextView owns the editing interaction. In addition
            // to multiline growth, dictation and autocorrect, that means the
            // system edit menu and its Paste action reach the first responder
            // directly instead of competing with a SwiftUI gesture on the
            // capsule around it.
            ZStack(alignment: .topLeading) {
                if draft.wrappedValue.isEmpty {
                    Text("Message")
                        .lineLimit(1)
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
                MentionComposerField(
                    text: draft,
                    // People only: MentionText knows `@here` and `@everyone`
                    // whatever roster it is handed.
                    names: mentions.personNames,
                    placeholder: placeholder,
                    focusRequest: focusRequest,
                    maxLines: maximumLines,
                    // A pasted image or file stages as an attachment instead
                    // of doing nothing, which is what a plain text view does
                    // with an image-only pasteboard.
                    canClaimPaste: { PasteboardAttachments.isAvailable },
                    claimPaste: { PasteboardAttachments.didStage(in: conversationId, store: store) }
                )
                .clipped()
            }
            .padding(.vertical, 5)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .clipped()
            .layoutPriority(1)
            .onChange(of: draft.wrappedValue) { _, newValue in
                noteTyping(newValue)
            }
            if canSend {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .hqGlass(in: Circle(), tint: Tokens.Palette.accent, interactive: true)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send message")
            } else {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
        }
        .clipShape(Self.fieldShape)
        .hqComposerGlass(in: Self.fieldShape, interactive: true)
        .accessibilityIdentifier("message-composer-surface")
    }

    /// The store spaces these out; a frame per character is never sent.
    private func noteTyping(_ text: String) {
        guard !text.isEmpty else { return }
        store.sendTyping(in: conversationId)
    }

    private func send() {
        let text = draft.wrappedValue
        draft.wrappedValue = ""
        store.send(text, in: conversationId)
    }

    /// A picked photo arrives as opaque bytes; the store types it by its own
    /// content, the way a dropped screenshot with no extension is typed on
    /// the Mac. Movies only reliably leave the picker as a FILE — loading
    /// one as Data fails outright for large or iCloud-resident videos — and
    /// either way a failure shows in the strip instead of doing nothing.
    private func attach(_ picks: [PhotosPickerItem]) async {
        for pick in picks {
            if pick.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try? await pick.loadTransferable(type: PickedMovie.self) else {
                    store.noteAttachmentFailure("Couldn't load that video", in: conversationId)
                    continue
                }
                let upload = store.attach(fileURLs: [movie.url], in: conversationId)
                // The picker's copy lives in its own tmp folder and was never
                // deleted: a phone gained the video's size per pick. It goes
                // once the upload, or the refusal, is done with the file.
                let folder = movie.url.deletingLastPathComponent()
                Task {
                    await upload.value
                    try? FileManager.default.removeItem(at: folder)
                }
                continue
            }
            guard let data = try? await pick.loadTransferable(type: Data.self) else {
                store.noteAttachmentFailure("Couldn't load that photo", in: conversationId)
                continue
            }
            let name = pick.supportedContentTypes.first?.preferredFilenameExtension
                .map { "photo.\($0)" } ?? "photo"
            let type = pick.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            store.attach(
                imageData: data, fileName: name, contentType: type, in: conversationId
            )
        }
    }
}

/// The picker's received file dies with the import closure, so the
/// representation copies it somewhere owned before handing back a URL.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hq-picks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

/// The tag list above the field. On the Mac the arrows walk it; a phone just
/// taps the one it wants.
private struct MentionPicker: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var contentHeight: CGFloat = 44
    let candidates: [MentionCandidate]
    let onPick: (MentionCandidate) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(candidates) { candidate in
                    Button { onPick(candidate) } label: {
                        HStack(spacing: Tokens.Space.x2) {
                            switch candidate {
                            case .person(let person) where person.kind == "bot":
                                BotAvatarView(name: person.name, size: 22)
                            case .person(let person):
                                AvatarView(name: person.name, size: 22)
                            case .broadcast:
                                // No face to draw: the room is not a person.
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Tokens.Palette.inkSecondary)
                                    .frame(width: 22, height: 22)
                                    .background(Tokens.Palette.inkTertiary.opacity(0.18), in: Circle())
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.label)
                                    .font(Tokens.Typography.row)
                                    .foregroundStyle(Tokens.Palette.ink)
                                if let caption = candidate.caption {
                                    Text(caption)
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(Tokens.Palette.inkSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Tokens.Space.x3)
                        .padding(.vertical, Tokens.Space.x2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, verticalSizeClass == .compact ? 80 : 150))
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("composer-mentions")
        .frame(maxWidth: 300, alignment: .leading)
        .hqGlass(in: RoundedRectangle(cornerRadius: 22))
        .padding(.leading, 42)
    }
}

/// HQ's own emoji palette — the phone's answer to the Mac's smiley, which
/// hands off to the system character palette. An app cannot raise the
/// keyboard's emoji plane, so this is a plain grid in a sheet: it stays up
/// after a pick, because choosing two emoji in a row is the common case and
/// re-opening a sheet per glyph is not.
struct EmojiPickerSheet: View {
    /// A tapback is one decision, so the palette that picks one closes behind
    /// it; the composer's palette stays up, because choosing two emoji in a
    /// row is the common case there.
    var isSingleChoice = false
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let columns = [
        GridItem(.adaptive(minimum: 44), spacing: Tokens.Space.x1)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: Tokens.Space.x1) {
                    ForEach(EmojiCatalogue.sections) { section in
                        Section {
                            ForEach(section.emoji, id: \.self) { emoji in
                                Button {
                                    onPick(emoji)
                                    if isSingleChoice { dismiss() }
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 30))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(emoji)
                            }
                        } header: {
                            Text(section.name)
                                .font(Tokens.Typography.captionEmphasis)
                                .foregroundStyle(Tokens.Palette.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Tokens.Space.x2)
                        }
                    }
                }
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.bottom, Tokens.Space.x4)
            }
            .navigationTitle("Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A curated palette rather than the whole of Unicode: the point is to reach
/// the emoji people actually send in a chat without scrolling past thousands.
/// The tapback strips (`MessageSheets`) keep their own shorter list — those
/// are reactions, these are text.
enum EmojiCatalogue {
    struct Section: Identifiable {
        let name: String
        let emoji: [String]
        var id: String { name }
    }

    static let sections: [Section] = [
        Section(name: "Smileys", emoji: [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃",
            "😉", "😊", "😇", "🥰", "😍", "😘", "😗", "😚", "😋", "😛",
            "🤪", "🤨", "🧐", "🤓", "😎", "🥳", "😏", "😒", "😞", "😔",
            "😟", "😕", "🙁", "😣", "😖", "😫", "😩", "🥺", "😢", "😭",
            "😤", "😠", "😡", "🤬", "🤯", "😳", "🥵", "🥶", "😶‍🌫️", "😱",
            "😨", "😰", "😥", "🤗", "🤔", "🤭", "🤫", "😬", "🙄", "😯",
            "😴", "🤤", "😪", "😵", "🤐", "🥴", "🤢", "🤮", "🤧", "😷",
            "🤒", "🤕", "🤑", "🤠", "😈", "👿", "💀", "☠️", "👻", "👽",
            "🤖", "💩", "😺", "😸", "😹", "😻", "😼", "😽", "🙀", "😿",
        ]),
        Section(name: "Gestures & People", emoji: [
            "👍", "👎", "👌", "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘",
            "🤙", "👈", "👉", "👆", "👇", "☝️", "✋", "🤚", "🖐️", "🖖",
            "👋", "🤝", "🙏", "✍️", "💪", "🦾", "🫶", "👏", "🙌", "👐",
            "🤲", "🫡", "🤦", "🤷", "🙋", "🙆", "🙅", "💁", "🧏", "🤵",
            "👤", "👥", "🧑‍💻", "👨‍💻", "👩‍💻", "🧑‍🔬", "🕺", "💃", "🧠", "👀",
        ]),
        Section(name: "Nature", emoji: [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯",
            "🦁", "🐮", "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐔", "🐧",
            "🐦", "🦅", "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛",
            "🦋", "🐌", "🐞", "🐢", "🐍", "🐙", "🦑", "🦀", "🐬", "🐳",
            "🐟", "🌵", "🌲", "🌳", "🌴", "🌱", "🌿", "☘️", "🍀", "🍃",
            "🌸", "🌼", "🌻", "🌺", "🌹", "🌷", "🌍", "🌎", "🌏", "🌕",
            "⭐️", "🌟", "✨", "⚡️", "🔥", "🌈", "☀️", "⛅️", "☁️", "🌧️",
            "❄️", "🌊", "💧", "🍄", "🪸",
        ]),
        Section(name: "Food & Drink", emoji: [
            "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐",
            "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🥑", "🥦", "🥬",
            "🥕", "🌽", "🌶️", "🥔", "🍠", "🥐", "🥯", "🍞", "🥖", "🧀",
            "🥚", "🍳", "🥞", "🧇", "🥓", "🍔", "🍟", "🍕", "🌭", "🥪",
            "🌮", "🌯", "🥗", "🍝", "🍜", "🍲", "🍣", "🍱", "🥟", "🍤",
            "🍚", "🍙", "🍦", "🍩", "🍪", "🎂", "🍰", "🧁", "🍫", "🍬",
            "🍿", "🧂", "☕️", "🍵", "🧃", "🥤", "🍺", "🍻", "🥂", "🍷",
            "🥃", "🍸", "🧉", "🧊",
        ]),
        Section(name: "Activity & Travel", emoji: [
            "⚽️", "🏀", "🏈", "⚾️", "🎾", "🏐", "🏉", "🎱", "🏓", "🏸",
            "🥅", "⛳️", "🏹", "🎣", "🥊", "🥋", "⛸️", "🎿", "🏂", "🏋️",
            "🤸", "🧘", "🏃", "🚶", "🧗", "🚴", "🏊", "🏄", "🎯", "🎮",
            "🎲", "🧩", "🎸", "🥁", "🎹", "🎺", "🎤", "🎧", "🎬", "🎨",
            "🚗", "🚕", "🚙", "🚌", "🏎️", "🚓", "🚑", "🚒", "🚚", "🚜",
            "🛵", "🏍️", "🚲", "🛴", "✈️", "🚀", "🛸", "🚁", "⛵️", "🚢",
            "🚂", "🚆", "🗺️", "🗽", "🗼", "🏰", "🏝️", "🏔️", "⛺️", "🌉",
        ]),
        Section(name: "Objects", emoji: [
            "⌚️", "📱", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "💽", "💾", "📀",
            "📷", "📸", "🎥", "📞", "☎️", "📺", "📻", "⏰", "⏳", "🔋",
            "🔌", "💡", "🔦", "🕯️", "🧯", "🛢️", "💸", "💵", "💰", "💳",
            "🧾", "✉️", "📧", "📦", "📪", "📝", "📄", "📊", "📈", "📉",
            "📋", "📌", "📎", "🖇️", "📐", "📏", "✂️", "🗃️", "🗄️", "🗑️",
            "🔒", "🔓", "🔑", "🔨", "🪓", "⛏️", "🔧", "🔩", "⚙️", "🧰",
            "🧲", "🧪", "🧬", "🔬", "🔭", "📡", "💊", "🩹", "🚪", "🛏️",
            "🧹", "🎁", "🎈", "🎉", "🎊", "🏆", "🥇", "🥈", "🥉", "🏅",
        ]),
        Section(name: "Symbols", emoji: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
            "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💯", "‼️",
            "❓", "❗️", "⁉️", "✅", "❌", "⭕️", "🚫", "⚠️", "🔞", "♻️",
            "✔️", "☑️", "🔘", "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️",
            "⚪️", "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "⬛️", "⬜️", "🔶",
            "🔷", "🔺", "🔻", "▶️", "⏸️", "⏹️", "⏺️", "⏭️", "🔁", "🔀",
            "➕", "➖", "➗", "✖️", "♾️", "💲", "🔝", "🔜", "🆕", "🆒",
            "🆗", "🆙", "🈶", "🕐", "💤", "💬", "💭", "🗯️", "🔔", "🔕",
        ]),
    ]
}
