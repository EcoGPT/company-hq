import Foundation

/// The board's one save path: every write runs after the one before it has
/// finished, in the order they were asked for, and the board is re-read once
/// when the queue goes quiet after at least one write landed. A second card
/// typed, or a status clicked, while a write is in flight waits its turn
/// instead of being dropped.
@MainActor final class ProjectsWriteQueue {
    private var tail: Task<Void, Never>?
    private var pending = 0
    private var owesRefresh = false
    /// Each row's latest answer from a write in this burst, by kind and id.
    private var answers: [String: Any] = [:]

    /// `write` runs after every earlier write has finished. A failure calls
    /// `onFailure` and the queue moves on.
    func enqueue(
        _ write: @escaping () async throws -> Void,
        onFailure: @escaping (Error) -> Void,
        refresh: @escaping () async -> Void
    ) {
        let previous = tail
        pending += 1
        tail = Task { @MainActor in
            await previous?.value
            do {
                try await write()
                owesRefresh = true
            } catch {
                onFailure(error)
            }
            pending -= 1
            if pending == 0 {
                if owesRefresh {
                    owesRefresh = false
                    await refresh()
                }
                // The refresh read the hub after every write landed, so the
                // store's copy is current again.
                answers.removeAll()
            }
        }
    }

    /// Keeps a write's answer for the rest of the burst: the store's copy can
    /// be put back to an older one before the next write runs (a refresh read
    /// before this write landed, a failed drag's snapshot, a late `tasks`
    /// frame), and a write built from that would undo this one.
    ///
    /// Known: a coding thread's links are not held here but in each card's
    /// thread section, so relinking one thread from two cards in one burst
    /// can build the second write from the older list; and while a burst
    /// runs, a held answer hides a teammate's edit to that row until the
    /// queue is idle and has refreshed.
    func hold<Row: Identifiable>(_ row: Row) where Row.ID == String {
        answers[Self.key(Row.self, row.id)] = row
    }

    /// Drops a row's held answer: a write that skips the queue (a board drag
    /// or Move To) changed it, so the store's copy is the newer one.
    func forget<Row>(_: Row.Type, id: String) { answers[Self.key(Row.self, id)] = nil }

    /// The row as a write in this burst last got it back, if one wrote it.
    func held<Row>(_: Row.Type, id: String) -> Row? { answers[Self.key(Row.self, id)] as? Row }

    private static func key<Row>(_: Row.Type, _ id: String) -> String { "\(Row.self)/\(id)" }

    /// The row a queued write starts from: the answer a write in this burst
    /// got back, else `rows` (the store's).
    func latest<Row: Identifiable>(_ id: String, in rows: [Row]) -> Row? where Row.ID == String {
        held(Row.self, id: id) ?? rows.first { $0.id == id }
    }

    /// Test seam: returns once everything queued so far (and its refresh) is done.
    func idle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }
}

/// A card's queued writes, worked out when their turn comes rather than at the
/// click: each reads the card as the store holds it then (`latest`, falling
/// back to the card as shown) and hands the hub's answer back (`apply`), so the
/// next write in a burst starts from this one instead of undoing it.
@MainActor enum ProjectsTaskWrite {
    /// The card's linked boards, changed by `change` (one added or removed).
    /// The hub replaces the whole list, so the list is built here.
    static func links(
        of task: TeamTask, _ change: ([String]) -> [String],
        latest: (String) -> TeamTask?,
        send: ([String]) async throws -> TeamTask,
        apply: (TeamTask) -> Void
    ) async throws {
        let current = latest(task.id) ?? task
        apply(try await send(change(current.associatedProjectIds)))
    }

    /// The card moved to `status`. The writes depend on where it stands (a done
    /// card is reopened first), so they are worked out from the card now.
    static func status(
        of task: TeamTask, to status: String,
        latest: (String) -> TeamTask?,
        send: (String) async throws -> TeamTask,
        apply: (TeamTask) -> Void
    ) async throws {
        let current = latest(task.id) ?? task
        for write in ProjectsModel.statusWrites(from: ProjectsModel.list(of: current), to: status) {
            apply(try await send(write))
        }
    }

    /// Delete Card: the panel closes at the click, and only the delete waits
    /// its turn, so a delete held behind a slow write never closes the panel
    /// opened after it. A card the hub no longer has (a second click on
    /// Delete) counts as deleted.
    static func delete<Client>(
        close: () -> Void,
        run: (@escaping (Client) async throws -> Void) -> Void,
        send: @escaping (Client) async throws -> Void
    ) {
        close()
        run { client in
            do { try await send(client) } catch let error as APIError where error.status == 404 {}
        }
    }
}

/// A board's queued tag writes, worked out the same way: the hub replaces the
/// whole list, so it is built from the board as it stands when the write
/// runs (`latest`, falling back to the board as shown), and the hub's answer
/// goes back through `apply` for the next write in the burst.
@MainActor enum ProjectsProjectWrite {
    static func tags(
        of project: Project, _ change: (Project) -> [String],
        latest: (String) -> Project?,
        send: ([String]) async throws -> Project,
        apply: (Project) -> Void
    ) async throws {
        let current = latest(project.id) ?? project
        apply(try await send(change(current)))
    }

    /// Edit Tags' Save: the sheet closes at the click and only the write
    /// waits its turn, so Save behind a slow write does not leave the sheet
    /// open until the queue drains. The typed list is the whole list.
    static func save<Client>(
        _ tags: [String], close: @escaping () -> Void,
        run: (@escaping (Client) async throws -> Void) -> Void,
        send: @escaping (Client, [String]) async throws -> Project,
        apply: @escaping (Project) -> Void
    ) {
        close()
        run { client in apply(try await send(client, tags)) }
    }
}
