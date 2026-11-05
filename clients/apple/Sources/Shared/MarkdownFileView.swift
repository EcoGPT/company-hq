import SwiftUI
import os

// The Markdown renderer both clients use for a `.md` attachment.
// `AttributedString(markdown:)` understands just the inline runs, so the
// blocks — headings, lists, code, quotes — are reassembled from the parser's
// presentation intents and laid out by hand.

struct MarkdownFileView: View {
    let text: String

    private typealias Block = MarkdownBlocks.Block

    /// Parsed once per text, whatever number of times SwiftUI evaluates the
    /// body (the memo answers every later pass), and in the same frame the
    /// view first appears in: a long document is complete on its first frame.
    private var blocks: [Block] { MarkdownBlocks.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(Self.headingFont(level))
                .padding(.top, level == 1 ? 2 : 8)
                .textSelection(.enabled)
        case .paragraph:
            Text(block.text)
                .font(Self.bodyFont)
                .lineSpacing(3)
                .textSelection(.enabled)
        case .listItem(let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(Self.markerFont)
                    .foregroundStyle(.secondary)
                Text(block.text)
                    .font(Self.bodyFont)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .code:
            Text(block.text)
                .font(Self.codeFont)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .textSelection(.enabled)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(width: 3)
                Text(block.text)
                    .font(Self.bodyFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .divider:
            Divider()
        }
    }

    // The Mac keeps its fixed sizes; the phone reads text styles, so the
    // document follows the Dynamic Type setting.
    #if os(macOS)
    private static let bodyFont = Font.system(size: 13)
    private static let markerFont = Font.system(size: 13, weight: .semibold)
    private static let codeFont = Font.system(size: 12, design: .monospaced)

    private static func headingFont(_ level: Int) -> Font {
        let size: CGFloat
        switch level {
        case 1: size = 22
        case 2: size = 17
        case 3: size = 15
        default: size = 13
        }
        return .system(size: size, weight: .bold)
    }
    #else
    private static let bodyFont = Font.body
    private static let markerFont = Font.body.weight(.semibold)
    private static let codeFont = Font.footnote.monospaced()

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Font.title2.bold()
        case 2: return Font.title3.bold()
        case 3: return Font.headline
        default: return Font.body.bold()
        }
    }
    #endif
}

/// Markdown to display blocks. Nothing here touches the main actor, so a long
/// document can parse on any thread, and a parsed document is remembered:
/// SwiftUI may evaluate a body any number of times for one input.
enum MarkdownBlocks {
    enum BlockKind: Hashable, Sendable {
        case heading(Int)
        case paragraph
        case listItem(marker: String, indent: Int)
        case code
        case quote
        case divider
    }

    struct Block: Identifiable, Sendable {
        let id: Int
        let kind: BlockKind
        let text: AttributedString
    }

    private final class Box: @unchecked Sendable {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    private static let memo: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 24
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Counts real parses, for tests.
    private static let counter = OSAllocatedUnfairLock(initialState: 0)
    static var parseCount: Int { counter.withLock { $0 } }

    static func cached(_ text: String) -> [Block]? {
        memo.object(forKey: text as NSString)?.blocks
    }

    static func parse(_ text: String) -> [Block] {
        if let hit = cached(text) { return hit }
        counter.withLock { $0 += 1 }
        let blocks = parseUncached(text)
        memo.setObject(Box(blocks), forKey: text as NSString, cost: text.utf8.count * 2)
        return blocks
    }

    static func parseUncached(_ text: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [Block(id: 0, kind: .paragraph, text: AttributedString(text))]
        }
        var blocks: [Block] = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let kind = blockKind(of: intent)
            let sliced = normalized(AttributedString(parsed[range]))
            if kind == .divider {
                blocks.append(Block(id: blocks.count, kind: .divider, text: AttributedString()))
            } else if !sliced.characters.isEmpty {
                blocks.append(Block(id: blocks.count, kind: kind, text: sliced))
            }
        }
        return blocks
    }

    private static func blockKind(of intent: PresentationIntent?) -> BlockKind {
        var kind: BlockKind = .paragraph
        var ordinal = 1
        // Innermost first: the first list component names the item's own
        // list, the count is the nesting depth.
        var listKinds: [Bool] = []
        for component in intent?.components ?? [] {
            switch component.kind {
            case .header(let level): kind = .heading(level)
            case .codeBlock: kind = .code
            case .blockQuote: kind = .quote
            case .thematicBreak: kind = .divider
            case .listItem(let n): ordinal = n
            case .orderedList: listKinds.append(true)
            case .unorderedList: listKinds.append(false)
            default: break
            }
        }
        if kind == .paragraph, let isOrdered = listKinds.first {
            kind = .listItem(
                marker: isOrdered ? "\(ordinal)." : "•",
                indent: listKinds.count - 1
            )
        }
        return kind
    }

    /// Hard line breaks arrive as inline intents; make them real newlines so
    /// a transcript's utterance lines stack instead of running together.
    private static func normalized(_ slice: AttributedString) -> AttributedString {
        var result = slice
        let breakRanges = result.runs
            .filter { $0.inlinePresentationIntent?.contains(.lineBreak) == true }
            .map(\.range)
        for range in breakRanges.reversed() {
            result.characters.replaceSubrange(range, with: "\n")
        }
        while result.characters.last?.isNewline == true {
            result.characters.removeLast()
        }
        return result
    }
}
