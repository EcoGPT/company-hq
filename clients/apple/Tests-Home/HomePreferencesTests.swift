import XCTest

final class HomePreferencesTests: XCTestCase {
    @MainActor
    func testPinsPersistReorderAndUnpin() async {
        let name = "home-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let home = HomePreferences(hub: "https://hq.example", personID: "one", defaults: defaults)
        XCTAssertTrue(home.pin("a"))
        XCTAssertTrue(home.pin("b"))
        XCTAssertTrue(home.pin("c"))
        XCTAssertFalse(home.pin("a"))
        home.movePin("a", to: "c")
        XCTAssertEqual(home.pinnedIDs, ["b", "c", "a"])
        home.unpin("c")
        let restored = HomePreferences(hub: "https://hq.example/", personID: "one", defaults: defaults)
        XCTAssertEqual(restored.pinnedIDs, ["b", "a"])
        restored.movePin("a", by: -1)
        XCTAssertEqual(restored.pinnedIDs, ["a", "b"])
    }

    @MainActor
    func testPreferencesAreIsolatedByPersonAndHub() async {
        let name = "home-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = HomePreferences(hub: "https://hq.example", personID: "one", defaults: defaults)
        first.pin("private-chat")
        first.setShortcuts([.files])
        for (hub, person) in [("https://hq.example", "two"), ("https://staging.example", "one")] {
            let other = HomePreferences(hub: hub, personID: person, defaults: defaults)
            XCTAssertTrue(other.pinnedIDs.isEmpty)
            XCTAssertEqual(other.shortcuts, [.calls, .tasks, .files])
        }
    }

    @MainActor
    func testEmptyShortcutsPersistAndLimitsAreEnforced() async {
        let name = "home-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let home = HomePreferences(hub: "https://hq.example", personID: "one", defaults: defaults)
        for index in 0..<12 { home.pin("\(index)") }
        XCTAssertEqual(home.pinnedIDs.count, 9)
        home.setShortcuts([.files, .files, .tasks, .calls])
        XCTAssertEqual(home.shortcuts, [.files, .tasks, .calls])
        home.setShortcuts([])
        XCTAssertEqual(HomePreferences(hub: "https://hq.example", personID: "one", defaults: defaults).shortcuts, [])
    }

    @MainActor
    func testReorderingRetainsUnavailablePins() async {
        let home = HomePreferences(hub: "https://hq.example", personID: "one", defaults: nil)
        for id in ["a", "unavailable", "b", "c"] { home.pin(id) }
        home.setPinOrder(["c", "c", "a", "b", "not-pinned"])
        XCTAssertEqual(home.pinnedIDs, ["c", "unavailable", "a", "b"])
        home.setPinOrder([])
        XCTAssertEqual(home.pinnedIDs, ["c", "unavailable", "a", "b"])
    }

    @MainActor
    func testMalformedAndFutureRecordsDoNotBreakHome() async {
        let name = "home-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let home = HomePreferences(hub: "https://hq.example", personID: "one", defaults: defaults)
        home.pin("a")
        let key = defaults.persistentDomain(forName: name)!.keys.first!
        defaults.set(Data("invalid".utf8), forKey: key)
        XCTAssertEqual(HomePreferences(hub: "https://hq.example", personID: "one", defaults: defaults).shortcuts,
                       [.calls, .tasks, .files])
        let record = #"{"pinnedIDs":["a","a","","b"],"shortcuts":["future","tasks","tasks","files"]}"#
        defaults.set(Data(record.utf8), forKey: key)
        let restored = HomePreferences(hub: "https://hq.example", personID: "one", defaults: defaults)
        XCTAssertEqual(restored.pinnedIDs, ["a", "b"])
        XCTAssertEqual(restored.shortcuts, [.tasks, .files])
    }
}
