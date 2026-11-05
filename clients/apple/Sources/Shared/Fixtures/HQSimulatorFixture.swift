#if DEBUG && (os(macOS) || targetEnvironment(simulator))
    import Foundation

    /// Launch with SIMCTL_CHILD_HQ_UI_SCENARIO=call (or chat/tasks/meetings/files/settings/list/projects).
    /// This data never reaches a live server. `projects` seeds the Projects
    /// mock's data (`HQProjectsFixture`) and reads `HQ_UI_ROUTE` for its screen.
    struct HQSimulatorFixture {
        static var scenario: String {
            ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
                ?? Bundle.main.object(forInfoDictionaryKey: "HQUIPreview") as? String ?? ""
        }
        static var isEnabled: Bool { !scenario.isEmpty }
        static var isProjects: Bool { scenario == "projects" }
        /// The Projects page `HQ_UI_ROUTE` names; nil is the home grid.
        static var route: ProjectsRoute? { HQProjectsFixture.route }
        var people: [Person] { Self.isProjects ? HQProjectsFixture.people : basePeople }
        private let basePeople = [
            Person(id: "ada", name: "Ada", kind: "person", isAdmin: true, avatarId: nil, removedAt: nil),
            Person(id: "bo", name: "Bo", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil),
            Person(id: "scout", name: "Scout", kind: "bot", isAdmin: false, avatarId: nil, removedAt: nil),
        ]
        private let date = "2026-09-14T02:00:00Z"
        var messages: [String: [Message]] {
            if ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "imessage" {
                let lines: [(String, String)] = [
                    ("ada", "That sounds good"),
                    ("bo", "I've been looking through the garden plans. The beds should feel familiar, with the same spacing as last year."),
                    ("ada", "Yeah, exactly"),
                    ("ada", "Can you send the updated sketch when it's ready?"),
                    ("bo", "The seed order too?"),
                    ("ada", "Yes, that one as well"),
                    ("bo", "On it"),
                ]
                return ["studio": lines.enumerated().map { index, line in
                    Message(id: "parity-\(index)", conversationId: "studio", senderPersonId: line.0,
                            senderName: line.0 == "ada" ? "Ada" : "Bo", content: line.1,
                            createdAt: index < 3 ? "2026-09-29T10:00:00Z" : "2026-09-29T11:08:00Z")
                }]
            }
            if ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "long-chat" {
                return ["studio": (1...40).map { index in
                    Message(
                        id: String(format: "keyboard-%03d", index), conversationId: "studio",
                        senderPersonId: index.isMultiple(of: 2) ? "ada" : "bo",
                        senderName: index.isMultiple(of: 2) ? "Ada" : "Bo",
                        content: index == 40 ? "Latest message — keep this visible above the keyboard."
                            : "Message \(index): Going over the plan for the spring workshop.",
                        createdAt: date
                    )
                }]
            }

            if ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "image-unavailable" {
                return ["studio": [Message(id: "image-missing", conversationId: "studio", senderPersonId: "bo", senderName: "Bo",
                    content: "Photo attachment", createdAt: date,
                    attachments: [Attachment(id: "unavailable-photo", fileName: "Landscape.png", contentType: "image/png",
                        byteSize: 2468000, width: 1600, height: 900)])]]
            }
            if ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "attachments" {
                return ["studio": [
                    Message(id: "file-incoming", conversationId: "studio", senderPersonId: "bo", senderName: "Bo",
                            content: "The workshop notes are attached.", createdAt: date,
                            attachments: [Attachment(id: "notes-file", fileName: "Workshop planning — spring notes.md",
                                contentType: "text/markdown", byteSize: 8192, width: nil, height: nil)]),
                    Message(id: "file-outgoing", conversationId: "studio", senderPersonId: "ada", senderName: "Ada",
                            content: "Here is the revised room plan.", createdAt: date,
                            attachments: [Attachment(id: "layout-file", fileName: "Room plan — final version.pdf",
                                contentType: "application/pdf", byteSize: 2468000, width: nil, height: nil)]),
                ]]
            }
            var seeded: [String: [Message]] = [
                "studio": [
                    Message(
                        id: "m1", conversationId: "studio", senderPersonId: "bo", senderName: "Bo",
                        content:
                            "Let's plan the spring workshop series. "
                        + "The sign-up form should stay easy to find on the home page.",
                        createdAt: date),
                    Message(
                        id: "m2", conversationId: "studio", senderPersonId: "ada", senderName: "Ada",
                        content: "I'll check the room booking, the supplies and the flyers too.", createdAt: date,
                        reactions: [Reaction(emoji: "👍", personIds: ["bo"])]),
                    Message(
                        id: "m3", conversationId: "studio", senderPersonId: "scout", senderName: "Scout",
                        content:
                            "**Planning notes**\n\nKeep the schedule short and the sign-up easy to reach.\n\n"
                        + "• Pottery and weaving each need their own evening.\n"
                        + "• Long titles should wrap without hiding the date.",
                        createdAt: date),
                ],
            ]
            // `HQ_UI_CONTENT=code`: the default room plus an answer in Markdown
            // (inline code, a fenced block, strikethrough) and a short reply,
            // for judging how code and strikethrough read in a bubble.
            if ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "code" {
                seeded["studio"]?.append(contentsOf: [
                    Message(
                        id: "m4", conversationId: "studio", senderPersonId: "scout", senderName: "Scout",
                        content: """
                            Run `make site` first, then check the pages on their own:

                            ```
                            make site

                            make check-links
                            ```

                            The old ~~manual upload~~ step is gone, and **`HQ_UI_OPAQUE=1`** still works.
                            """,
                        createdAt: date),
                    Message(
                        id: "m5", conversationId: "studio", senderPersonId: "ada", senderName: "Ada",
                        content: "Thanks, `check-links` passes and ~~the slow path~~ is deleted.",
                        createdAt: date),
                ])
            }
            return seeded
        }
        var conversations: [Conversation] {
            let base = [
                Conversation(
                    id: "studio", kind: ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "imessage" ? "dm" : "group",
                    title: ProcessInfo.processInfo.environment["HQ_UI_CONTENT"] == "imessage" ? "Bo" : "Spring workshop planning",
                    memberIds: ["ada", "bo", "scout"], createdAt: date, lastMessage: messages["studio"]?.last,
                    unreadCount: 2),
                Conversation(
                    id: "bo-dm", kind: "dm", title: nil, memberIds: ["ada", "bo"], createdAt: date, lastMessage: nil,
                    unreadCount: 0),
                Conversation(
                    id: "updates", kind: "group", title: "Updates", memberIds: ["ada", "scout"], createdAt: date,
                    lastMessage: nil, unreadCount: 0, roomSlug: "updates"),
                Conversation(
                    id: "scout-dm", kind: "dm", title: nil, memberIds: ["ada", "scout"], createdAt: date, lastMessage: nil,
                    unreadCount: 0),
            ]
            guard ["home", "pins"].contains(Self.scenario) else { return base }
            let titles = [
                "Garden club", "Book swap", "Potluck planning", "Open studio night", "Newsletter", "Volunteers", "Photo walk",
            ]
            return base + titles.enumerated().map { index, title in
                let id = "home-\(index)"
                let message = Message(
                    id: "home-message-\(index)", conversationId: id, senderPersonId: "bo", senderName: "Bo",
                    content: [
                        "The seedlings are ready to pick up.", "Can we swap books on Saturday morning?",
                        "See you at 12:30!", "I've added the supply list for the next session.",
                        "Here are the photos from last week.",
                        "Let's start with the sign-up sheet.",
                        "The route map is in the shared folder.",
                    ][index], createdAt: "2026-09-\(String(format: "%02d", 13 - index))T18:00:00Z"
                )
                return Conversation(
                    id: id, kind: "group", title: title, memberIds: ["ada", "bo", "scout"], createdAt: date,
                    lastMessage: message, unreadCount: index == 1 ? 1 : 0
                )
            }
        }
        var calls: [Call] {
            [
                Call(
                    id: "ada-call", conversationId: "studio", kind: "meeting", meetingId: nil, title: "Quick Call",
                    startedByPersonId: "bo", startedAt: date, endedAt: nil,
                    participants: people.map { person in
                        CallParticipant(
                            deviceId: person.id == "ada" ? "ada-device" : person.id, personId: person.id, sessionId: nil,
                            isMuted: false, isCameraOn: false, isScreenSharing: false, isHandRaised: false,
                            joinedAt: date, leftAt: nil)
                    }, tracks: [])
            ]
        }
        var projects: [Project] {
            if Self.isProjects { return HQProjectsFixture.projects }
            return ["Product", "Operations", "Marketing"].enumerated().map { index, category in
                var project = Project(id: "project-\(index)", name: ["Website refresh", "Venue and supplies", "Newsletter"][index],
                    body: nil, ownerPersonId: index == 0 ? "bo" : "ada", ownerName: index == 0 ? "Bo" : "Ada",
                    status: "active", openTasks: index == 0 ? 2 : 0, createdAt: date, closedAt: nil)
                project.planningCategory = category
                project.planningState = index == 2 ? "Backlog" : "Now"
                return project
            }
        }
        var tasks: [TeamTask] {
            if Self.isProjects { return HQProjectsFixture.tasks }
            return ["open", "in_progress", "blocked", "done"].enumerated().map { index, status in
                TeamTask(
                    recurrence: nil, nextTaskId: nil, id: "task-\(index)",
                    title: [
                        "Order the seed packets", "Check the long names in the sign-up list",
                        "Confirm the room booking", "Print the flyers",
                    ][index],
                    body: "Check the page in light and dark appearance, with larger text and the keyboard visible.",
                    status: status, ownerPersonId: "ada", ownerName: "Ada", dueAt: nil, originConversationId: "studio",
                    createdByPersonId: "ada", createdAt: date, resolvedByPersonId: nil, resolvedAt: status == "done" ? ISO8601DateFormatter().string(from: Date()) : nil, projectId: index < 2 ? "project-0" : nil)
            }
        }
    }
#endif
