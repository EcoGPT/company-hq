import Foundation
import SwiftUI
import os

/// Markdown as it appears inside a chat bubble. The wire keeps the original
/// source; this value contains only display text and the small set of inline
/// attributes a bubble supports.
enum ChatMarkdown {
    private enum RichTimestampStyle: String {
        case dateTime = "date-time"
        case range
        case time
        case timeZone = "time-zone"
    }

    private static let validTimestampSeconds: ClosedRange<Int64> = 0...253_402_300_799

    struct Span: Equatable {
        var range: NSRange
        let isBold: Bool
        let isItalic: Bool
        let link: URL?
        /// A tag: `@Name` in the wire text, drawn as the name alone.
        var isMention = false
        /// `inline code`, or a fenced block (then `isCodeBlock` too).
        var isCode = false
        /// A fenced ``` block: its own paragraph, line breaks kept.
        var isCodeBlock = false
        var isStrikethrough = false
    }

    /// How code reads inside a bubble, one answer for both clients. The fill
    /// is a wash of white or black over whatever the bubble is: black on the
    /// blue own bubble in either appearance (a white wash left white code text
    /// at 3.9:1 in light and 2.9:1 in dark; black 22% gives 7.7:1 and 5.6:1),
    /// black on the light gray incoming one, white on the dark gray one.
    enum CodeStyle {
        static func fill(isOwn: Bool, isDark: Bool) -> (white: Double, opacity: Double) {
            if isOwn { return (0, 0.22) }
            return isDark ? (1, 0.10) : (0, 0.06)
        }

        static let inlineRadius: CGFloat = 4
        static let blockRadius: CGFloat = 8
        /// A block's wash reaches this far past its text on each side: the
        /// Mac sets the text in by it (a head and tail indent), so the wash
        /// never leaves the text view; the iPhone draws it into the bubble's
        /// own padding.
        static let blockPadding: CGFloat = 6

        /// The Mac's code size, one step under its 14pt bubble text. Both the
        /// SwiftUI font here and the AppKit one in `SelectableBubbleText` use it.
        static let macPointSize: CGFloat = 13

        /// Code is set one step under the bubble's text.
        static var font: Font {
            #if os(iOS)
            .system(.callout, design: .monospaced)
            #else
            .system(size: macPointSize, design: .monospaced)
            #endif
        }
    }

    struct Rendered: Equatable {
        let text: String
        let spans: [Span]

        var hasCode: Bool { spans.contains(where: \.isCode) }

        func attributed(linkColor: Color, mentionColor: Color) -> AttributedString {
            var result = AttributedString(text)
            for span in spans {
                guard let range = Range(span.range, in: result) else { continue }
                var intent: InlinePresentationIntent = []
                if span.isBold { intent.insert(.stronglyEmphasized) }
                if span.isItalic { intent.insert(.emphasized) }
                // A tag carries weight as well as colour, so it still reads
                // as one inside an own-bubble, where everything is white.
                if span.isMention {
                    intent.insert(.stronglyEmphasized)
                    result[range].foregroundColor = mentionColor
                }
                if span.isCode {
                    // Its own face, so the weight and slant ride on the font
                    // rather than on the intent.
                    var font = CodeStyle.font
                    if span.isBold { font = font.bold() }
                    if span.isItalic { font = font.italic() }
                    result[range].font = font
                } else if !intent.isEmpty {
                    result[range].inlinePresentationIntent = intent
                }
                if span.isStrikethrough { result[range].strikethroughStyle = .single }
                if let link = span.link {
                    result[range].link = link
                    result[range].underlineStyle = .single
                    result[range].foregroundColor = linkColor
                }
            }
            return result
        }

        /// The bubble's text, with each code span a `CodeBackground` run so a
        /// `CodeBackgroundRenderer` can draw the wash behind it (SwiftUI's own
        /// `backgroundColor` is square-cornered). Text without code is the
        /// plain `Text(attributed)` it always was.
        func text(linkColor: Color, mentionColor: Color) -> Text {
            let attributed = attributed(linkColor: linkColor, mentionColor: mentionColor)
            guard hasCode else { return Text(attributed) }
            var pieces: [Text] = []
            var cursor = attributed.startIndex
            for span in spans.filter(\.isCode).sorted(by: { $0.range.location < $1.range.location }) {
                guard let range = Range(span.range, in: attributed), range.lowerBound >= cursor
                else { continue }
                if cursor < range.lowerBound {
                    pieces.append(Text(AttributedString(attributed[cursor..<range.lowerBound])))
                }
                var piece = AttributedString(attributed[range])
                if span.isCodeBlock { piece.fillBlankLines() }
                pieces.append(
                    Text(piece).customAttribute(CodeBackground(isBlock: span.isCodeBlock))
                )
                cursor = range.upperBound
            }
            if cursor < attributed.endIndex {
                pieces.append(Text(AttributedString(attributed[cursor...])))
            }
            return pieces.reduce(Text("")) { Text("\($0)\($1)") }
        }
    }

    /// Marks a run as code for `CodeBackgroundRenderer`.
    struct CodeBackground: TextAttribute {
        let isBlock: Bool
    }

    /// Draws a rounded wash behind every `CodeBackground` run, then the text.
    /// An inline run gets one pill per line it sits on; a block, one panel
    /// around all its lines. The wash only paints — layout is the text's own.
    struct CodeBackgroundRenderer: TextRenderer {
        var fill: Color

        /// The wash is drawn past the text's own frame (a block's padding, a
        /// pill's 2pt); without this SwiftUI clips it flat at the edge.
        var displayPadding: EdgeInsets {
            EdgeInsets(
                top: 1, leading: CodeStyle.blockPadding, bottom: 1,
                trailing: CodeStyle.blockPadding
            )
        }

        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            var panel: CGRect?
            for line in layout {
                var pill: CGRect?
                var blockOnLine: CGRect?
                for run in line {
                    let bounds = run.typographicBounds.rect
                    if let mark = run[CodeBackground.self] {
                        if mark.isBlock {
                            blockOnLine = blockOnLine.map { $0.union(bounds) } ?? bounds
                        } else {
                            pill = pill.map { $0.union(bounds) } ?? bounds
                        }
                    } else if let rect = pill {
                        paint(rect.insetBy(dx: -2, dy: 1), radius: CodeStyle.inlineRadius, in: &context)
                        pill = nil
                    }
                }
                if let rect = pill {
                    paint(rect.insetBy(dx: -2, dy: 1), radius: CodeStyle.inlineRadius, in: &context)
                }
                if let block = blockOnLine {
                    let lineBounds = line.typographicBounds.rect
                    let row = CGRect(
                        x: block.minX, y: lineBounds.minY, width: block.width,
                        height: lineBounds.height
                    )
                    panel = panel.map { $0.union(row) } ?? row
                } else if let rect = panel {
                    paint(rect.insetBy(dx: -CodeStyle.blockPadding, dy: 0), radius: CodeStyle.blockRadius, in: &context)
                    panel = nil
                }
            }
            if let rect = panel {
                paint(rect.insetBy(dx: -CodeStyle.blockPadding, dy: 0), radius: CodeStyle.blockRadius, in: &context)
            }
            for line in layout { context.draw(line) }
        }

        private func paint(_ rect: CGRect, radius: CGFloat, in context: inout GraphicsContext) {
            context.fill(
                Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                with: .color(fill)
            )
        }
    }

    /// `names` is the roster a tag is matched against. Passing none renders
    /// the text exactly as it did before tags were drawn — `@Name` and all.
    ///
    /// Memoised: the answer is a pure function of (source, roster, zone), and
    /// the same message is rendered by its bubble, by the size probes that
    /// ask for the string again, by a sidebar preview and by every reply that
    /// quotes it — on every pass, and again from empty on each chat switch.
    /// The cache is process-wide, count- and cost-bounded, and thread-safe, so
    /// no call site changes.
    static func render(
        _ source: String, names: [String] = [], timeZone: TimeZone = .current
    ) -> Rendered {
        // A very long post is rendered once for its bubble and not worth
        // pinning; the cache is for the many short messages.
        guard source.utf16.count <= RenderCache.maxSourceLength else {
            return renderUncached(source, names: names, timeZone: timeZone)
        }
        let key = RenderCache.Key(
            source: source, rosterID: MentionText.rosterID(names),
            zone: timeZone.identifier
        )
        if let hit = RenderCache.shared.object(forKey: key) {
            RenderCache.count(hit: true)
            return hit.value
        }
        RenderCache.count(hit: false)
        let rendered = renderUncached(source, names: names, timeZone: timeZone)
        RenderCache.shared.setObject(
            RenderCache.Entry(rendered), forKey: key,
            cost: 256 + source.utf16.count * 6
        )
        return rendered
    }

    /// The cache behind `render`. `NSCache` is already thread-safe and sheds
    /// entries under memory pressure; the limits keep it from growing with a
    /// long session either way.
    enum RenderCache {
        static let maxSourceLength = 20_000

        final class Key: NSObject {
            let source: String
            let rosterID: Int
            let zone: String

            init(source: String, rosterID: Int, zone: String) {
                self.source = source
                self.rosterID = rosterID
                self.zone = zone
            }

            override var hash: Int {
                var hasher = Hasher()
                hasher.combine(source)
                hasher.combine(rosterID)
                hasher.combine(zone)
                return hasher.finalize()
            }

            override func isEqual(_ object: Any?) -> Bool {
                guard let other = object as? Key else { return false }
                return rosterID == other.rosterID && zone == other.zone && source == other.source
            }
        }

        final class Entry {
            let value: Rendered
            init(_ value: Rendered) { self.value = value }
        }

        static let shared: NSCache<Key, Entry> = {
            let cache = NSCache<Key, Entry>()
            cache.countLimit = 4_000
            cache.totalCostLimit = 12_000_000
            return cache
        }()

        private static let tally = OSAllocatedUnfairLock(initialState: (hits: 0, misses: 0))

        fileprivate static func count(hit: Bool) {
            tally.withLock { if hit { $0.hits += 1 } else { $0.misses += 1 } }
        }

        /// Hits and misses since launch (or the last `reset`): what the tests
        /// read to prove a second render came from the cache.
        static var stats: (hits: Int, misses: Int) { tally.withLock { $0 } }

        static func reset() {
            shared.removeAllObjects()
            tally.withLock { $0 = (0, 0) }
        }
    }

    /// The render itself, with no cache. `render` is this plus the memo.
    static func renderUncached(
        _ source: String, names: [String] = [], timeZone: TimeZone = .current
    ) -> Rendered {
        var text = ""
        var spans: [Span] = []
        let segments = fenceSegments(in: source).filter { !($0.isCode && $0.text.isEmpty) }
        for (index, segment) in segments.enumerated() {
            if index > 0 { text += "\n" }
            let offset = text.utf16.count
            if segment.isCode {
                text += segment.text
                spans.append(
                    Span(
                        range: NSRange(location: offset, length: segment.text.utf16.count),
                        isBold: false, isItalic: false, link: nil,
                        isCode: true, isCodeBlock: true
                    )
                )
            } else {
                let parsed = parsedInline(segment.text, timeZone: timeZone)
                text += parsed.text
                spans += parsed.spans.map {
                    var shifted = $0
                    shifted.range.location += offset
                    return shifted
                }
            }
        }
        return tagged(linkify(Rendered(text: text, spans: spans)), names: names)
    }

    /// The source cut at its fenced ``` blocks, by CommonMark's rules. A fence
    /// opens on a line that is three or more backticks and an optional info
    /// string (`swift`) that holds no backtick — nothing else, so
    /// "```bun run ci``` and on" is inline code in a sentence. It closes on a
    /// line of at least as many backticks and only spaces after them; every
    /// other line, a "```swift" or "``` words" included, is code. A fence
    /// left open — an answer still streaming — runs to the end. A block with
    /// nothing in it (or only blank lines) keeps its fence lines as plain text, so no message ever
    /// loses its words. What is inside is literal: no Markdown, no tags, no
    /// links. The segments are separate paragraphs, so the caller puts a line
    /// break between them.
    private static func fenceSegments(in source: String) -> [(text: String, isCode: Bool)] {
        guard source.contains("```") else { return [(source, false)] }
        // "\r\n" is one Character, so a split on "\n" never sees it.
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        func backtickRun(_ line: Substring) -> (count: Int, rest: Substring)? {
            guard line.prefix(while: { $0 == " " }).count < 4 else { return nil }
            let body = line.drop(while: { $0 == " " })
            let ticks = body.prefix(while: { $0 == "`" }).count
            return ticks >= 3 ? (ticks, body.dropFirst(ticks)) : nil
        }
        func opens(_ line: Substring) -> Int? {
            guard let run = backtickRun(line), !run.rest.contains("`") else { return nil }
            return run.count
        }
        func closes(_ line: Substring, fence: Int) -> Bool {
            guard let run = backtickRun(line) else { return false }
            return run.count >= fence && run.rest.allSatisfy { $0 == " " }
        }

        var segments: [(text: String, isCode: Bool)] = []
        var prose: [Substring] = []
        func flushProse() {
            if !prose.isEmpty { segments.append((prose.joined(separator: "\n"), false)) }
            prose = []
        }

        var index = 0
        while index < lines.count {
            guard let fence = opens(lines[index]) else {
                prose.append(lines[index])
                index += 1
                continue
            }
            var body: [Substring] = []
            var end = index + 1
            var closed = false
            while end < lines.count {
                if closes(lines[end], fence: fence) { closed = true; break }
                body.append(lines[end])
                end += 1
            }
            if body.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                // Nothing to set in a block: the fence lines stay as typed.
                // Escaped, or the Markdown pass would read two backticks as an
                // empty code span and a trailing backslash as a line break,
                // and swallow them. The backslash goes first.
                func literal(_ line: Substring) -> Substring {
                    Substring(
                        line.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "`", with: "\\`")
                    )
                }
                prose.append(literal(lines[index]))
                prose += body
                if closed { prose.append(literal(lines[end])) }
            } else {
                flushProse()
                segments.append((body.joined(separator: "\n"), true))
            }
            index = closed ? end + 1 : end
        }
        flushProse()
        return segments
    }

    /// One run of ordinary Markdown, parsed to its display text and spans.
    private static func parsedInline(_ source: String, timeZone: TimeZone) -> Rendered {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let displaySource = normalizedListMarkers(in: source)
        guard let parsed = try? AttributedString(markdown: displaySource, options: options) else {
            return Rendered(text: displaySource, spans: [])
        }

        let localized = localizingTimestamps(in: parsed, timeZone: timeZone)
        let text = String(localized.characters)
        var spans: [Span] = []
        var location = 0
        for run in localized.runs {
            let runText = String(localized[run.range].characters)
            let inline = run.inlinePresentationIntent
            let link = safeLink(run.link)
            if inline != nil || link != nil {
                spans.append(
                    Span(
                        range: NSRange(location: location, length: runText.utf16.count),
                        isBold: inline?.contains(.stronglyEmphasized) == true,
                        isItalic: inline?.contains(.emphasized) == true,
                        link: link,
                        isCode: inline?.contains(.code) == true,
                        isStrikethrough: inline?.contains(.strikethrough) == true
                    )
                )
            }
            location += runText.utf16.count
        }
        return Rendered(text: text, spans: spans)
    }

    /// The tag pass, run last so it sees the text a bubble will actually
    /// show. Each `@Name` loses its `@` and takes the roster's spelling,
    /// which shortens the string — so every span found earlier is carried
    /// across to its new home rather than left pointing at stale offsets.
    private static func tagged(_ rendered: Rendered, names: [String]) -> Rendered {
        // Code is literal: a tag typed inside it stays as typed.
        let codeRanges = rendered.spans.filter(\.isCode).map(\.range)
        let matches = MentionText.matches(in: rendered.text, names: names).filter { match in
            let range = NSRange(match.range, in: rendered.text)
            return !codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        guard !matches.isEmpty else { return rendered }

        struct Shift {
            let start: Int
            let end: Int
            let newStart: Int
            let delta: Int
        }

        var text = ""
        var mentions: [Span] = []
        var shifts: [Shift] = []
        var cursor = rendered.text.startIndex
        var old = 0
        var new = 0

        for match in matches {
            let between = rendered.text[cursor..<match.range.lowerBound]
            text += between
            old += between.utf16.count
            new += between.utf16.count

            let wasLength = rendered.text[match.range].utf16.count
            let nowLength = match.name.utf16.count
            text += match.name
            mentions.append(
                Span(
                    range: NSRange(location: new, length: nowLength),
                    isBold: false, isItalic: false, link: nil, isMention: true
                )
            )
            shifts.append(
                Shift(start: old, end: old + wasLength, newStart: new, delta: nowLength - wasLength)
            )
            old += wasLength
            new += nowLength
            cursor = match.range.upperBound
        }
        text += rendered.text[cursor...]

        // A location inside a tag has nowhere exact to land, so it collapses
        // to the tag's start; everything after it moves by what was removed.
        func moved(_ location: Int) -> Int {
            var accumulated = 0
            for shift in shifts {
                if location >= shift.end {
                    accumulated += shift.delta
                } else if location > shift.start {
                    return shift.newStart
                } else {
                    break
                }
            }
            return location + accumulated
        }

        var spans = mentions
        for span in rendered.spans {
            let start = moved(span.range.location)
            let end = moved(NSMaxRange(span.range))
            guard end > start else { continue }
            var carried = span
            carried.range = NSRange(location: start, length: end - start)
            spans.append(carried)
        }
        return Rendered(text: text, spans: spans)
    }

    private static func localizingTimestamps(
        in parsed: AttributedString, timeZone: TimeZone
    ) -> AttributedString {
        var result = AttributedString()
        for (link, range) in parsed.runs[\.link] {
            let original = AttributedString(parsed[range])
            guard let link,
                  let text = formattedTimestamp(in: link.absoluteString, timeZone: timeZone)
            else {
                result.append(original)
                continue
            }
            var replacement = AttributedString(text)
            if let attributes = original.runs.first?.attributes {
                replacement.setAttributes(attributes)
            }
            replacement.link = nil
            result.append(replacement)
        }
        return result
    }

    private static func formattedTimestamp(in rawURL: String, timeZone: TimeZone) -> String? {
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              HQConfig.isServerHost(components.host),
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.path == "/admin",
              let encodedFragment = components.percentEncodedFragment,
              let fragment = encodedFragment.removingPercentEncoding
        else { return nil }

        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let key = String(fields[0]).removingPercentEncoding,
                  let value = String(fields[1]).removingPercentEncoding,
                  !key.isEmpty,
                  values[key] == nil
            else { return nil }
            values[key] = value
        }

        guard let style = values["style"].flatMap(RichTimestampStyle.init(rawValue:))
        else { return nil }

        if style == .range {
            return formattedTimestampRange(values: values, timeZone: timeZone)
        }

        guard Set(values.keys) == Set(["timestamp", "style"]),
              let timestamp = values["timestamp"].flatMap(Int64.init),
              validTimestampSeconds.contains(timestamp)
        else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        switch style {
        case .dateTime:
            formatter.dateFormat = "MMM d, h:mm a zzz"
        case .range:
            return nil
        case .time:
            formatter.dateFormat = "h:mm a"
        case .timeZone:
            formatter.dateFormat = "h:mm a zzz"
        }
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }

    private static func formattedTimestampRange(
        values: [String: String], timeZone: TimeZone
    ) -> String? {
        guard Set(values.keys) == Set(["timestamp", "end", "style"]),
              let start = values["timestamp"].flatMap(Int64.init),
              let end = values["end"].flatMap(Int64.init),
              validTimestampSeconds.contains(start),
              validTimestampSeconds.contains(end),
              end >= start
        else { return nil }
        return formattedTimestampRange(start: start, end: end, timeZone: timeZone)
    }

    private static func formattedTimestampRange(
        start: Int64, end: Int64, timeZone: TimeZone
    ) -> String {
        let startDate = Date(timeIntervalSince1970: Double(start))
        let endDate = Date(timeIntervalSince1970: Double(end))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "MMM d"

        let zoneFormatter = DateFormatter()
        zoneFormatter.calendar = calendar
        zoneFormatter.locale = Locale(identifier: "en_US_POSIX")
        zoneFormatter.timeZone = timeZone
        zoneFormatter.dateFormat = "zzz"

        let sameDay = calendar.isDate(startDate, inSameDayAs: endDate)
        let startZone = zoneFormatter.string(from: startDate)
        let endZone = zoneFormatter.string(from: endDate)
        let sameZone = startZone == endZone
        let startHour = calendar.component(.hour, from: startDate)
        let endHour = calendar.component(.hour, from: endDate)
        let startPeriod = startHour < 12 ? "am" : "pm"
        let endPeriod = endHour < 12 ? "am" : "pm"
        let includeStartPeriod = !(sameDay && sameZone && startPeriod == endPeriod)

        func time(_ date: Date, hour: Int, period: String, includePeriod: Bool) -> String {
            let minute = calendar.component(.minute, from: date)
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let value = String(format: "%d:%02d", hour12, minute)
            return includePeriod ? value + period : value
        }

        let startDateLabel = sameDay ? "" : dateFormatter.string(from: startDate) + ", "
        let endDateLabel = sameDay ? "" : dateFormatter.string(from: endDate) + ", "
        let startZoneLabel = sameZone ? "" : " \(startZone)"
        let startTime = time(
            startDate, hour: startHour, period: startPeriod, includePeriod: includeStartPeriod
        )
        let endTime = time(endDate, hour: endHour, period: endPeriod, includePeriod: true)
        let startLabel = "\(startDateLabel)\(startTime)\(startZoneLabel)"
        let endLabel = "\(endDateLabel)\(endTime) \(endZone)"
        return "\(startLabel)-\(endLabel)"
    }

    private static func normalizedListMarkers(in source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var value = String(line)
                let content = value.drop(while: { $0 == " " || $0 == "\t" })
                guard content.count >= 2 else { return value }
                let marker = content.first
                let next = content.index(after: content.startIndex)
                guard (marker == "-" || marker == "*" || marker == "+"), content[next] == " "
                else { return value }
                let markerIndex = value.index(value.startIndex, offsetBy: value.count - content.count)
                value.replaceSubrange(markerIndex...markerIndex, with: "•")
                return value
            }
            .joined(separator: "\n")
    }

    private static func safeLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }

    /// Keep the pre-Markdown behaviour: ordinary URLs remain tappable. A
    /// detector match never replaces an explicit, already-safe Markdown link.
    private static func linkify(_ rendered: Rendered) -> Rendered {
        var spans = rendered.spans
        for match in linkMatches(in: rendered.text) {
            guard !spans.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 })
            else { continue }
            spans.append(
                Span(range: match.range, isBold: false, isItalic: false, link: match.url)
            )
        }
        return Rendered(text: rendered.text, spans: spans)
    }
}

private extension AttributedString {
    /// An empty line has no glyphs, so SwiftUI lays it out with no run for the
    /// renderer to find and a block's panel would break there. A zero-width
    /// space gives it one; it is drawn nowhere and only the display string has
    /// it — the message text is untouched.
    mutating func fillBlankLines() {
        var blanks: [AttributedString.Index] = []
        var previous: Character? = "\n"
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            if previous == "\n", character == "\n" { blanks.append(index) }
            previous = character
            index = characters.index(after: index)
        }
        if previous == "\n", !characters.isEmpty { blanks.append(characters.endIndex) }
        let attributes = runs.first?.attributes ?? AttributeContainer()
        for at in blanks.reversed() {
            insert(AttributedString("\u{200B}", attributes: attributes), at: at)
        }
    }
}
