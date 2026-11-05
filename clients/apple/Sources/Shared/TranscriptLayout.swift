import Foundation

/// The rules that decide what a transcript looks like: where a quiet stretch
/// gets stamped with its time, where a run of one person's messages starts
/// and ends, who gets a name label, who gets an avatar, and which bursts of
/// identical group events collapse into one line.
///
/// It is here, and not in either app's view layer, because "the same layout"
/// has to mean the same arithmetic — a phone that broke runs at 40 minutes
/// while the Mac broke them at 30 would be two products. Views ask; this
/// answers; neither platform owns a copy.
struct TranscriptLayout {
    static func orderedMessages(_ messages: [Message]) -> [Message] {
        messages.filter { $0.isHidden != true }
    }

    let messages: [Message]
    let myPersonId: String?
    let isGroup: Bool
    /// A DM whose whole other side is bots: a lone bot there needs no name
    /// label, because there is nobody else it could be.
    let isBotDM: Bool
    /// Whether a sender is a bot — a tagged assistant interjecting in a human
    /// DM must say who is talking.
    let isBot: (String) -> Bool

    /// A time stamp whenever the conversation goes quiet for half an hour,
    /// which is how Messages breaks a long thread into readable stretches.
    func shouldShowTimestamp(at index: Int) -> Bool {
        // Indices arrive from view closures that can update after the array
        // they enumerated was replaced; a stale index renders nothing rather
        // than trapping.
        guard messages.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        let gap = messages[index].transcriptDate.timeIntervalSince(messages[index - 1].transcriptDate)
        return gap > RelativeStamp.quietGap
    }

    /// A run breaks on a sender change, a centered group event, or the
    /// timestamp a quiet half hour stamps between messages.
    func isStartOfRun(at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        let previous = messages[index - 1]
        return previous.senderPersonId != messages[index].senderPersonId
            || previous.isSystem
            || shouldShowTimestamp(at: index)
    }

    /// Sender labels appear on the first incoming message of a run — in
    /// groups, and for a bot interjecting in a human DM.
    func shouldShowSender(at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        let message = messages[index]
        guard message.senderPersonId != myPersonId else { return false }
        let isBotSender = isBot(message.senderPersonId)
        guard isGroup || (isBotSender && !isBotDM) else { return false }
        return isStartOfRun(at: index)
    }

    /// The sender's avatar sits beside the LAST message of a run — for
    /// incoming messages in groups, and for a bot anywhere: a bot's mark is
    /// how the room knows the machine spoke.
    func shouldShowAvatar(at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        let message = messages[index]
        guard message.senderPersonId != myPersonId,
              isGroup || isBot(message.senderPersonId)
        else { return false }
        guard index < messages.count - 1 else { return true }
        return isStartOfRun(at: index + 1)
    }

    /// A burst of the same event from one actor — twelve completions landing
    /// in one sitting — reads as one line plus a count instead of twelve
    /// identical rows. A run is consecutive events of one kind from one
    /// sender, and it ends wherever a timestamp separator would break the
    /// transcript anyway, so a run never swallows one.
    var eventRuns: (runs: [String: [Message]], absorbed: Set<String>) {
        var runs: [String: [Message]] = [:]
        var absorbed: Set<String> = []
        var index = 0
        while index < messages.count {
            guard messages[index].isSystem else {
                index += 1
                continue
            }
            var end = index + 1
            while end < messages.count,
                messages[end].isSystem,
                messages[end].kind == messages[index].kind,
                messages[end].senderPersonId == messages[index].senderPersonId,
                !shouldShowTimestamp(at: end) {
                end += 1
            }
            if end - index > 1 {
                runs[messages[index].id] = Array(messages[index..<end])
                absorbed.formUnion(messages[(index + 1)..<end].map(\.id))
            }
            index = end
        }
        return (runs, absorbed)
    }

    /// How many loaded messages reply to each message — what the "N Replies"
    /// link under an original counts.
    var replyCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for message in messages where !message.isDeleted {
            if let target = message.replyTo?.id { counts[target, default: 0] += 1 }
        }
        return counts
    }
}
