import CryptoKit
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

// Link previews the way Messages does them: the RECEIVING app resolves the
// page's metadata itself (LinkPresentation), nothing rides the wire. Fetched
// metadata is archived to disk so a link resolves once per device, not once
// per scroll-into-view. Shared by both clients — the resolving, the disk
// cache, and the card are identical; only the image class has two names.
/// Settings → "Show link previews". On by default. Off, this device never fetches a page
/// for a link another person sent: the message stays a plain text bubble.
enum LinkPreviewSetting {
    static let key = "hq-show-link-previews"
}

@MainActor
final class LinkPreviewCache {
    static let shared = LinkPreviewCache()

    struct Preview {
        let title: String
        let host: String
        var image: PlatformImage?
        var imageBytes = 0
    }

    enum State {
        case loading
        /// No usable metadata — the bubble stays a plain text link.
        case unavailable
        case loaded(Preview)
    }

    private let states = MemoryBudgetCache<State>(byteLimit: 16 * 1024 * 1024)
    private var inFlight: [String: Task<Resolved, Never>] = [:]
    /// Links that resolved to nothing. Kept apart from `states`, which evicts
    /// by count, so a dead link is not fetched again however many bubbles
    /// mount. A miss the page itself caused (no title) holds for the session; a
    /// failed fetch (offline, timeout, just after wake) is retried after
    /// `LinkFailureMemo.retryInterval`.
    private var failed = LinkFailureMemo()
    private let diskDirectory: URL
    private let fetch: @MainActor (URL) async -> LPLinkMetadata?
    private let now: @MainActor () -> Date
    /// The transcript mounts every row at once, so a chat with N distinct
    /// links would otherwise start N page fetches together. The newest
    /// request goes first, which is the row nearest the bottom.
    private let fetchLimiter: AsyncLimiter
    /// How long a fetch may hold its slot. LPMetadataProvider's own timeout
    /// is the only other bound; a fetch that never calls back must not keep
    /// a slot, or three of them would stall every later link until quit.
    private let fetchTimeout: Duration

    /// `fetch` is the network step; tests replace it. LPMetadataProvider is
    /// single-shot and wants the main thread, hence `@MainActor`.
    init(
        diskDirectory: URL? = nil,
        fetch: (@MainActor (URL) async -> LPLinkMetadata?)? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        fetchLimit: Int = 3,
        fetchTimeout: Duration = .seconds(15)
    ) {
        self.now = now
        self.fetchLimiter = AsyncLimiter(limit: fetchLimit)
        self.fetchTimeout = fetchTimeout
        self.diskDirectory = diskDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(HQIdentity.bundleID)/link-previews", isDirectory: true)
        self.fetch = fetch ?? { url in
            let provider = LPMetadataProvider()
            provider.timeout = 10
            return await Self.fetchMetadata(for: url, with: provider)
        }
    }

    /// The default fetch, given its provider so a test can stand in for it.
    /// The provider's async call does not watch `Task.cancel`, so a cancel
    /// is passed on to it: past `fetchTimeout` the race cancels this task,
    /// and without that the provider would keep fetching until it called
    /// back on its own. The race cancels on the main actor, so `cancel()`
    /// runs there.
    static func fetchMetadata(
        for url: URL, with provider: some LinkMetadataProviding
    ) async -> LPLinkMetadata? {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return try? await provider.startFetchingMetadata(for: url)
        } onCancel: {
            provider.cancel()
        }
    }

    /// The preview already in memory, if any: a bubble can start from it
    /// instead of showing the plain link for a frame.
    func cachedPreview(for url: URL) -> Preview? {
        guard case .loaded(let preview)? = states.value(for: url.absoluteString) else { return nil }
        return preview
    }

    func state(for url: URL) async -> State {
        let key = url.absoluteString
        if let known = states.value(for: key) { return known }
        if failed.isRemembered(key, at: now()) { return .unavailable }
        if let running = inFlight[key] { return await running.value.state }
        let load = Task { await resolve(url, key: key) }
        inFlight[key] = load
        defer { inFlight[key] = nil }
        let result = await load.value
        switch result.state {
        case .loaded(let preview):
            states.insert(result.state, for: key, cost: preview.imageBytes)
        case .unavailable:
            // Not in `states`: that cache would hand a transient miss back
            // forever. The memo owns "nothing here", and when to look again.
            failed.record(key, transient: result.transient, at: now())
        case .loading:
            break
        }
        return result.state
    }

    private struct Resolved {
        let state: State
        /// The fetch itself failed, so a later look may succeed.
        var transient = false
    }

    private func resolve(_ url: URL, key: String) async -> Resolved {
        let file = diskURL(key: key)
        if let cached = await Self.loadFromDisk(file) {
            return Resolved(state: await built(from: cached.metadata, url: url))
        }
        do { try await fetchLimiter.acquire() } catch { return Resolved(state: .unavailable, transient: true) }
        let fetched = await boundedFetch(url)
        fetchLimiter.release()
        guard let metadata = fetched else { return Resolved(state: .unavailable, transient: true) }
        // Built first, archived after: `built` reads the image provider, and
        // the archive reads it too, so the two never overlap. The archive
        // works on a copy, so nothing else can change it mid-write.
        let state = await built(from: metadata, url: url)
        if let copy = metadata.copy() as? LPLinkMetadata {
            Self.saveToDisk(copy, to: file, in: diskDirectory)
        }
        return Resolved(state: state)
    }

    /// `fetch(url)`, or nil once `fetchTimeout` passes, whichever is first.
    /// Not a task group: a group waits for every child, so a fetch that
    /// ignores cancellation would hold it open. Past the bound the fetch is
    /// cancelled (the default fetch passes that on to its provider) and its
    /// answer, if one still comes, is dropped.
    private func boundedFetch(_ url: URL) async -> LPLinkMetadata? {
        @MainActor final class Race {
            var continuation: CheckedContinuation<LPLinkMetadata?, Never>?
            var fetching: Task<Void, Never>?
            var timer: Task<Void, Never>?
            /// The first answer wins; the loser is cancelled.
            func finish(_ metadata: LPLinkMetadata?) {
                continuation?.resume(returning: metadata)
                continuation = nil
                fetching?.cancel()
                timer?.cancel()
            }
        }
        let race = Race()
        let fetch = fetch
        let timeout = fetchTimeout
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.fetching = Task { @MainActor in race.finish(await fetch(url)) }
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                race.finish(nil)
            }
        }
    }

    func built(from metadata: LPLinkMetadata, url: URL) async -> State {
        guard let title = metadata.title, !title.isEmpty else { return .unavailable }
        var preview = Preview(title: title, host: url.host() ?? "", image: nil)
        // Ask for encoded bytes, not an NSImage/UIImage that may have already
        // decoded its full resolution. The same decoder serves chat photos.
        if let provider = metadata.imageProvider,
           let type = provider.registeredTypeIdentifiers.first(where: {
               UTType($0)?.conforms(to: .image) == true
           }) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data, let cgImage = await ImageDecoder.shared.thumbnail(data: data) {
                let decoded = DecodedImage(cgImage)
                preview.image = decoded.image
                preview.imageBytes = decoded.cost
            }
        }
        return .loaded(preview)
    }

    private func diskURL(key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent("\(digest).metadata")
    }

    /// LPLinkMetadata is a reference type handed between threads; the box says
    /// so to the compiler. Callers hand the archive a copy, never the object
    /// `built(from:)` is reading.
    private struct Unarchived: @unchecked Sendable { let metadata: LPLinkMetadata }

    /// Read and unarchive off the main actor (the archive embeds images).
    private nonisolated static func loadFromDisk(_ file: URL) async -> Unarchived? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: file),
                  let metadata = try? NSKeyedUnarchiver.unarchivedObject(
                      ofClass: LPLinkMetadata.self, from: data
                  ) else { return nil }
            return Unarchived(metadata: metadata)
        }.value
    }

    /// Archive and write off the main actor; nothing waits on it.
    private nonisolated static func saveToDisk(_ metadata: LPLinkMetadata, to file: URL, in directory: URL) {
        let box = Unarchived(metadata: metadata)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? NSKeyedArchiver.archivedData(
                withRootObject: box.metadata, requiringSecureCoding: true
            ) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// The two LPMetadataProvider calls the default fetch makes. `@MainActor`
/// so the fetch starts on the main thread, as a direct call from the cache
/// does; without it the witness hops to the cooperative pool first. A cancel
/// can come from any thread.
@MainActor
protocol LinkMetadataProviding: AnyObject {
    func startFetchingMetadata(for url: URL) async throws -> LPLinkMetadata
    nonisolated func cancel()
}

extension LPMetadataProvider: LinkMetadataProviding {}

/// Which links to leave alone, and until when. Pure, so the clock is an
/// argument: a deterministic miss (the page has no title) holds for the
/// session; a transient one (the fetch failed) expires, so a link that failed
/// while the network was down is tried again.
struct LinkFailureMemo {
    static let retryInterval: TimeInterval = 10 * 60

    private enum Entry { case session, until(Date) }
    private var entries: [String: Entry] = [:]

    mutating func record(_ key: String, transient: Bool, at now: Date) {
        entries[key] = transient ? .until(now.addingTimeInterval(Self.retryInterval)) : .session
    }

    mutating func isRemembered(_ key: String, at now: Date) -> Bool {
        switch entries[key] {
        case nil: return false
        case .session?: return true
        case .until(let date)?:
            if now < date { return true }
            entries[key] = nil
            return false
        }
    }
}

extension Message {
    /// The message is nothing but one http(s) link — the case Messages turns
    /// into a rich preview card instead of a text bubble.
    var soleLinkURL: URL? {
        guard !isDeleted else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}

// Built once: creating a detector compiles its patterns, and the transcript
// asks for matches on every measure pass. NSDataDetector is immutable and
// thread-safe (its NSRegularExpression contract), so one instance serves all.
private let sharedLinkDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
)

// The links a message carries, found once for both renderings of it: the
// SwiftUI string below, and the Mac bubble's AppKit text view.
func linkMatches(in string: String) -> [(range: NSRange, url: URL)] {
    guard let detector = sharedLinkDetector else { return [] }
    let fullRange = NSRange(string.startIndex..., in: string)
    return detector.matches(in: string, range: fullRange).compactMap { match in
        match.url.map { (match.range, $0) }
    }
}

/// URLs in bubble text made tappable, and `@Name` drawn as a tag. Own bubbles
/// are blue, so their links go white-underlined and their tags stay white —
/// weight alone sets those apart; incoming links and tags take the accent.
func linkified(
    _ string: String, linkColor: Color, names: [String] = [], mentionColor: Color? = nil
) -> AttributedString {
    ChatMarkdown.render(string, names: names)
        .attributed(linkColor: linkColor, mentionColor: mentionColor ?? linkColor)
}

// The card: hero image when the page offers one, then title over host, sized
// like an image bubble. Click opens the browser; the row's context menu still
// carries Copy for the raw URL.
struct LinkPreviewCard: View {
    @Environment(\.openURL) private var openURL
    let url: URL
    let preview: LinkPreviewCache.Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = preview.image {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Tokens.LinkCard.width, height: Tokens.LinkCard.imageHeight)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title)
                    .font(Tokens.LinkCard.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(preview.host)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: Tokens.LinkCard.width, alignment: .leading)
        }
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { openURL(url) }
        .help(url.absoluteString)
    }
}
