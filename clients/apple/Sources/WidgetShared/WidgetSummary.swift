import Foundation

/// One person's desktop-widget snapshot, as `GET /v1/widgets/summary` sends it
/// (docs/widgets.md). The server finishes every number; the widgets only lay
/// it out.
struct WidgetSummary: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: Date
    var me: Me
    var work: Work

    struct Me: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var avatarId: String?
    }

    /// The tasks this person owes: counts for every one, and a few cards of each status.
    struct Work: Codable, Equatable, Sendable {
        var inProgress: Int
        var open: Int
        var blocked: Int
        var doneWeek: Int
        var nextDue: WorkTask?
        var tasks: [WorkTask]

        var total: Int { inProgress + open + blocked }
    }

    struct WorkTask: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var number: Int?
        /// "HQ-<number>", the way the app's task cards name a task.
        var ref: String?
        var title: String
        var status: String
        var projectName: String?
        var commentCount: Int
        var dueAt: Date?
        var touchedAt: Date

        var isBlocked: Bool { status == "blocked" }
        var isInProgress: Bool { status == "in_progress" }
    }
}

extension WidgetSummary {
    /// Whether these are the tasks of the person the saved key belongs to. With no key there is nobody.
    func belongs(to credentials: WidgetShelf.Credentials?) -> Bool {
        credentials?.personId == me.id
    }

    /// The server's ISO dates carry milliseconds, which `.iso8601` refuses.
    static func decode(_ data: Data) throws -> WidgetSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = WidgetDates.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not an ISO date: \(text)"))
        }
        return try decoder.decode(WidgetSummary.self, from: data)
    }
}

enum WidgetDates {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }
}

/// Where a widget row opens HQ: `hq://task/<id>` is one task's card, `hq://mine` the board.
/// (`hq://thread/<id>` belongs to the Agents page and is read elsewhere.)
enum WidgetLink: Equatable {
    case task(String)
    case mine

    var url: URL {
        switch self {
        case .task(let id): URL(string: "hq://task/\(id)") ?? WidgetLink.mine.url
        case .mine: URL(string: "hq://mine")!
        }
    }

    init?(url: URL) {
        guard url.scheme == "hq", url.query == nil, url.fragment == nil, let host = url.host else { return nil }
        let id = String(url.path.dropFirst())
        let isId = id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
        switch (host, isId) {
        case ("task", true): self = .task(id)
        case ("mine", false) where id.isEmpty: self = .mine
        default: return nil
        }
    }
}
