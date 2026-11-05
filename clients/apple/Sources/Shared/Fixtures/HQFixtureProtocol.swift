#if DEBUG && (os(macOS) || targetEnvironment(simulator))
    import Foundation

    /// This transport handles every request itself; unknown routes fail locally.
    /// It cannot fall through to the network, including uploads and downloads.
    class HQFixtureProtocol: URLProtocol {
        static var contentMode = ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] ?? "ready"
        /// Comments posted during a fixture run, by "tasks/<id>" or
        /// "projects/<id>", so a composer's send reads back like a hub's.
        static var postedComments: [String: [HQComment]] = [:]
        /// The board as this run has changed it — dragged cards, new cards —
        /// so a drop reads back the way a server's does. Nil until the first
        /// write; the scenario's own rows until then.
        static var board: (tasks: [TeamTask], projects: [Project])?
        static let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HQFixtureProtocol.self]
            return URLSession(configuration: configuration)
        }()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        /// `HQ_UI_REQUEST_LOG=<file>` appends "METHOD /path" per request, so a
        /// fixture run can count what a page asked the hub for.
        private static let requestLog = ProcessInfo.processInfo.environment["HQ_UI_REQUEST_LOG"]
            .flatMap { path -> FileHandle? in
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }
        private static let requestLogLock = NSLock()

        override func startLoading() {
            guard let url = request.url else { return }
            if let log = Self.requestLog {
                Self.requestLogLock.withLock {
                    log.seekToEndOfFile()
                    log.write(Data("\(request.httpMethod ?? "GET") \(url.path)\n".utf8))
                }
            }
            do {
                let payload = try response(for: url.path)
                let data = try JSONSerialization.data(withJSONObject: payload)
                guard
                    let response = HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        private func json(_ value: some Encodable) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }

        private func requestJSON() throws -> [String: Any] {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }

        /// `/v1/tasks/:id/comments` and `/v1/projects/:id/comments`: the
        /// Projects fixture's activity, plus whatever this run has posted.
        private func commentsResponse(for path: String) throws -> [String: Any]? {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "v1", parts[3] == "comments",
                parts[1] == "tasks" || parts[1] == "projects"
            else { return nil }
            let key = parts[1] + "/" + parts[2]
            if request.httpMethod == "POST" {
                let body = try requestJSON()
                let comment = HQComment(
                    id: "posted-\(UUID().uuidString)", authorName: "Ada", authorPersonId: "ada",
                    body: body["body"] as? String ?? "", createdAt: ISO8601DateFormatter().string(from: Date()))
                Self.postedComments[key, default: []].append(comment)
                return ["comment": try json(comment)]
            }
            let posted = Self.postedComments[key] ?? []
            if parts[1] == "projects" {
                return ["comments": try json(HQProjectsFixture.comments(forProject: parts[2]) + posted)]
            }
            return ["comments": try json(HQProjectsFixture.comments(forTask: parts[2]) + posted)]
        }

        /// The server's list order: open first, then the hand order.
        private static func listed(_ tasks: [TeamTask]) -> [TeamTask] {
            tasks.filter { $0.status == "open" } + tasks.filter { $0.status != "open" }
        }

        // One case per board write, beside the hub route it stands in for.
        // swiftlint:disable cyclomatic_complexity discouraged_optional_collection
        /// The board's writes, done the server's way on the fixture's own rows:
        /// a status PATCH, `POST /v1/tasks/:id/order` (the whole list back)
        /// and a new card. A live-app drag in the `projects` scenario lands
        /// and stays.
        private func boardResponse(for path: String, fixture: HQSimulatorFixture) throws -> [String: Any]? {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == "v1", ["tasks", "projects"].contains(parts[1]) else { return nil }
            let method = request.httpMethod ?? "GET"
            var tasks = Self.board?.tasks ?? fixture.tasks
            let projects = Self.board?.projects ?? fixture.projects
            defer { Self.board = (Self.listed(tasks), projects) }
            switch (method, parts.count, parts[1], parts.last ?? "") {
            case ("PATCH", 3, "tasks", _):
                let body = try requestJSON()
                guard let index = tasks.firstIndex(where: { $0.id == parts[2] }) else { return nil }
                guard let status = body["status"] as? String else { return nil }
                // The server's rule: a done task leaves done only by reopening.
                if tasks[index].status != "done" || ["open", "done"].contains(status) {
                    tasks[index] = tasks[index].moved(to: status)
                }
                return ["task": try json(tasks[index])]
            case ("POST", 4, "tasks", "order"):
                let body = try requestJSON()
                let anchor = (body["after_task_id"] ?? body["before_task_id"]) as? String
                let isAfter = body["after_task_id"] != nil
                guard let from = tasks.firstIndex(where: { $0.id == parts[2] }), let anchor else { return nil }
                let moving = tasks.remove(at: from)
                let at = tasks.firstIndex { $0.id == anchor } ?? from
                tasks.insert(moving, at: isAfter && at < tasks.count ? at + 1 : at)
                return ["tasks": try json(Self.listed(tasks))]
            case ("POST", 2, "tasks", _):
                let body = try requestJSON()
                let owner = body["owner_person_id"] as? String ?? "ada"
                let number = (tasks.compactMap(\.number).max() ?? 1_000) + 1
                let task = TeamTask(
                    id: "task-\(number)", number: number, title: body["title"] as? String ?? "", status: "open",
                    ownerPersonId: owner, ownerName: fixture.people.first { $0.id == owner }?.name ?? "Ada",
                    createdByPersonId: "ada", createdAt: ISO8601DateFormatter().string(from: Date()),
                    projectId: body["project_id"] as? String, touchedAt: ISO8601DateFormatter().string(from: Date()))
                tasks.append(task)
                return ["task": try json(task)]
            case ("GET", 2, "tasks", _):
                return ["tasks": try json(Self.listed(tasks))]
            case ("GET", 2, "projects", _):
                return ["projects": try json(projects), "planning": true,
                        "open_transcripts": HQCodingThreadsFixture.opensTranscripts]
            default:
                return nil
            }
        }
        // swiftlint:enable cyclomatic_complexity discouraged_optional_collection

        // A declarative route table keeps fixture responses beside their endpoints.
        // swiftlint:disable:next cyclomatic_complexity
        private func response(for path: String) throws -> [String: Any] {
            let fixture = HQSimulatorFixture()
            let mode = Self.contentMode
            if mode == "error" { throw URLError(.notConnectedToInternet) }
            let isEmpty = mode == "empty"
            if request.httpMethod == "POST", path.hasSuffix("/messages"), path.contains("/conversations/") {
                let body = try requestJSON()
                let id = path.split(separator: "/").dropLast().last.map(String.init) ?? "studio"
                let message = Message(
                    id: "sent-" + (body["client_msg_id"] as? String ?? "fixture"), conversationId: id,
                    senderPersonId: "ada", senderName: "Ada", content: body["content"] as? String ?? "",
                    createdAt: "2026-09-14T03:00:00Z",
                    replyTo: (body["reply_to_message_id"] as? String).map {
                        ReplyStub(id: $0, content: "Original message", senderName: "Bo")
                    },
                    attachments: (body["attachment_ids"] as? [String] ?? []).compactMap { id in
                        Attachment(id: id, fileName: "Room plan.pdf", contentType: "application/pdf",
                                   byteSize: 2048, width: nil, height: nil)
                    }
                )
                return ["message": try json(message)]
            }
            if let threads = HQCodingThreadsFixture.response(path, query: request.url?.query, empty: isEmpty) { return threads }
            let query = Dictionary(
                (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            _ = query
            if let settings = try HQSettingsFixture.response(
                path: path, method: request.httpMethod ?? "GET", empty: isEmpty
            ) {
                return settings
            }
            if let comments = try commentsResponse(for: path) { return comments }
            if !isEmpty, HQSimulatorFixture.isProjects, let board = try boardResponse(for: path, fixture: fixture) {
                return board
            }
            switch path {
            case "/v1/people": return ["people": try json(fixture.people)]
            case "/v1/conversations": return ["conversations": try json(fixture.conversations)]
            case "/v1/calls": return ["calls": try json(fixture.calls), "meetings": [], "ringing": []]
            case "/v1/tasks": return ["tasks": isEmpty ? [] : try json(fixture.tasks)]
            case "/v1/projects":
                return ["projects": isEmpty ? [] : try json(fixture.projects), "planning": true,
                        "open_transcripts": HQCodingThreadsFixture.opensTranscripts]
            case "/v1/library":
                return [
                    "folders": isEmpty
                        ? [] : [["id": "garden", "name": "Garden references", "created_at": "2026-09-14T02:00:00Z"]]
                ]
            case "/v1/files": return ["files": []]
            case "/v1/documents":
                return [
                    "documents": isEmpty
                        ? []
                        : [
                            [
                                "slug": "workshop-notes", "title": "Workshop planning notes",
                                "updated_at": "2026-09-14T02:00:00Z", "updated_by_name": "Bo",
                            ],
                            [
                                "slug": "seed-list", "title": "Seed list", "folder_id": "garden",
                                "updated_at": "2026-09-13T18:00:00Z", "updated_by_name": "Cy",
                            ],
                            [
                                "slug": "bed-layout", "title": "Bed layout", "folder_id": "garden",
                                "updated_at": "2026-09-12T09:00:00Z", "updated_by_name": "Bo",
                            ],
                        ]
                ]
            case "/v1/documents/workshop-notes":
                return [
                    "document": [
                        "slug": "workshop-notes", "title": "Workshop planning notes",
                        "content":
                            "# Workshop planning\n\nKeep the schedule short.\n\n## Checklist\n\n"
                            + "- Book the room for every evening\n- Order enough clay for twelve people",
                        "updated_at": "2026-09-14T02:00:00Z", "updated_by_name": "Bo",
                    ]
                ]
            case "/v1/search":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "q" }?.value ?? ""
                let matches = (fixture.messages["studio"] ?? []).filter {
                    $0.previewText.localizedCaseInsensitiveContains(query)
                }
                return ["messages": isEmpty ? [] : try json(matches)]
            default:
                if path.hasSuffix("/messages"), path.contains("/conversations/") {
                    if request.url?.query?.contains("before=") == true { return ["messages": []] }
                    // The room's own transcript; a conversation the fixture
                    // never seeded reads as the studio room.
                    let id = path.split(separator: "/").dropLast().last.map(String.init) ?? "studio"
                    return ["messages": try json(fixture.messages[id] ?? fixture.messages["studio"] ?? [])]
                }
                if path.hasSuffix("/read") { return ["last_read_message_id": "m3"] }
                if path.hasSuffix("/decline") || path.hasSuffix("/leave") { return ["ok": true] }
                throw URLError(.resourceUnavailable)
            }
        }
    }
#endif
