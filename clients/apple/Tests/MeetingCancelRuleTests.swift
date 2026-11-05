import XCTest

@testable import HQ

/// Who may cancel a meeting. The Mac's menu and the phone's swipe offer
/// Cancel, Skip and End series to the same two people.
final class MeetingCancelRuleTests: XCTestCase {
    private func meeting(createdBy: String, seriesId: String? = nil) throws -> Meeting {
        var object: [String: Any] = [
            "id": "m1", "title": "Weekly planning", "scheduled_at": "2026-09-16T15:00:00Z",
            "created_by_person_id": createdBy, "created_at": "2026-09-01T00:00:00Z",
        ]
        if let seriesId { object["series_id"] = seriesId }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Meeting.self, from: data)
    }

    private func person(_ id: String, isAdmin: Bool = false) -> Person {
        Person(id: id, name: id, kind: "person", isAdmin: isAdmin, avatarId: nil, removedAt: nil)
    }

    func testTheCreatorMayCancelTheirOwnMeeting() throws {
        XCTAssertTrue(try meeting(createdBy: "ada").canBeCanceled(by: person("ada")))
    }

    func testAnAdminMayCancelSomeoneElsesMeeting() throws {
        XCTAssertTrue(try meeting(createdBy: "ada").canBeCanceled(by: person("bo", isAdmin: true)))
    }

    func testAnotherMemberMayNot() throws {
        XCTAssertFalse(try meeting(createdBy: "ada").canBeCanceled(by: person("dana")))
        XCTAssertFalse(try meeting(createdBy: "ada", seriesId: "s1").canBeCanceled(by: person("dana")))
    }

    func testNobodySignedInMayNot() throws {
        XCTAssertFalse(try meeting(createdBy: "ada").canBeCanceled(by: nil))
    }
}
