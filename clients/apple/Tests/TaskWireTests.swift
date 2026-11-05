import XCTest

@testable import HQ

/// Tasks are `HQ-<n>` on the wire; comments decode beside them.
final class TaskWireTests: XCTestCase {
    private func task(_ extra: String) throws -> TeamTask {
        let json = """
        {"id":"t1","title":"Ship it","status":"open","owner_person_id":"p1",
         "owner_name":"Bo","created_by_person_id":"p1",
         "created_at":"2026-09-22T12:00:00.000Z"\(extra)}
        """
        return try JSONDecoder().decode(TeamTask.self, from: Data(json.utf8))
    }

    func testNumberIsTheRef() throws {
        XCTAssertEqual(try task(#","number":412"#).ref, "HQ-\(412)")
    }

    func testAnOlderServerHasNoNumberAndNoRef() throws {
        let decoded = try task("")
        XCTAssertNil(decoded.number)
        XCTAssertNil(decoded.ref)
    }

    func testACommentDecodes() throws {
        let comment = try JSONDecoder().decode(HQComment.self, from: Data("""
        {"id":"c1","author_name":"Scout","author_person_id":"scout","body":"Started",
         "created_at":"2026-09-22T12:00:00.000Z","target_id":"t1","target_kind":"task"}
        """.utf8))
        XCTAssertEqual(comment.authorName, "Scout")
    }

    func testACommentCountRidesOnTheTask() throws {
        let decoded = try task(#","number":633,"comment_count":3"#)
        XCTAssertEqual(decoded.commentCount, 3)
    }

    func testAServerWithoutThatFieldStillDecodes() throws {
        let decoded = try task("")
        XCTAssertEqual(decoded.commentCount, 0)
    }

    func testAShapeThisBuildCannotReadCostsTheFieldNotTheTask() throws {
        let decoded = try task(#","comment_count":null"#)
        XCTAssertEqual(decoded.id, "t1")
        XCTAssertEqual(decoded.commentCount, 0)
    }

    func testFieldsForFeaturesThisClientLacksAreIgnored() throws {
        let decoded = try task(#","extra_id":"x-9","badge":{"tier":"gold"},"note":{"state":"open"}"#)
        XCTAssertEqual(decoded.id, "t1")
        XCTAssertEqual(decoded.status, "open")
    }

    func testProjectKindAndCommentCountAreOptional() throws {
        let base = """
        {"id":"p1","name":"Website","body":null,"owner_person_id":"ada","owner_name":"Ada",
         "status":"active","open_tasks":6,"created_at":"2026-09-22T12:00:00.000Z","closed_at":null
        """
        let work = try JSONDecoder().decode(
            Project.self, from: Data((base + #","kind":"work","comment_count":2}"#).utf8))
        XCTAssertEqual(work.kind, "work")
        XCTAssertEqual(work.commentCount, 2)
        let older = try JSONDecoder().decode(Project.self, from: Data((base + "}").utf8))
        XCTAssertNil(older.kind)
        XCTAssertNil(older.commentCount)
    }

    func testCommentViaSaysWhoWroteIt() throws {
        func comment(_ via: String) throws -> HQComment {
            try JSONDecoder().decode(HQComment.self, from: Data("""
            {"id":"c1","author_name":"Ada","author_person_id":"p1","body":"x",
             "created_at":"2026-09-22T12:00:00.000Z"\(via)}
            """.utf8))
        }
        XCTAssertTrue(try comment(#","via":"mcp""#).isViaAgent)
        let typed = try comment(#","via":null"#)
        XCTAssertFalse(typed.isViaAgent)
        XCTAssertNil(try comment("").via)
    }

    /// The fixture's tasks cross the wire the way a server's do.
    func testFixtureTasksSurviveTheWire() throws {
        let fixture = try XCTUnwrap(HQProjectsFixture.tasks.first)
        let task = try JSONDecoder().decode(TeamTask.self, from: JSONEncoder().encode(fixture))
        XCTAssertEqual(task, fixture)
        XCTAssertEqual(task.ref, "HQ-\(101)")
    }
}
