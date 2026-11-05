import AppKit
import SwiftUI

// A message bubble's text, selectable the way text is in every other app:
// press and drag highlights, and the drag keeps going into the bubbles above
// and below it. ⌘C copies the whole run.
//
// It cannot be SwiftUI's `.textSelection(.enabled)` — that hands right-click to
// the system text menu, and the row's own menu (tapbacks, reply, edit, Copy)
// has to win everywhere on the row, which is why selection is custom.
// An AppKit text view can give its menu up: this one answers nil and lets the
// click travel on to SwiftUI.
//
// Every button opens that menu: a right- or control-click travels up to it,
// and a plain click raises it too — clicking a bubble is how a tapback gets
// put on one, and the menu's first two rows ARE the tapback strips.
//
// The selection itself belongs to `TranscriptSelection`, not to these views —
// an `NSTextView`'s own selection stops at its own edge, and the bar is
// Messages': one continuous highlight across the whole transcript.
struct SelectableBubbleText: NSViewRepresentable {
    let messageId: String
    let text: String
    let isOwn: Bool
    /// The roster `@Name` is matched against, so a tag can be drawn as the
    /// name alone. It belongs in every cache key below: a tag loses its `@`
    /// and gains weight, and both move glyphs.
    var names: [String] = []
    let selection: TranscriptSelection
    /// A plain click on the bubble raises the row's menu — tapbacks first.
    /// Off for a message still in flight, whose menu has nothing to offer.
    var clickOpensMenu = true

    func makeCoordinator() -> Measurer { Measurer() }

    /// Process-wide memory for what a bubble draws and how big it is. A
    /// switch destroys the whole scroll content and rebuilds every bubble
    /// from empty — a fresh coordinator, a fresh Markdown render, four fresh
    /// TextKit probes each — so anything held per coordinator is gone just
    /// when it is needed most. These two survive the switch, and a chat just
    /// left comes back from memory. Main-actor only (every caller is a view
    /// method), bounded by count, oldest entry out first.
    @MainActor
    enum Memory {
        struct StringKey: Hashable {
            let text: String
            let roster: Int
            let isOwn: Bool
            /// The render turns a timestamp link into a time in the current
            /// zone, so a zone change (travel, a manual change) must not be
            /// answered from a string built for the old one.
            let zone: String
        }

        struct SizeKey: Hashable {
            let text: String
            let roster: Int
            let width: CGFloat
            let zone: String
        }

        /// An insertion-ordered dictionary that forgets its oldest entry
        /// first. A bubble's string and sizes are rebuilt cheaply once, so
        /// plain FIFO is enough; the cap is what matters.
        struct Bounded<Key: Hashable, Value> {
            let limit: Int
            private(set) var entries: [Key: Value] = [:]
            private var order: [Key] = []
            private var head = 0

            init(limit: Int) { self.limit = limit }

            var count: Int { entries.count }

            subscript(key: Key) -> Value? { entries[key] }

            mutating func insert(_ value: Value, for key: Key) {
                if entries.updateValue(value, forKey: key) == nil {
                    order.append(key)
                    while entries.count > limit, head < order.count {
                        entries.removeValue(forKey: order[head])
                        head += 1
                    }
                    // Compact the queue once the dead prefix outweighs the live part.
                    if head > 1_024, head * 2 > order.count {
                        order.removeFirst(head)
                        head = 0
                    }
                }
            }

            mutating func removeAll() {
                entries.removeAll()
                order.removeAll()
                head = 0
            }
        }

        // A long post is rendered for its bubble and not kept.
        static let maxCachedLength = 20_000

        static var strings = Bounded<StringKey, NSAttributedString>(limit: 1_500)
        static var sizes = Bounded<SizeKey, CGSize>(limit: 12_000)

        static func attributed(
            text: String, isOwn: Bool, names: [String]
        ) -> NSAttributedString {
            guard text.utf16.count <= maxCachedLength else {
                return SelectableBubbleText.attributedString(for: text, isOwn: isOwn, names: names)
            }
            let key = StringKey(
                text: text, roster: MentionText.rosterID(names), isOwn: isOwn,
                zone: TimeZone.current.identifier
            )
            if let hit = strings[key] { return hit }
            let built = SelectableBubbleText.attributedString(for: text, isOwn: isOwn, names: names)
            strings.insert(built, for: key)
            return built
        }

        static func size(text: String, names: [String], width: CGFloat) -> CGSize? {
            guard text.utf16.count <= maxCachedLength else { return nil }
            return sizes[SizeKey(
                text: text, roster: MentionText.rosterID(names), width: width,
                zone: TimeZone.current.identifier
            )]
        }

        static func remember(_ size: CGSize, text: String, names: [String], width: CGFloat) {
            guard text.utf16.count <= maxCachedLength else { return }
            sizes.insert(
                size,
                for: SizeKey(
                    text: text, roster: MentionText.rosterID(names), width: width,
                    zone: TimeZone.current.identifier
                )
            )
        }

        static func reset() {
            strings.removeAll()
            sizes.removeAll()
        }
    }

    // Sizing gets its OWN TextKit stack, never the live view's. Measuring
    // through the view broke every incoming bubble: `usedRect` reports
    // the full container width once the container has been resized after an
    // earlier layout, and SwiftUI probes a row with a zero-width proposal
    // before the real one whenever the row reserves the avatar gutter — so the
    // bubble stopped hugging and took the whole 420pt cap. Setting the storage
    // AFTER the width is the full invalidation that keeps the used rect tight.
    final class Measurer {
        private let storage = NSTextStorage()
        private let layoutManager = NSLayoutManager()
        private let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )

        init() {
            storage.addLayoutManager(layoutManager)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            layoutManager.addTextContainer(container)
        }

        // The memo: SwiftUI re-asks the whole transcript's sizes on every
        // animation frame (typing dots, the activity shimmer), and a bubble's
        // text almost never changes between passes. The font is fixed and
        // colors don't move glyphs, so (text, width) decides the answer — but
        // each pass proposes MORE than one width per bubble (the zero-width
        // probe from #79 before the real one), so a single-slot memo thrashes
        // and every pass re-runs the Markdown render and TextKit for every
        // bubble in the transcript (a regression seen twice). One entry
        // per width, all invalidated together when the text changes, and the
        // attributed string is built once per text, not once per miss.
        private var memoText: String?
        private var memoAttributed: NSAttributedString?
        private var sizesByWidth: [CGFloat: CGSize] = [:]

        private static func hasCodeBlock(_ string: NSAttributedString) -> Bool {
            var found = false
            string.enumerateAttribute(
                .hqCodeBlock, in: NSRange(location: 0, length: string.length)
            ) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }

        func size(
            of text: String, fitting width: CGFloat,
            attributed: () -> NSAttributedString
        ) -> CGSize {
            if text != memoText {
                memoText = text
                memoAttributed = nil
                sizesByWidth.removeAll(keepingCapacity: true)
            }
            if let known = sizesByWidth[width] { return known }
            // A live window resize can walk the proposal through many widths;
            // the text is the natural reset, so cap the stragglers.
            if sizesByWidth.count > 32 { sizesByWidth.removeAll(keepingCapacity: true) }
            let string = memoAttributed ?? attributed()
            memoAttributed = string
            container.size = CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
            storage.setAttributedString(string)
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            // A fenced block is set in from both sides, but the used rect
            // only counts the head indent; without the tail's share the
            // bubble would end where the text does and its panel would be
            // clamped flat. Never past the width offered.
            var hugged = ceil(used.maxX)
            if Self.hasCodeBlock(string) {
                hugged = min(hugged + ChatMarkdown.CodeStyle.blockPadding, container.size.width)
            }
            let size = CGSize(width: hugged, height: ceil(used.maxY))
            sizesByWidth[width] = size
            return size
        }
    }

    func makeNSView(context: Context) -> BubbleTextView {
        // TextKit 1 on purpose: the selection is drawn through the layout
        // manager, and a plain `NSTextView(frame:)` is TextKit 2, whose
        // `layoutManager` is nil.
        let storage = NSTextStorage()
        let layoutManager = CodeBackgroundLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = BubbleTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize.zero
        // The string carries its own link colour — white on a blue bubble — so
        // the view must not repaint links in the system's.
        view.linkTextAttributes = [:]
        // The transcript accepts dropped files; a bubble in the middle of it
        // must not swallow the drop.
        view.unregisterDraggedTypes()
        storage.setAttributedString(attributed)
        adopt(view)
        return view
    }

    func updateNSView(_ view: BubbleTextView, context: Context) {
        // The transcript re-updates every visible row on every store change
        // (typing, presence, receipts). The string depends only on the text
        // and the bubble side, so only those rebuild it — resetting the
        // storage re-renders the Markdown and relays out the live view.
        if view.renderedText != text || view.renderedIsOwn != isOwn
            || view.renderedNames != names {
            view.textStorage?.setAttributedString(attributed)
        }
        adopt(view)
    }

    static func dismantleNSView(_ view: BubbleTextView, coordinator: Measurer) {
        view.selection?.unregister(view.messageId)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: BubbleTextView, context: Context
    ) -> CGSize? {
        Self.measure(
            text: text, names: names, proposedWidth: proposal.width,
            measurer: context.coordinator
        ) { attributed }
    }

    /// The widest the text can ever be drawn: the bubble cap less
    /// `ChatBubble`'s padding on both sides.
    static let contentCap = Tokens.Bubble.maxWidth - 2 * Tokens.Bubble.paddingHorizontal

    @MainActor
    static func measure(
        text: String, names: [String], proposedWidth: CGFloat?, measurer: Measurer,
        attributed: () -> NSAttributedString
    ) -> CGSize {
        // SwiftUI probes every bubble at its real width, at zero and
        // unspecified in each pass. The zero probe asks for the minimum
        // width; laid out for real it is one glyph per line, the most
        // expensive layout a bubble can have. Answer it from the cap's
        // layout instead — about a glyph wide, at the real height — so one
        // TextKit layout serves all three. A row is only drawn at this answer
        // in a column under ~154 pt, which RootView's 860 pt minimum rules out.
        if let proposed = proposedWidth, proposed.isFinite, proposed <= 1 {
            let capSize = measure(
                text: text, names: names, proposedWidth: contentCap,
                measurer: measurer, attributed: attributed
            )
            return CGSize(
                width: min(capSize.width, ceil(Tokens.Bubble.textFont.pointSize)),
                height: capSize.height
            )
        }
        // An unspecified or infinite proposal means the cap: a bubble never
        // grows past it, and the measured rect then hugs the text inside it.
        let width = min(proposedWidth ?? contentCap, contentCap)
        // The process-wide answer first: a bubble measured in any earlier
        // pass, or before the last chat switch, costs a dictionary lookup.
        // The roster rides in the key: the same source text renders to
        // different glyphs once the people in it are known.
        if let known = Memory.size(text: text, names: names, width: width) { return known }
        // Only a true miss reaches the per-coordinator memo (and TextKit),
        // so the key it wants is built here, not on every probe.
        let key = "\(MentionText.rosterID(names))\u{0}\(text)"
        let size = measurer.size(of: key, fitting: width, attributed: attributed)
        Memory.remember(size, text: text, names: names, width: width)
        return size
    }

    /// SwiftUI recycles these views across messages, so the registration has to
    /// follow the id rather than the view.
    private func adopt(_ view: BubbleTextView) {
        if view.messageId != messageId, !view.messageId.isEmpty {
            view.selection?.unregister(view.messageId)
        }
        view.messageId = messageId
        view.renderedText = text
        view.renderedIsOwn = isOwn
        view.renderedNames = names
        view.selection = selection
        view.clickOpensMenu = clickOpensMenu
        // The system's selection blue is invisible on a blue bubble; there the
        // highlight is the bubble's own white, dimmed.
        view.selectionColor = isOwn
            ? NSColor.white.withAlphaComponent(0.32)
            : .selectedTextBackgroundColor
        selection.register(view, for: messageId)
    }

    private var attributed: NSAttributedString {
        Memory.attributed(text: text, isOwn: isOwn, names: names)
    }

    /// Code is set one step under the bubble's text, monospaced.
    static func codeFont(bold: Bool) -> NSFont {
        .monospacedSystemFont(ofSize: ChatMarkdown.CodeStyle.macPointSize, weight: bold ? .bold : .regular)
    }

    /// The wash behind code. It resolves against the view's appearance when it
    /// is drawn, so a bubble keeps reading after the system flips to dark.
    static func codeFill(isOwn: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fill = ChatMarkdown.CodeStyle.fill(isOwn: isOwn, isDark: isDark)
            return NSColor(white: fill.white, alpha: fill.opacity)
        }
    }

    /// What a bubble draws and measures: the same string for both, so the
    /// code face is always counted in the bubble's size.
    static func attributedString(for text: String, isOwn: Bool, names: [String]) -> NSAttributedString {
        let rendered = ChatMarkdown.render(text, names: names)
        let result = NSMutableAttributedString(
            string: rendered.text,
            attributes: [
                .font: Tokens.Bubble.textFont,
                .foregroundColor: isOwn ? NSColor.white : .labelColor,
            ]
        )
        for span in rendered.spans {
            var attributes: [NSAttributedString.Key: Any] = [:]
            var traits: NSFontTraitMask = []
            if span.isBold { traits.insert(.boldFontMask) }
            if span.isItalic { traits.insert(.italicFontMask) }
            if span.isStrikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if span.isCode {
                attributes[.font] = codeFont(bold: span.isBold)
                if span.isItalic { attributes[.obliqueness] = 0.2 }
                attributes[.hqCodeFill] = codeFill(isOwn: isOwn)
                if span.isCodeBlock {
                    attributes[.hqCodeBlock] = true
                    // Set in from both sides, so the panel drawn around it
                    // stays inside the text view, which clips at its edge.
                    let inset = NSMutableParagraphStyle()
                    inset.firstLineHeadIndent = ChatMarkdown.CodeStyle.blockPadding
                    inset.headIndent = ChatMarkdown.CodeStyle.blockPadding
                    inset.tailIndent = -ChatMarkdown.CodeStyle.blockPadding
                    attributes[.paragraphStyle] = inset
                }
                traits = []
            }
            // A tag: the accent on an incoming bubble, and on an own bubble —
            // already blue — the white it shares with the rest, set apart by
            // weight alone.
            if span.isMention {
                traits.insert(.boldFontMask)
                attributes[.foregroundColor] =
                    isOwn ? NSColor.white : NSColor(Tokens.Palette.accent)
            }
            if !traits.isEmpty {
                attributes[.font] = NSFontManager.shared.convert(
                    Tokens.Bubble.textFont, toHaveTrait: traits
                )
            }
            if let link = span.link {
                attributes[.link] = link
                attributes[.foregroundColor] = isOwn ? NSColor.white : .systemBlue
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.addAttributes(attributes, range: span.range)
        }
        return result
    }
}

// The text view that gives its menu back — a right- or control-click travels
// up the responder chain to the SwiftUI row, and a plain click, which has no
// press left to send by the time it is answered, reaches for the same menu
// itself; so the message menu opens over selectable text exactly as it does
// over the gutter beside it — and that hands its selection to the transcript
// instead of keeping its own.
class BubbleTextView: NSTextView {
    var messageId = ""
    // What the storage currently shows — the update pass compares against
    // these instead of re-rendering the Markdown to find out nothing moved.
    var renderedText = ""
    var renderedIsOwn = false
    var renderedNames: [String] = []
    weak var selection: TranscriptSelection?
    var selectionColor: NSColor = .selectedTextBackgroundColor
    var clickOpensMenu = true
    private var didDrag = false
    /// Set when the press itself opened the menu, so the release that follows
    /// is not read as a second click on the bubble.
    private var didOpenMenu = false

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    /// The row's menu, found by walking up from this view: SwiftUI hangs the
    /// `.contextMenu` off an ancestor, and this view deliberately has none of
    /// its own.
    func rowMenu(for event: NSEvent) -> NSMenu? {
        var view = superview
        while let candidate = view {
            if let menu = candidate.menu(for: event) { return menu }
            view = candidate.superview
        }
        return nil
    }

    /// A plain click opens that menu here rather than by handing itself up as
    /// a right-click, the way the other two buttons do: a click cannot be
    /// answered until the mouse comes back UP — a press that drags is a
    /// selection, not a tapback — and by then there is no press left for the
    /// chain to carry. Should the walk ever come up empty, the forward is
    /// still a better answer than none.
    private func presentRowMenu(with event: NSEvent) {
        guard let menu = rowMenu(for: event) else {
            nextResponder?.rightMouseDown(with: event)
            return
        }
        runMenu(menu, at: convert(event.locationInWindow, from: nil))
    }

    /// The one place the modal menu loop is entered, so a test can drive the
    /// gesture from outside it.
    func runMenu(_ menu: NSMenu, at point: NSPoint) {
        menu.popUp(positioning: nil, at: point, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        didOpenMenu = false
        // A control-click IS a right-click and travels like one: up the chain
        // to the row, which is where the menu hangs.
        guard !event.modifierFlags.contains(.control) else {
            didOpenMenu = true
            nextResponder?.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        didDrag = false
        let local = convert(event.locationInWindow, from: nil)
        selection?.begin(
            at: .init(messageId: messageId, index: characterIndexForInsertion(at: local))
        )
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        // Dragging past the top or bottom of the transcript keeps going.
        autoscroll(with: event)
        guard let caret = selection?.caret(at: event.locationInWindow) else { return }
        selection?.extend(to: caret)
    }

    override func mouseUp(with event: NSEvent) {
        // A drag was a selection, and a double-click's second press belongs to
        // the menu the first one opened — over the tapback strip, at that.
        guard !didDrag, !didOpenMenu, event.clickCount <= 1 else { return }
        // A click, not a drag: it drops the selection, and on a link it opens
        // the link — NSTextView's own handling went out with its mouseDown.
        selection?.clear()
        let local = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: local)
        if let storage = textStorage, index < storage.length,
           let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
            NSWorkspace.shared.open(url)
            return
        }
        // Anywhere else on the bubble, a plain click is the tapback gesture:
        // the row's menu opens under the cursor with the strips at its top.
        guard clickOpensMenu else { return }
        presentRowMenu(with: event)
    }

    // Focus moving to the composer (or anywhere else) ends the selection, the
    // way a click outside it would.
    override func resignFirstResponder() -> Bool {
        selection?.clear()
        return super.resignFirstResponder()
    }

    // The highlight is painted here rather than through `selectedRange`: only
    // one view can be first responder, and NSTextView dims the selection in
    // the others — a run across three bubbles would come out three shades.
    override func draw(_ dirtyRect: NSRect) {
        drawTranscriptSelection()
        super.draw(dirtyRect)
    }

    private func drawTranscriptSelection() {
        guard let range = selection?.range(in: messageId), range.length > 0,
              let layoutManager, let textContainer
        else { return }
        selectionColor.setFill()
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer
        ) { rect, _ in
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    // ⌘C routes through Edit ▸ Copy, and NSTextView validates that item
    // against its OWN selectedRange — which stays empty on purpose: the
    // highlight lives in TranscriptSelection. Answer for the transcript's
    // selection instead, or the menu item disables and ⌘C dies silently.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.copy(_:)) {
            return selection?.isEmpty == false
        }
        return super.validateUserInterfaceItem(item)
    }

    // AppKit normally routes ⌘C through Edit ▸ Copy, but this read-only
    // text view owns a transcript-level selection rather than an NSTextView
    // selectedRange. Handle the physical shortcut at the responder too, and
    // accept Ctrl-C as requested by teammates who use that spelling/habit.
    // Nothing else is intercepted, and either shortcut only wins while a
    // transcript selection actually exists.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if copySelectionIfRequested(by: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if copySelectionIfRequested(by: event) { return }
        super.keyDown(with: event)
    }

    private func copySelectionIfRequested(by event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.charactersIgnoringModifiers?.lowercased() == "c",
              modifiers.contains(.command) || modifiers.contains(.control),
              modifiers.intersection([.shift, .option]).isEmpty,
              selection?.isEmpty == false
        else { return false }
        copy(nil)
        return true
    }

    override func copy(_ sender: Any?) {
        guard let text = selection?.selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension NSAttributedString.Key {
    /// On a code run: the `NSColor` wash `CodeBackgroundLayoutManager` draws
    /// behind it. It is its own key, never `.backgroundColor`, which AppKit
    /// fills square-cornered.
    static let hqCodeFill = NSAttributedString.Key("hq.code.fill")
    /// On a fenced block's run: one panel around all its lines, not a pill
    /// per line.
    static let hqCodeBlock = NSAttributedString.Key("hq.code.block")
}

/// Draws the rounded wash behind code, under the glyphs. Each line a code run
/// sits on gets the glyph bounds of just that run — a wrapped span is two
/// pills, not one rectangle bleeding to the margin — and a fenced block's
/// lines are joined into one panel. Painting adds no layout: bubble sizes are
/// the text's own.
final class CodeBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0,
              let container = textContainers.first
        else { return }
        // The whole string, not the dirty range: a partial redraw would cut a
        // block in two and round its corners mid-way. Bubbles are short.
        // Everything drawn stays inside the container, which the view clips to.
        let bounds = NSRect(
            x: 0, y: 0, width: container.size.width, height: usedRect(for: container).maxY
        )
        storage.enumerateAttribute(.hqCodeFill, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard let fill = value as? NSColor else { return }
            let isBlock = storage.attribute(.hqCodeBlock, at: run.location, effectiveRange: nil) != nil
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            var rects: [NSRect] = []
            enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { return }
                let line = self.boundingRect(forGlyphRange: part, in: container)
                rects.append(NSRect(x: line.minX, y: used.minY, width: line.width, height: used.height))
            }
            guard !rects.isEmpty else { return }
            fill.setFill()
            let drawn: [(NSRect, CGFloat)]
            if isBlock {
                let panel = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                let padding = ChatMarkdown.CodeStyle.blockPadding
                drawn = [(panel.insetBy(dx: -padding, dy: 0), ChatMarkdown.CodeStyle.blockRadius)]
            } else {
                drawn = rects.map { ($0.insetBy(dx: -2, dy: 1), ChatMarkdown.CodeStyle.inlineRadius) }
            }
            for (rect, radius) in drawn {
                let placed = rect.intersection(bounds).offsetBy(dx: origin.x, dy: origin.y)
                guard !placed.isEmpty else { continue }
                NSBezierPath(roundedRect: placed, xRadius: radius, yRadius: radius).fill()
            }
        }
    }
}
