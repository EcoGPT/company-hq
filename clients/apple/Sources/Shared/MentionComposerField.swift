import SwiftUI

#if os(macOS)
import AppKit
typealias ComposerFont = NSFont
typealias ComposerColor = NSColor
#else
import UIKit
typealias ComposerFont = UIFont
typealias ComposerColor = UIColor
#endif

extension NSAttributedString.Key {
    /// Marks a run of display text as a resolved tag. The value is a
    /// `MentionTag`, whose reference identity keeps two adjacent tags from
    /// being coalesced into one run by `enumerateAttribute`.
    static let hqMention = NSAttributedString.Key("hqMention")
}

/// A resolved tag, carrying the roster spelling that the `@` was traded for.
final class MentionTag: NSObject {
    let name: String
    init(name: String) { self.name = name }
}

/// The rules a composer's text storage obeys, with no view attached: what a
/// tag looks like, when a half-typed token becomes one, and what a delete
/// takes with it. Both platforms' coordinators drive this; only the delegate
/// plumbing around it differs.
///
/// The storage holds *display* text — tags without their `@` — while the
/// binding outside holds wire text. `MentionText` is the hinge between them.
final class MentionFieldEngine {
    var names: [String] = []

    private let baseFont: ComposerFont
    private let baseColor: ComposerColor
    private let accent: ComposerColor
    private let mentionFont: ComposerFont

    init(baseFont: ComposerFont, baseColor: ComposerColor, accent: ComposerColor) {
        self.baseFont = baseFont
        self.baseColor = baseColor
        self.accent = accent
        // Messages sets a tag apart by weight as much as by colour, which is
        // what keeps it legible for anyone who cannot see the blue.
        self.mentionFont = ComposerFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: baseColor]
    }

    private func mentionAttributes(_ tag: MentionTag) -> [NSAttributedString.Key: Any] {
        [.font: mentionFont, .foregroundColor: accent, .hqMention: tag]
    }

    // MARK: - Crossing between wire and display

    /// Wire text as the storage should hold it.
    func attributed(forWire wire: String) -> NSAttributedString {
        let display = MentionText.display(from: wire, names: names)
        let result = NSMutableAttributedString(string: display.text, attributes: baseAttributes)
        let source = display.text as NSString
        for run in display.runs where NSMaxRange(run) <= source.length {
            result.addAttributes(
                mentionAttributes(MentionTag(name: source.substring(with: run))), range: run
            )
        }
        return result
    }

    /// What the storage currently means on the wire.
    func wire(from storage: NSAttributedString) -> String {
        var runs: [NSRange] = []
        storage.enumerateAttribute(
            .hqMention, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value is MentionTag { runs.append(range) }
        }
        return MentionText.wire(fromDisplay: storage.string, runs: runs)
    }

    // MARK: - Styling

    /// Repaints the storage: base everywhere, tags in accent, and the token
    /// under the caret tinted while it is still being typed. Colour is
    /// derived on every change rather than carried along by typing, so no
    /// edit can leave a stray blue character behind.
    ///
    /// Only runs whose attributes differ from that end state are rewritten.
    /// This runs twice per keystroke, and an attribute edit over the whole
    /// draft relays out the whole draft: typing slowed with its length.
    func restyle(_ storage: NSTextStorage, caret: Int) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        // The tags are read off BEFORE the repaint: `setAttributes` replaces
        // every attribute in the range, `.hqMention` included, so enumerating
        // afterwards would be enumerating what was just erased — and the wire
        // text built from it would have lost every `@`.
        var tags: [(NSRange, MentionTag)] = []
        storage.enumerateAttribute(.hqMention, in: full) { value, range, _ in
            if let tag = value as? MentionTag { tags.append((range, tag)) }
        }
        let token = liveTokenRange(in: storage.string, caret: caret)
        // The end state in segments: wherever a tag or the token starts or
        // ends, the attributes may change.
        var cuts: Set<Int> = [0, full.length]
        for (range, _) in tags {
            cuts.insert(range.location)
            cuts.insert(NSMaxRange(range))
        }
        if let token {
            cuts.insert(token.location)
            cuts.insert(NSMaxRange(token))
        }
        let bounds = cuts.filter { $0 >= 0 && $0 <= full.length }.sorted()
        var writes: [(NSRange, [NSAttributedString.Key: Any])] = []
        var tagIndex = 0
        for (start, end) in zip(bounds, bounds.dropFirst()) where end > start {
            while tagIndex < tags.count, NSMaxRange(tags[tagIndex].0) <= start { tagIndex += 1 }
            var desired = tagIndex < tags.count && tags[tagIndex].0.location <= start
                ? mentionAttributes(tags[tagIndex].1) : baseAttributes
            if let token, NSLocationInRange(start, token) { desired[.foregroundColor] = accent }
            let wanted = desired as NSDictionary
            storage.enumerateAttributes(
                in: NSRange(location: start, length: end - start)
            ) { attributes, run, _ in
                if !wanted.isEqual(to: attributes) { writes.append((run, desired)) }
            }
        }
        guard !writes.isEmpty else { return }
        storage.beginEditing()
        for (range, attributes) in writes {
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
    }

    /// The `@token` the caret sits in, when somebody on the roster answers to
    /// it. Nil once it is committed — a committed tag has no `@` left.
    func liveTokenRange(in text: String, caret: Int) -> NSRange? {
        let source = text as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        let prefix = source.substring(to: caret)
        guard let found = MentionText.trailingToken(before: prefix),
              MentionText.isLiveToken(found.token, names: names)
        else { return nil }
        return NSRange(found.at..<prefix.endIndex, in: prefix)
    }

    // MARK: - The commit animation

    /// The layer that plays a tag's arrival. Messages does not just repaint
    /// the name — it pops it, which is what makes a space feel like it *did*
    /// something. The real glyphs go clear underneath for the length of it so
    /// there is no static ghost behind the one that moves.
    func popLayer(for name: String, scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = name
        layer.font = CTFontCreateWithName(
            mentionFont.fontName as CFString, mentionFont.pointSize, nil
        )
        layer.fontSize = mentionFont.pointSize
        layer.foregroundColor = accent.cgColor
        layer.contentsScale = scale
        layer.alignmentMode = .left
        layer.isWrapped = false
        return layer
    }

    /// Grow, overshoot, settle — with the colour arriving over the first
    /// third of it, so the name is seen turning blue rather than being blue.
    func popAnimations() -> [CAPropertyAnimation] {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.22, 0.97, 1.0]
        pop.keyTimes = [0, 0.4, 0.72, 1]
        pop.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        pop.duration = Self.popDuration

        let turningBlue = CABasicAnimation(keyPath: "foregroundColor")
        turningBlue.fromValue = baseColor.cgColor
        turningBlue.toValue = accent.cgColor
        turningBlue.duration = Self.popDuration * 0.42
        turningBlue.timingFunction = CAMediaTimingFunction(name: .easeOut)

        return [pop, turningBlue]
    }

    static let popDuration: CFTimeInterval = 0.34

    /// What the glyphs under the animation wear while it runs.
    func hide(_ range: NSRange, in storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.foregroundColor, value: ComposerColor.clear, range: range)
    }

    // MARK: - Edits

    /// The replacement a space or tab makes when it ends a token that names
    /// somebody: the `@token` becomes the tag, and the separator follows it.
    /// This is the only thing that resolves a tag besides picking one — no
    /// timer, and never mid-word.
    func commit(in storage: NSTextStorage, caret: Int, typed: String) -> (NSRange, NSAttributedString)? {
        guard typed == " " || typed == "\t" else { return nil }
        let source = storage.string as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        let prefix = source.substring(to: caret)
        guard let found = MentionText.trailingToken(before: prefix),
              let name = MentionText.commitName(for: found.token, names: names)
        else { return nil }

        let replacement = NSMutableAttributedString(
            string: name, attributes: mentionAttributes(MentionTag(name: name))
        )
        replacement.append(NSAttributedString(string: " ", attributes: baseAttributes))
        return (NSRange(found.at..<prefix.endIndex, in: prefix), replacement)
    }

    /// A delete that touches a tag takes the whole tag. Backspacing at the
    /// end of "Turner" removes the name entire, the way Messages does, rather
    /// than shaving it down to a half-name that no longer tags anyone.
    func deletionRange(in storage: NSTextStorage, range: NSRange) -> NSRange {
        var result = range
        storage.enumerateAttribute(
            .hqMention, in: NSRange(location: 0, length: storage.length)
        ) { value, run, _ in
            guard value is MentionTag else { return }
            // A caret delete arrives as the character about to go, so a run
            // that merely abuts the range is left alone; one it bites into
            // comes along whole.
            guard NSIntersectionRange(run, result).length > 0 else { return }
            result = NSUnionRange(result, run)
        }
        return result
    }

    /// Typing into the middle of a tag dissolves it back into plain text —
    /// what is left is no longer the name anybody is known by.
    func breakMentions(in storage: NSTextStorage, editing range: NSRange) {
        var doomed: [NSRange] = []
        storage.enumerateAttribute(
            .hqMention, in: NSRange(location: 0, length: storage.length)
        ) { value, run, _ in
            guard value is MentionTag else { return }
            let touchesInside = range.location > run.location && range.location < NSMaxRange(run)
            let overlaps = range.length > 0 && NSIntersectionRange(run, range).length > 0
            if touchesInside || overlaps { doomed.append(run) }
        }
        guard !doomed.isEmpty else { return }
        storage.beginEditing()
        for run in doomed { storage.removeAttribute(.hqMention, range: run) }
        storage.endEditing()
    }
}

/// The composer's text field: a native text view that draws tags the way
/// Messages does — the `@` gone once the tag resolves, the name in accent —
/// while the binding it feeds keeps holding ordinary `@Name` wire text.
struct MentionComposerField {
    @Binding var text: String
    /// Everyone tag-able here, roster spelling.
    var names: [String]
    var placeholder: String
    /// Bumped to pull first responder to this field.
    var focusRequest: Int
    var maxLines: Int
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void
    /// iOS only. A pasted image or file is an attachment, not text — the same
    /// call the Mac's ⌘V makes — so the editor asks first and only falls back
    /// to a text paste when the answer is no. `canClaimPaste` decides whether
    /// the Paste item is offered at all (a UITextView holding plain text will
    /// not offer one for an image-only pasteboard on its own); it is called
    /// while a menu is being built, so it may only look at pasteboard TYPES —
    /// reading the contents there would raise the system's paste banner
    /// without the user having asked for anything. `claimPaste` runs on the
    /// user's actual Paste and returns whether it took the pasteboard.
    var canClaimPaste: (() -> Bool)?
    var claimPaste: (() -> Bool)?

    init(
        text: Binding<String>,
        names: [String],
        placeholder: String,
        focusRequest: Int,
        maxLines: Int = 10,
        onSubmit: @escaping () -> Void = {},
        onFocusChange: @escaping (Bool) -> Void = { _ in },
        canClaimPaste: (() -> Bool)? = nil,
        claimPaste: (() -> Bool)? = nil
    ) {
        self._text = text
        self.names = names
        self.placeholder = placeholder
        self.focusRequest = focusRequest
        self.maxLines = maxLines
        self.onSubmit = onSubmit
        self.onFocusChange = onFocusChange
        self.canClaimPaste = canClaimPaste
        self.claimPaste = claimPaste
    }
}

#if os(macOS)

final class MentionComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let view = documentView as? NSTextView else { return }
        let width = contentView.bounds.width
        guard width > 0, abs(view.frame.width - width) > 0.5 else { return }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }
}

fileprivate final class MentionComposerMeasurer {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(
        size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )

    init() {
        storage.addLayoutManager(layout)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
    }

    func height(
        for string: NSAttributedString, width: CGFloat, font: NSFont, maxLines: Int
    ) -> CGFloat {
        container.containerSize = CGSize(
            width: width, height: CGFloat.greatestFiniteMagnitude
        )
        storage.setAttributedString(string)
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        let line = ceil(layout.defaultLineHeight(for: font))
        return min(max(used, line), line * CGFloat(maxLines))
    }
}

extension MentionComposerField: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, explicitly: the height of a growing composer is read off
        // `usedRect`, and reaching for `layoutManager` on a TextKit 2 view to
        // get it triggers a silent fallback anyway. Ask for it up front.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let view = ComposerTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        let coordinator = context.coordinator
        view.onFocusChange = { [weak coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainerInset = .zero
        view.font = Self.font
        view.textColor = .labelColor
        view.typingAttributes = context.coordinator.engine.baseAttributes
        view.setAccessibilityLabel(placeholder)

        let scroll = MentionComposerScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none

        context.coordinator.engine.names = names
        context.coordinator.render(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        let rosterChanged = coordinator.engine.names != names
        coordinator.engine.names = names

        // Only a change from OUTSIDE redraws the storage. The field's own
        // keystrokes come back through the binding as the wire text it just
        // emitted, and re-rendering those would resolve a tag the moment its
        // last letter was typed — the one thing that must wait for a space.
        if text != coordinator.lastEmitted {
            coordinator.render(view)
        } else if rosterChanged {
            // A roster arriving late should light up a restored draft, but
            // not by yanking the caret out from under someone mid-sentence.
            if view.window?.firstResponder === view {
                coordinator.restyle(view)
            } else {
                coordinator.render(view)
            }
        }

        view.setAccessibilityLabel(placeholder)
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            if let window = view.window {
                window.makeFirstResponder(view)
            } else {
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context
    ) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView,
              let width = proposal.width, width.isFinite, width > 0
        else { return nil }

        let height = context.coordinator.measurer.height(
            for: view.attributedString(), width: width,
            font: view.font ?? Self.font, maxLines: maxLines
        )
        return CGSize(width: width, height: height)
    }

    static let font = NSFont.systemFont(ofSize: 13)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionComposerField
        let engine: MentionFieldEngine
        fileprivate let measurer = MentionComposerMeasurer()
        /// The wire text this field last pushed outward — the mark that tells
        /// its own echo apart from somebody else's edit.
        var lastEmitted: String
        var lastFocusRequest: Int
        /// Set while the coordinator is performing an edit of its own, so the
        /// re-entrant delegate call does not try to rewrite it again.
        private var isApplying = false
        /// The tag currently playing its arrival, if one is.
        private var pop: NSView?

        init(_ parent: MentionComposerField) {
            self.parent = parent
            self.lastEmitted = parent.text
            self.lastFocusRequest = parent.focusRequest
            self.engine = MentionFieldEngine(
                baseFont: MentionComposerField.font,
                baseColor: .labelColor,
                accent: NSColor(Tokens.Palette.accent)
            )
        }

        func render(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            endPop()
            storage.setAttributedString(engine.attributed(forWire: parent.text))
            view.setSelectedRange(NSRange(location: storage.length, length: 0))
            lastEmitted = parent.text
            restyle(view)
        }

        func restyle(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            // An IME's marked clause carries attributes of its own — the
            // underline that says this text is not committed yet. Repainting
            // the storage erases them, so while a composition is open the
            // tint waits; committing it runs this again.
            guard !view.hasMarkedText() else { return }
            engine.restyle(storage, caret: view.selectedRange().location)
            view.typingAttributes = engine.baseAttributes
        }

        private func emit(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            // Any further edit ends an arrival early — the glyphs it hid have
            // to come back before the repaint, not after.
            endPop()
            restyle(view)
            let wire = engine.wire(from: storage)
            lastEmitted = wire
            if parent.text != wire { parent.text = wire }
        }

        private func apply(_ replacement: NSAttributedString, over range: NSRange, in view: NSTextView) {
            guard let storage = view.textStorage else { return }
            isApplying = true
            defer { isApplying = false }
            guard view.shouldChangeText(in: range, replacementString: replacement.string) else {
                return
            }
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: replacement)
            storage.endEditing()
            view.setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
            view.didChangeText()
            emit(view)
            if replacement.length > 0,
               let tag = replacement.attribute(.hqMention, at: 0, effectiveRange: nil) as? MentionTag {
                playPop(
                    over: NSRange(location: range.location, length: (tag.name as NSString).length),
                    name: tag.name, in: view
                )
            }
        }

        private func endPop() {
            pop?.removeFromSuperview()
            pop = nil
        }

        /// The name arriving: the real glyphs step aside for a layer that
        /// grows, overshoots and settles while it turns blue. The host view
        /// is sized to the glyphs it stands in for and the layer fills it, so
        /// nothing here depends on which way the text view's layer is flipped.
        private func playPop(over range: NSRange, name: String, in view: NSTextView) {
            endPop()
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  let storage = view.textStorage,
                  let layout = view.layoutManager,
                  let container = view.textContainer
            else { return }

            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var frame = layout.boundingRect(forGlyphRange: glyphs, in: container)
            frame.origin.x += view.textContainerInset.width
            frame.origin.y += view.textContainerInset.height
            guard frame.width > 1, frame.height > 1 else { return }

            let host = NSView(frame: frame)
            host.wantsLayer = true
            let layer = engine.popLayer(
                for: name, scale: view.window?.backingScaleFactor ?? 2
            )
            layer.frame = host.bounds
            host.layer?.addSublayer(layer)
            view.addSubview(host)
            engine.hide(range, in: storage)
            pop = host

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak view] in
                guard let self, self.pop === host else { return }
                self.endPop()
                if let view { self.restyle(view) }
            }
            for animation in engine.popAnimations() {
                layer.add(animation, forKey: animation.keyPath)
            }
            CATransaction.commit()
        }

        // swiftlint:disable:next boolean_function_naming
        func textView(
            _ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            guard !isApplying, let storage = view.textStorage else { return true }
            let replacement = replacementString ?? ""

            if range.length == 0,
               let (commitRange, tagged) = engine.commit(
                   in: storage, caret: range.location, typed: replacement
               ) {
                apply(tagged, over: commitRange, in: view)
                return false
            }
            if replacement.isEmpty, range.length > 0 {
                let expanded = engine.deletionRange(in: storage, range: range)
                if expanded != range {
                    apply(NSAttributedString(string: ""), over: expanded, in: view)
                    return false
                }
            }
            engine.breakMentions(in: storage, editing: range)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let view = notification.object as? NSTextView else { return }
            emit(view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // The tint follows the caret: leaving a half-typed token stops
            // advertising it as one.
            guard !isApplying, let view = notification.object as? NSTextView else { return }
            restyle(view)
        }

        // swiftlint:disable:next boolean_function_naming
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // AppKit sends ⇧↩ as the same selector as ↩, so the event's
                // modifiers are the only way to tell a line break from a send.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    view.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)),
               let storage = view.textStorage,
               let (range, tagged) = engine.commit(
                   in: storage, caret: view.selectedRange().location, typed: "\t"
               ) {
                apply(tagged, over: range, in: view)
                return true
            }
            return false
        }
    }
}

/// The composer reports FOCUS, not editing. `textDidBeginEditing` is AppKit
/// saying the user has begun *changing* the text — a keystroke too late for
/// the key monitor above the field, which has to know on the click whether
/// ⌘V belongs to the composer. Answering that from the edit notification
/// made a freshly clicked field read as "nothing is focused", and an image
/// paste went to the text view, which drops one silently.
final class ComposerTextView: NSTextView {
    var onFocusChange: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { report(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { report(false) }
        return resigned
    }

    // A bumped focusRequest moves first responder from inside SwiftUI's own
    // update pass, so the answer waits a turn rather than mutating state
    // mid-update.
    private func report(_ focused: Bool) {
        let notify = onFocusChange
        DispatchQueue.main.async { notify(focused) }
    }
}

#else

/// On the phone the editor must own long-press selection and Paste itself. A
/// gesture on a SwiftUI wrapper can focus a field, but it also sits between
/// the edit-menu interaction and the first responder — the failure mode where
/// typing works and Paste never appears. UITextView supplies the native menu,
/// hardware ⌘V, dictation, Scribble, autocorrect and caret-aware insertion
/// without HQ reading the clipboard at all.
/// The editor itself, so that a paste of an image or a file can become an
/// attachment before UIKit turns it into text (or drops it silently). Nothing
/// else about the field changes: selection, the edit menu, dictation and
/// Scribble stay the system's.
final class PasteAwareTextView: UITextView {
    /// May look at pasteboard TYPES only — see `MentionComposerField`.
    var canClaimPaste: (() -> Bool)?
    /// Returns true when it took the pasteboard; false falls back to text.
    var claimPaste: (() -> Bool)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), canClaimPaste?() == true { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if claimPaste?() == true { return }
        super.paste(sender)
    }
}

extension MentionComposerField: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = PasteAwareTextView()
        view.delegate = context.coordinator
        // Through the coordinator, never the closures captured here: this
        // struct is rebuilt on every update and the copy made now would go on
        // staging into whatever conversation was open when the field mounted.
        let coordinator = context.coordinator
        view.canClaimPaste = { [weak coordinator] in coordinator?.parent.canClaimPaste?() ?? false }
        view.claimPaste = { [weak coordinator] in coordinator?.parent.claimPaste?() ?? false }
        view.backgroundColor = .clear
        view.font = Self.font
        view.textColor = .label
        view.tintColor = .systemBlue
        // The SwiftUI wrapper owns vertical padding so scrolled lines cannot draw into it.
        view.textContainerInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 4)
        view.textContainer.lineFragmentPadding = 0
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .default
        view.spellCheckingType = .default
        view.typingAttributes = context.coordinator.engine.baseAttributes
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = placeholder
        context.coordinator.engine.names = names
        context.coordinator.render(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let hasFontChanged = view.font?.pointSize != Self.font.pointSize
        if hasFontChanged {
            coordinator.engine = MentionFieldEngine(
                baseFont: Self.font, baseColor: .label, accent: UIColor(Tokens.Palette.accent)
            )
            view.font = Self.font
        }
        let rosterChanged = hasFontChanged || coordinator.engine.names != names
        coordinator.engine.names = names

        // See the Mac's note: the field's own echo must not re-render, or a
        // tag would resolve on its last letter instead of on the space.
        if text != coordinator.lastEmitted {
            coordinator.render(view)
            view.invalidateIntrinsicContentSize()
        } else if rosterChanged {
            if view.isFirstResponder {
                coordinator.restyle(view)
            } else {
                coordinator.render(view)
            }
        }

        view.accessibilityLabel = placeholder
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            view.becomeFirstResponder()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView view: UITextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let fitting = view.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let lineHeight = view.font?.lineHeight ?? 20
        let verticalInset = view.textContainerInset.top + view.textContainerInset.bottom
        let minimum = ceil(lineHeight + verticalInset)
        let maximum = ceil(lineHeight * CGFloat(maxLines) + verticalInset)
        view.isScrollEnabled = fitting.height > maximum
        return CGSize(width: width, height: min(max(fitting.height, minimum), maximum))
    }

    static var font: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionComposerField
        var engine: MentionFieldEngine
        var lastEmitted: String
        var lastFocusRequest: Int
        private var isApplying = false
        /// The tag currently playing its arrival, if one is.
        private var pop: UIView?

        init(_ parent: MentionComposerField) {
            self.parent = parent
            self.lastEmitted = parent.text
            self.lastFocusRequest = parent.focusRequest
            self.engine = MentionFieldEngine(
                baseFont: MentionComposerField.font,
                baseColor: .label,
                accent: UIColor(Tokens.Palette.accent)
            )
        }

        func render(_ view: UITextView) {
            endPop()
            let storage = view.textStorage
            storage.setAttributedString(engine.attributed(forWire: parent.text))
            view.selectedRange = NSRange(location: storage.length, length: 0)
            lastEmitted = parent.text
            restyle(view)
        }

        func restyle(_ view: UITextView) {
            // See the Mac's note: a repaint mid-composition erases the marked
            // clause's own attributes.
            guard view.markedTextRange == nil else { return }
            engine.restyle(view.textStorage, caret: view.selectedRange.location)
            view.typingAttributes = engine.baseAttributes
        }

        private func emit(_ view: UITextView) {
            // Any further edit ends an arrival early — the glyphs it hid have
            // to come back before the repaint, not after.
            endPop()
            restyle(view)
            let wire = engine.wire(from: view.textStorage)
            lastEmitted = wire
            if parent.text != wire { parent.text = wire }
            view.invalidateIntrinsicContentSize()
        }

        private func apply(_ replacement: NSAttributedString, over range: NSRange, in view: UITextView) {
            isApplying = true
            defer { isApplying = false }
            let storage = view.textStorage
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: replacement)
            storage.endEditing()
            view.selectedRange = NSRange(location: range.location + replacement.length, length: 0)
            emit(view)
            if replacement.length > 0,
               let tag = replacement.attribute(.hqMention, at: 0, effectiveRange: nil) as? MentionTag {
                playPop(
                    over: NSRange(location: range.location, length: (tag.name as NSString).length),
                    name: tag.name, in: view
                )
            }
        }

        private func endPop() {
            pop?.removeFromSuperview()
            pop = nil
        }

        /// See the Mac's note: the glyphs step aside for a layer that grows,
        /// overshoots and settles as it turns blue. The rect comes from
        /// `UITextInput` rather than a layout manager, so this stays out of
        /// the way of whichever TextKit the text view chose for itself.
        private func playPop(over range: NSRange, name: String, in view: UITextView) {
            endPop()
            guard !UIAccessibility.isReduceMotionEnabled,
                  let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let span = view.textRange(from: start, to: end)
            else { return }

            let frame = view.firstRect(for: span)
            guard frame.width > 1, frame.height > 1, frame.origin.x.isFinite else { return }

            let host = UIView(frame: frame)
            host.isUserInteractionEnabled = false
            let layer = engine.popLayer(for: name, scale: view.traitCollection.displayScale)
            layer.frame = host.bounds
            host.layer.addSublayer(layer)
            view.addSubview(host)
            engine.hide(range, in: view.textStorage)
            pop = host

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak view] in
                guard let self, self.pop === host else { return }
                self.endPop()
                if let view { self.restyle(view) }
            }
            for animation in engine.popAnimations() {
                layer.add(animation, forKey: animation.keyPath)
            }
            CATransaction.commit()
        }

        // swiftlint:disable:next boolean_function_naming
        func textView(
            _ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
        ) -> Bool {
            guard !isApplying else { return true }
            let storage = view.textStorage

            if range.length == 0,
               let (commitRange, tagged) = engine.commit(
                   in: storage, caret: range.location, typed: text
               ) {
                apply(tagged, over: commitRange, in: view)
                return false
            }
            if text.isEmpty, range.length > 0 {
                let expanded = engine.deletionRange(in: storage, range: range)
                if expanded != range {
                    apply(NSAttributedString(string: ""), over: expanded, in: view)
                    return false
                }
            }
            engine.breakMentions(in: storage, editing: range)
            return true
        }

        func textViewDidChange(_ view: UITextView) {
            guard !isApplying else { return }
            emit(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isApplying else { return }
            restyle(view)
        }

        func textViewDidBeginEditing(_ view: UITextView) { parent.onFocusChange(true) }
        func textViewDidEndEditing(_ view: UITextView) { parent.onFocusChange(false) }
    }
}

#endif
