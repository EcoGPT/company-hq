import Foundation

/// Who this build is. Everything the app names on the system (the Keychain service, the log
/// subsystem, cache folders, the preferences suite) comes from the bundle id, which
/// `Config/Signing.xcconfig` sets, so a fork never shares state with another build.
enum HQIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "hq"
    static let logSubsystem = bundleID
}

/// Which server the app talks to. There is no default: the sign-in screen asks for one and the
/// last value is remembered.
enum HQConfig {
    /// What makes the Server field unusable.
    struct ServerProblem: Error, Equatable {
        let message: String
    }

    /// The preferences key holding the last server. `defaults write <bundle id> HQBaseURL <url>`
    /// sets it without the sign-in screen (for example from a script).
    static let serverDefaultsKey = "HQBaseURL"

    /// The remembered server, or nil when none was ever entered.
    static var savedServer: String? {
        get {
            let value = UserDefaults.standard.string(forKey: serverDefaultsKey)
            return value?.isEmpty == false ? value : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: serverDefaultsKey) }
    }

    /// Empty until a server has been entered; callers surface the resulting request failure.
    static var baseURLString: String {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled { return "https://hq-ui-fixture.invalid" }
        #endif
        return savedServer ?? ""
    }

    // Nil when no server is set or it holds something unparseable; callers
    // surface that as a request failure rather than crashing on a bad string.
    static func url(path: String) -> URL? {
        URL(string: baseURLString + path)
    }

    /// Plain http is for a server on this machine or this network only.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
    }

    /// What the Server field holds, as the base URL the app will use: `https` unless the host is
    /// local (`localhost`, `127.0.0.1`, `*.local`), no trailing slash. A bare host gets the
    /// scheme it would need (`hq.example.com` is `https://hq.example.com`).
    static func normalizedServer(_ input: String) -> Result<String, ServerProblem> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ServerProblem(message: "Enter your server address.")) }
        var candidate = trimmed
        if !trimmed.contains("://") {
            // A bare host: take the scheme it would need.
            let authority = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
            let bareHost = authority.split(separator: ":").first.map(String.init) ?? authority
            candidate = (isLocalHost(bareHost) ? "http://" : "https://") + trimmed
        }
        guard var components = URLComponents(string: candidate), let host = components.host, !host.isEmpty,
              components.scheme == "https" || components.scheme == "http"
        else { return .failure(ServerProblem(message: "That is not a server address.")) }
        if components.scheme == "http", !isLocalHost(host) {
            return .failure(ServerProblem(
                message: "Use https:// for your server. Plain http is only allowed for localhost, 127.0.0.1 and .local hosts."))
        }
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string.map { .success($0) } ?? .failure(ServerProblem(message: "That is not a server address."))
    }

    /// Whether `url` points at the server this app is signed in to: the same scheme and host.
    static func isServerURL(_ url: URL) -> Bool {
        url.scheme == URLComponents(string: baseURLString)?.scheme && isServerHost(url.host)
    }

    /// Whether `host` is the server this app is signed in to. Links the server writes (a task's
    /// link, a rich timestamp) are only trusted on that host.
    static func isServerHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(),
              let server = URLComponents(string: baseURLString)?.host?.lowercased()
        else { return false }
        return host == server
    }

    /// What a session and a cache belong to. A bearer is minted by one hub,
    /// so a session enrolled against one server must not overwrite another's
    /// in the same Keychain item.
    static var storeSuffix: String {
        guard let components = URLComponents(string: baseURLString), let host = components.host else { return "" }
        let port = components.port.map { ":\($0)" } ?? ""
        return "@" + host + port
    }

    static var webSocketURL: URL? {
        webSocketURL(path: "/v1/ws")
    }

    static func webSocketURL(path: String) -> URL? {
        guard var components = URLComponents(string: baseURLString) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path += path
        return components.url
    }
}
