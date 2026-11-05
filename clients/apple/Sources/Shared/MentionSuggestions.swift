import Foundation

/// One row the @-mention picker can offer: somebody in the room, or one of
/// the two tags that address the room itself.
enum MentionCandidate: Identifiable, Equatable {
    case person(Person)
    case broadcast(MentionText.Broadcast)

    var id: String {
        switch self {
        case .person(let person): return person.id
        case .broadcast(let broadcast): return "broadcast:\(broadcast.rawValue)"
        }
    }

    /// What the row reads, and what a pick puts in the draft: a bare name for
    /// a person, `@everyone` for a broadcast.
    var label: String {
        switch self {
        case .person(let person): return person.name
        case .broadcast(let broadcast): return broadcast.tag
        }
    }

    /// The one line under the label, for rows whose meaning is not their name.
    var caption: String? {
        switch self {
        case .person: return nil
        case .broadcast(let broadcast): return broadcast.caption
        }
    }

    /// What has to be typed after the `@` to reach this row.
    var token: String {
        switch self {
        case .person(let person): return person.name
        case .broadcast(let broadcast): return broadcast.rawValue
        }
    }

    var person: Person? {
        if case .person(let person) = self { return person }
        return nil
    }
}

/// The @-mention picker's brain, shared by both composers: what token is
/// being typed, who can be tagged, and what the draft becomes when one is
/// picked. The trigger is the web composer's own `/(^|\s)@([^\s@]*)$/`,
/// transliterated once so all three clients agree about what counts as a
/// mention.
struct MentionSuggestions {
    /// How many rows a picker shows before it stops growing.
    static let visibleLimit = 5

    let draft: String
    /// The thread's members, minus the viewer.
    let members: [Person]
    /// The assistant rides in every thread without appearing as a member, so it is
    /// offered here even when the roster does not name it.
    let assistant: Person?

    /// The trailing "@token" being typed, or nil when the caret is not in one.
    var token: String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            guard draft[draft.index(before: atIndex)].isWhitespace else { return nil }
        }
        let token = draft[draft.index(after: atIndex)...]
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }

    /// Everyone tag-able here. Bots lead — they are the mentions that do
    /// something. `@here` and `@everyone` come last, deliberately: they are
    /// typed in full far more often than they are browsed to, and a room-wide
    /// tag is not what a half-typed `@e` should be sitting on when Return
    /// lands.
    var candidates: [MentionCandidate] {
        var people = members
        if let assistant, !people.contains(where: { $0.id == assistant.id }) {
            people.append(assistant)
        }
        let sorted = people.sorted {
            ($0.kind == "bot" ? 0 : 1, $0.name) < ($1.kind == "bot" ? 0 : 1, $1.name)
        }
        return sorted.map(MentionCandidate.person)
            + MentionText.Broadcast.allCases.map(MentionCandidate.broadcast)
    }

    /// The names a composer tints against — people only. Broadcasts are
    /// `MentionText`'s own business and are matched there whatever roster it
    /// is handed, so listing them here would double them up.
    var personNames: [String] { candidates.compactMap(\.person).map(\.name) }

    var matches: [MentionCandidate] {
        guard let token else { return [] }
        guard !token.isEmpty else { return candidates }
        return candidates.filter { $0.token.localizedCaseInsensitiveContains(token) }
    }

    /// The rows a picker actually draws. The limit is spent on people FIRST
    /// being wrong: with a full room, a plain `@` would fill all five slots
    /// with names and push both room tags off the end, so `@here` could only
    /// ever be found by already knowing to type it. A matching broadcast
    /// therefore holds its seat and the people take what is left — the popup
    /// stays the same height either way.
    var visible: [MentionCandidate] {
        let all = matches
        let rooms = all.filter { $0.person == nil }
        let people = all.filter { $0.person != nil }
        let room = rooms.prefix(Self.visibleLimit)
        return Array(people.prefix(Self.visibleLimit - room.count)) + room
    }

    /// The draft with the half-typed token replaced by the picked tag.
    func applying(_ candidate: MentionCandidate) -> String {
        guard let atIndex = draft.lastIndex(of: "@") else { return draft }
        switch candidate {
        case .person(let person):
            return String(draft[..<atIndex]) + "@\(person.name) "
        case .broadcast(let broadcast):
            return String(draft[..<atIndex]) + "\(broadcast.tag) "
        }
    }
}
