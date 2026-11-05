import Foundation
import os

/// The two faces of a tagged name. The wire carries `@Turner` — that is what
/// the server routes bots on, what the web app shows, and what every older
/// build already stored — so nothing here changes what a message *is*. What
/// changes is what a person sees: Messages drops the `@` once a tag resolves
/// and shows the name alone, tinted. So display text is wire text with the
/// `@` of every resolved mention removed, and the runs left behind say where
/// the tags now sit.
///
/// Both directions are pure and total: `display` then `wire` returns the
/// original string, which is what lets an editor hold the display form while
/// the draft binding keeps holding the wire form.
enum MentionText {
    /// The two tags that address a room rather than a person. They hold no
    /// roster seat and never will, so they are matched by the same token rules
    /// and kept apart by kind: a person's tag reads as the bare name, a
    /// broadcast keeps its `@` because "everyone" on its own is just a word.
    ///
    /// `@everyone` is the loud one — the server lets it through a muted
    /// thread. `@here` addresses the room and routes like any
    /// other message, which in HQ already reaches every unmuted member.
    enum Broadcast: String, CaseIterable, Equatable, Sendable {
        case everyone
        case here

        /// How it is spelled everywhere a person sees it.
        var tag: String { "@" + rawValue }

        /// The one line a picker row carries under the tag. Short on purpose:
        /// it sits on one line in a narrow popup, and a truncated explanation
        /// explains nothing.
        var caption: String {
            switch self {
            case .everyone: return "Muted or not"
            case .here: return "Everyone in this thread"
            }
        }
    }

    /// A resolved `@Name` inside a piece of wire text.
    struct Match: Equatable {
        let range: Range<String.Index>
        /// How the tag should read: the roster's spelling, not the typed one —
        /// `@turner` resolves to "Turner", the way Messages corrects a tag as
        /// you commit it — or `@everyone` for a broadcast, `@` and all.
        let name: String
        /// Nil for a person.
        let broadcast: Broadcast?

        init(range: Range<String.Index>, name: String, broadcast: Broadcast? = nil) {
            self.range = range
            self.name = name
            self.broadcast = broadcast
        }
    }

    /// One thing an `@token` can resolve to, in the order the matcher tries
    /// them: longest first, and a roster name ahead of a broadcast of the same
    /// length, so a teammate called Here is still tag-able as herself.
    private struct Candidate {
        /// What has to be typed after the `@`.
        let token: String
        /// What the tag becomes once it resolves.
        let display: String
        let broadcast: Broadcast?
        /// The token's length and lowercase spelling, worked out once per
        /// roster rather than once per `@` in every message that is scanned.
        let length: Int
        let folded: String

        init(token: String, display: String, broadcast: Broadcast?) {
            self.token = token
            self.display = display
            self.broadcast = broadcast
            self.length = token.count
            self.folded = token.lowercased()
        }
    }

    // The sorted candidate list for the roster last asked about. Rendering
    // calls `matches` once per bubble, sidebar preview and reply quote, and a
    // pass hands every one of them the same roster array, so a single slot
    // (compared by `==`, which is O(1) for the very same buffer) turns the
    // per-call sort into one sort per roster change. Locked: the Markdown
    // render is callable from any thread.
    private static let candidateMemo =
        OSAllocatedUnfairLock<(names: [String], list: [Candidate])?>(initialState: nil)

    private static func candidates(_ names: [String]) -> [Candidate] {
        if let memo = candidateMemo.withLock({ $0 }), memo.names == names { return memo.list }
        let people = names.map { Candidate(token: $0, display: $0, broadcast: nil) }
        let rooms = Broadcast.allCases.map {
            Candidate(token: $0.rawValue, display: $0.tag, broadcast: $0)
        }
        // Sorted with an explicit tiebreak rather than on length alone:
        // Swift's sort is not stable, and a coin-flip between "Here" the
        // person and `@here` the broadcast is not a rule anyone can rely on.
        let list = (people + rooms).sorted {
            if $0.length != $1.length { return $0.length > $1.length }
            return ($0.broadcast == nil ? 0 : 1) < ($1.broadcast == nil ? 0 : 1)
        }
        candidateMemo.withLock { $0 = (names, list) }
        return list
    }

    // A roster's identity as a number, for cache keys. Two arrays with the
    // same names in the same order share an id; a changed roster gets a new
    // one. The last array asked about is remembered by `==`, so the four size
    // probes a bubble gets per pass (all handed one array) cost a buffer
    // compare each instead of joining the roster into a fresh string.
    private static let rosterMemo =
        OSAllocatedUnfairLock<(names: [String], id: Int)>(initialState: ([], 0))
    private static let rosterTable =
        OSAllocatedUnfairLock<(ids: [[String]: Int], next: Int)>(initialState: ([:], 1))

    /// 0 for an empty roster, otherwise a small integer standing for exactly
    /// this list of names. Never reused for different content in a process.
    static func rosterID(_ names: [String]) -> Int {
        if names.isEmpty { return 0 }
        let last = rosterMemo.withLock { $0 }
        if last.names == names { return last.id }
        let id = rosterTable.withLock { table -> Int in
            if let known = table.ids[names] { return known }
            // Bounded: a roster only changes when someone joins or leaves, so
            // this never fills in practice. Dropping the table costs a cache
            // miss, never a wrong answer, because ids are not recycled.
            if table.ids.count > 64 { table.ids.removeAll() }
            let fresh = table.next
            table.next += 1
            table.ids[names] = fresh
            return fresh
        }
        rosterMemo.withLock { $0 = (names, id) }
        return id
    }

    /// Display text plus where its tags live, as UTF-16 ranges — the
    /// coordinate space `NSAttributedString` and both text views speak.
    struct Display: Equatable {
        let text: String
        let runs: [NSRange]

        static let empty = Self(text: "", runs: [])
    }

    /// Every tag in `text`: the roster names it spells, and the broadcasts.
    ///
    /// The `@` must open a token (start of string, or after whitespace) and
    /// the name must end on a boundary, so `me@work.com` and `@turnery` are
    /// not tags. Longer names are tried first: on a roster holding both
    /// "Bo" and "Bo Turner", `@Bo Turner` is one tag, not one tag
    /// and a stray surname.
    static func matches(in text: String, names: [String]) -> [Match] {
        // No `@`, no tag: skip the roster work entirely for the common case.
        guard !text.isEmpty, text.contains("@" as Character) else { return [] }
        let candidates = candidates(names)
        var matches: [Match] = []
        var index = text.startIndex

        while index < text.endIndex, let at = text[index...].firstIndex(of: "@") {
            let afterAt = text.index(after: at)
            // Where the scan resumes if nothing matches here: past the `@`
            // itself, never at it, or this loop never finishes.
            var resume = afterAt
            let opensToken = at == text.startIndex || text[text.index(before: at)].isWhitespace

            if opensToken {
                for candidate in candidates {
                    guard
                        let end = text.index(
                            afterAt, offsetBy: candidate.length, limitedBy: text.endIndex
                        ),
                        text[afterAt..<end].lowercased() == candidate.folded,
                        end == text.endIndex || !isNameCharacter(text[end])
                    else { continue }
                    matches.append(
                        Match(range: at..<end, name: candidate.display, broadcast: candidate.broadcast)
                    )
                    resume = end
                    break
                }
            }
            index = resume
        }
        return matches
    }

    /// Whether a message tags the whole room the loud way — the one tag a
    /// thread on Hide Alerts still banners for. The roster is deliberately
    /// not consulted, so this answers the same way on a client that has not
    /// loaded people yet, and the hub's `mentionsEveryone` agrees with it.
    static func mentionsEveryone(_ wire: String) -> Bool {
        matches(in: wire, names: []).contains { $0.broadcast == .everyone }
    }

    /// Wire text as it should be shown: every resolved tag loses its `@` and
    /// takes the roster's spelling.
    static func display(from wire: String, names: [String]) -> Display {
        let matches = matches(in: wire, names: names)
        guard !matches.isEmpty else {
            return Display(text: wire, runs: [])
        }

        var text = ""
        var runs: [NSRange] = []
        var cursor = wire.startIndex
        var offset = 0

        for match in matches {
            let between = wire[cursor..<match.range.lowerBound]
            text += between
            offset += between.utf16.count
            text += match.name
            runs.append(NSRange(location: offset, length: match.name.utf16.count))
            offset += match.name.utf16.count
            cursor = match.range.upperBound
        }
        text += wire[cursor...]
        return Display(text: text, runs: runs)
    }

    /// Display text back to the wire: each tag gets its `@` again. A broadcast
    /// never lost one — `@everyone` is shown with it — so a run that already
    /// opens with `@` is passed through rather than given a second. Runs that
    /// fall outside the string, or overlap one another, are dropped rather
    /// than trusted — an editor's attributes are only as tidy as the last
    /// edit left them.
    static func wire(fromDisplay text: String, runs: [NSRange]) -> String {
        guard !runs.isEmpty else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0

        for run in runs.sorted(by: { $0.location < $1.location }) {
            guard run.length > 0, run.location >= cursor, NSMaxRange(run) <= source.length else {
                continue
            }
            result += source.substring(with: NSRange(location: cursor, length: run.location - cursor))
            let tag = source.substring(with: run)
            result += tag.hasPrefix("@") ? tag : "@" + tag
            cursor = NSMaxRange(run)
        }
        result += source.substring(from: cursor)
        return result
    }

    /// Wire text as a PLAIN-text surface should show it — a sidebar preview,
    /// a reply quote, a notification. Those cannot carry the tint a bubble
    /// gives a tag, but they can at least agree with it about the words: a
    /// person's `@` goes and the roster's spelling is used, a broadcast keeps
    /// its own. Without this the same message reads two ways in one app.
    static func plain(_ wire: String, names: [String]) -> String {
        ChatMarkdown.render(wire, names: names).text
    }

    /// The tag a half-typed token turns into when it is committed — the space
    /// or tab that ends it, or a pick from the picker. A broadcast commits to
    /// its own spelling, `@` and all.
    ///
    /// An exact spelling always wins, so a roster holding both "Ada" and
    /// "Samantha" still lets "Ada" be tagged. Otherwise the token must name
    /// exactly one candidate: an ambiguous prefix commits to nobody and stays
    /// the literal text somebody typed.
    static func commitName(for token: String, names: [String]) -> String? {
        guard !token.isEmpty else { return nil }
        let candidates = candidates(names)
        let typed = token.lowercased()
        if let exact = candidates.first(where: { $0.folded == typed }) {
            return exact.display
        }
        let prefixed = candidates.filter { $0.folded.hasPrefix(typed) }
        return prefixed.count == 1 ? prefixed.first?.display : nil
    }

    /// Whether a trailing token is worth tinting: at least one person on the
    /// roster, or one broadcast, answers to it. A token nobody answers to
    /// stays plain text, so an email address or a stray `@` never lights up.
    static func isLiveToken(_ token: String, names: [String]) -> Bool {
        guard !token.isEmpty else { return false }
        let typed = token.lowercased()
        return candidates(names).contains { $0.folded.hasPrefix(typed) }
    }

    /// The trailing `@token` a caret sits inside, or nil when it does not.
    /// The rule is `MentionSuggestions`' own, applied to the text before a
    /// caret rather than to a whole draft, because an editor's caret is not
    /// always at the end.
    static func trailingToken(before caret: String) -> (token: String, at: String.Index)? {
        guard let at = caret.lastIndex(of: "@") else { return nil }
        if at > caret.startIndex {
            guard caret[caret.index(before: at)].isWhitespace else { return nil }
        }
        let token = caret[caret.index(after: at)...]
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return (String(token), at)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
