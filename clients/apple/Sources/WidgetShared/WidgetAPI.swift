import Foundation

/// `/v1/widgets` over one bearer: HQ.app's device bearer or the extension's
/// widget key. The server answers both the summary; only a device bearer mints
/// a key or reads people's pictures.
struct WidgetAPI: Sendable {
    let baseURL: URL
    let bearer: String

    struct Failure: Error, LocalizedError {
        let status: Int
        let code: String
        var errorDescription: String? { "Request failed (\(code), HTTP \(status))." }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL, bearer: String) {
        self.baseURL = baseURL
        self.bearer = bearer
    }

    init?(credentials: WidgetShelf.Credentials) {
        guard let url = URL(string: credentials.baseURL) else { return nil }
        self.init(baseURL: url, bearer: credentials.key)
    }

    /// The summary and the bytes it came in, which the shelf keeps as they are.
    func summary() async throws -> (WidgetSummary, Data) {
        let data = try await send("GET", "/v1/widgets/summary")
        return (try WidgetSummary.decode(data), data)
    }

    func mintKey() async throws -> String {
        struct Minted: Decodable { let key: String }
        return try JSONDecoder().decode(Minted.self, from: try await send("POST", "/v1/widgets/key")).key
    }

    func revokeKey() async throws {
        _ = try await send("DELETE", "/v1/widgets/key")
    }

    /// A person's current picture (device bearer only).
    func avatar(personId: String, avatarId: String) async throws -> Data {
        try await send("GET", "/v1/avatars/people/\(personId)/\(avatarId)")
    }

    /// Any other path with this bearer: a test uses it to see what a widget key is refused.
    func request(_ method: String, _ path: String) async throws -> Data {
        try await send(method, path)
    }

    /// `path` under the server's address, keeping any path the address has: a server at
    /// `https://example.org/hq` is asked at `https://example.org/hq/v1/…`, as `HQConfig.url(path:)` does.
    static func url(base: URL, path: String) -> URL? {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + path)
    }

    private func send(_ method: String, _ path: String) async throws -> Data {
        guard let url = Self.url(base: baseURL, path: path) else { throw Failure(status: 0, code: "bad_url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(status: status, code: code ?? "unknown")
        }
        return data
    }
}
