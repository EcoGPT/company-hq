import XCTest

@testable import HQ

/// A thread's detail: the fixture server plays the by-id route, the app reads
/// the capability flag and asks for another person's session only when the
/// server opens them.
final class OpenTranscriptsTests: XCTestCase {
    override func tearDown() {
        unsetenv("HQ_UI_OPEN_TRANSCRIPTS")
    }

    private func detail(_ id: String) throws -> CodingThreadDetail {
        let body = try XCTUnwrap(HQCodingThreadsFixture.response("/v1/agent-sessions/by-id/\(id)", empty: false))
        return try JSONDecoder().decode(CodingThreadDetail.self, from: JSONSerialization.data(withJSONObject: body))
    }

    func testAnotherPersonsThreadCarriesItsSessionWhenTheServerOpensThem() throws {
        let other = try detail("b-02")
        XCTAssertEqual(other.thread.ownerPersonId, "bo")
        let session = try XCTUnwrap(other.session)
        XCTAssertEqual(session.id, "b-02")
        XCTAssertNotNil(try detail("thread-two").session)
        XCTAssertNotNil(try detail("thread-one").session)
    }

    func testAServerThatDoesNotOpenThemSendsNoSessionForAPeer() throws {
        setenv("HQ_UI_OPEN_TRANSCRIPTS", "off", 1)
        XCTAssertFalse(HQCodingThreadsFixture.opensTranscripts)
        XCTAssertNil(try detail("b-02").session)
        XCTAssertNil(try detail("thread-two").session)
        XCTAssertNotNil(try detail("thread-one").session, "your own is always yours")
    }

    func testTheDetailRequestAsksForTheSessionOnlyWhenTheServerOpensThem() {
        XCTAssertEqual(CodingThreadRoutes.detail(id: "s1", openTranscripts: true), "/v1/agent-sessions/by-id/s1?open=1")
        XCTAssertEqual(CodingThreadRoutes.detail(id: "s1", openTranscripts: false), "/v1/agent-sessions/by-id/s1")
    }

    func testAProjectTheServerKeysForItselfIsASystemProject() throws {
        func project(_ json: String) throws -> Project {
            try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        }
        let base = #""body":null,"owner_person_id":"p","owner_name":"P","status":"active","open_tasks":0,"created_at":"2026-10-01T00:00:00Z","closed_at":null"#
        XCTAssertTrue(try project(#"{"id":"b","name":"Renamed","system_key":"standing",\#(base)}"#).isSystem)
        XCTAssertFalse(try project(#"{"id":"a","name":"Standing",\#(base)}"#).isSystem, "a name alone is not a system project")
        XCTAssertFalse(try project(#"{"id":"d","name":"Image fleet",\#(base)}"#).isSystem)
    }
}
