#if DEBUG && (os(macOS) || targetEnvironment(simulator))
    import Foundation

    /// The server's answers for Settings' cards in the `settings` scenarios:
    /// invented people and plainly fake values. `empty` answers every list
    /// with nothing, so the empty states can be checked too.
    enum HQSettingsFixture {
        /// `HQ_UI_SETTINGS_ROLE=member` signs the fixture in as a member: no
        /// Admin page.
        static var isMember: Bool { ProcessInfo.processInfo.environment["HQ_UI_SETTINGS_ROLE"] == "member" }
        /// `HQ_UI_SETTINGS_FAIL=mcp-keys` fails that list read as if offline,
        /// to show a card's error line.
        private static let failing = Set(
            (ProcessInfo.processInfo.environment["HQ_UI_SETTINGS_FAIL"] ?? "").split(separator: ",").map(String.init))
        private static let day = 86_400_000
        private static let now = 1_789_351_200_000

        // One case per Settings route, beside the server route it stands in for.
        static func response(path: String, method: String, empty: Bool) throws -> [String: Any]? {
            let parts = path.split(separator: "/").map(String.init)
            if method == "GET", parts.count == 2, failing.contains(parts[1]) { throw URLError(.notConnectedToInternet) }
            switch (method, path) {
            case ("GET", "/v1/mcp-keys"):
                return ["keys": empty ? [] : mcpKeys]
            case ("POST", "/v1/mcp-keys"):
                return ["id": "mcp-new", "key": "hq_mcp_v1_FIXTURE-NOT-A-REAL-KEY", "label": "New key"]
            case ("POST", "/v1/keys"):
                return ["ok": true, "person_name": "Teammate", "key": "FIXTURE-INVITE-KEY"]
            default:
                break
            }
            if method == "DELETE", parts.count == 3, parts[1] == "mcp-keys" { return ["ok": true] }
            return nil
        }

        private static let mcpKeys: [[String: Any]] = [
            ["id": "mcp-1", "label": "Work laptop", "scopes": "read,send", "created_at": now - 30 * day,
             "revoked_at": NSNull(), "last_used_at": now - 3 * 60_000],
            ["id": "mcp-2", "label": "Home desktop", "scopes": "read,send", "created_at": now - 9 * day,
             "revoked_at": NSNull(), "last_used_at": NSNull()],
        ]
    }
#endif
