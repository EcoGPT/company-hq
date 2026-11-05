import Foundation
import XCTest
@testable import HQ

/// What the @-picker offers, and in what order. The rules are shared by both
/// composers, so the answers here are the answers on the phone too.
final class MentionSuggestionsTests: XCTestCase {
    private func person(_ name: String, kind: String = "person") -> Person {
        Person(id: name, name: name, kind: kind, isAdmin: false, avatarId: nil, removedAt: nil)
    }

    private func suggestions(_ draft: String, members: [String]) -> MentionSuggestions {
        MentionSuggestions(
            draft: draft, members: members.map { person($0) }, assistant: person("Scout", kind: "bot")
        )
    }

    func testTheRoomTagsAreOfferedAfterThePeople() {
        let visible = suggestions("hey @", members: ["Bo", "Mia"]).visible

        XCTAssertEqual(visible.map(\.label), ["Scout", "Bo", "Mia", "@everyone", "@here"])
    }

    /// The limit is spent on people last. A full room used to fill every slot
    /// with names, which left `@here` findable only by already knowing to
    /// type it.
    func testARoomTagKeepsItsSeatInACrowdedThread() {
        let crowd = ["Ana", "Ben", "Cara", "Dev", "Erin", "Fay", "Gil"]
        let visible = suggestions("@", members: crowd).visible

        XCTAssertEqual(visible.count, MentionSuggestions.visibleLimit)
        XCTAssertEqual(visible.suffix(2).map(\.label), ["@everyone", "@here"])
    }

    func testAllFiveSlotsGoToPeopleWhenNoRoomTagMatches() {
        let crowd = ["Ana", "Ben", "Cara", "Dev", "Erin", "Fay"]
        let visible = suggestions("@a", members: crowd).visible

        XCTAssertTrue(visible.allSatisfy { $0.person != nil })
    }

    func testATokenNarrowsToTheRoomTagItSpells() {
        let visible = suggestions("@her", members: ["Bo", "Mia"]).visible

        XCTAssertEqual(visible.map(\.label), ["@here"])
    }

    func testPickingARoomTagPutsItInTheDraftWithItsAt() {
        let picked = suggestions("standup @ev", members: ["Bo"])
            .applying(.broadcast(.everyone))

        XCTAssertEqual(picked, "standup @everyone ")
    }

    func testPickingAPersonStillDropsInTheirName() {
        let picked = suggestions("hey @bl", members: ["Bo"]).applying(.person(person("Bo")))

        XCTAssertEqual(picked, "hey @Bo ")
    }

    func testNoTokenOffersNothing() {
        XCTAssertTrue(suggestions("just talking", members: ["Bo"]).visible.isEmpty)
    }
}
