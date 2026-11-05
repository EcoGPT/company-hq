import XCTest

@testable import HQ

/// What the shelf and the widget API do with keys, people and server addresses: the rules that keep one
/// person's tasks off another's desktop, and a widget key off the wrong host. The shelf is pointed at a
/// temporary folder (a build with no team has no App Group).
final class WidgetShelfTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-shelf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        WidgetShelf.directoryOverride = folder
    }

    override func tearDown() {
        WidgetShelf.directoryOverride = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func credentials(person: String = "ada", key: String = "hq_widget_one", device: String? = "d1") -> WidgetShelf.Credentials {
        .init(baseURL: "https://example.org/hq", key: key, personId: person, deviceId: device)
    }

    private func sampleData() -> Data { Data(WidgetSummary.sampleJSON.utf8) }

    // MARK: Server addresses

    func testAServerAddressKeepsItsPath() throws {
        let base = try XCTUnwrap(URL(string: "https://example.org/hq"))
        XCTAssertEqual(WidgetAPI.url(base: base, path: "/v1/widgets/summary")?.absoluteString,
                       "https://example.org/hq/v1/widgets/summary")
        let slash = try XCTUnwrap(URL(string: "https://example.org/hq/"))
        XCTAssertEqual(WidgetAPI.url(base: slash, path: "/v1/widgets/key")?.absoluteString,
                       "https://example.org/hq/v1/widgets/key")
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:18790"))
        XCTAssertEqual(WidgetAPI.url(base: root, path: "/v1/widgets/summary")?.absoluteString,
                       "http://127.0.0.1:18790/v1/widgets/summary")
    }

    // MARK: Whose tasks these are

    func testASummaryBelongsOnlyToThePersonWhoseKeyIsSaved() throws {
        let summary = try XCTUnwrap(WidgetSummary.sample)
        XCTAssertTrue(summary.belongs(to: credentials(person: "ada")))
        XCTAssertFalse(summary.belongs(to: credentials(person: "bo")))
        XCTAssertFalse(summary.belongs(to: nil), "with no key there is nobody")
    }

    func testTheCacheIsShownOnlyWhileAKeyForThatPersonIsSaved() throws {
        WidgetShelf.saveCredentials(credentials(person: "ada"))
        XCTAssertTrue(WidgetShelf.saveSummary(sampleData(), fetchedWith: "hq_widget_one"))
        XCTAssertEqual(WidgetShelf.loadCurrentSummary()?.me.id, "ada")

        // Another person signs in on this Mac: the earlier person's tasks are not shown to them.
        WidgetShelf.saveCredentials(credentials(person: "bo", key: "hq_widget_two"))
        XCTAssertNotNil(WidgetShelf.loadSummary(), "the file is still there")
        XCTAssertNil(WidgetShelf.loadCurrentSummary())

        // Sign-out empties the shelf; a summary file that outlives it is not shown either.
        WidgetShelf.saveCredentials(credentials(person: "ada"))
        XCTAssertNotNil(WidgetShelf.loadCurrentSummary())
        WidgetShelf.clear()
        XCTAssertNil(WidgetShelf.loadCurrentSummary())
    }

    func testAFetchThatFinishesAfterSignOutWritesNothing() throws {
        WidgetShelf.saveCredentials(credentials())
        WidgetShelf.clear() // sign-out, while a fetch under the key "hq_widget_one" was in flight
        XCTAssertFalse(WidgetShelf.saveSummary(sampleData(), fetchedWith: "hq_widget_one"))
        XCTAssertNil(WidgetShelf.loadSummary())
    }

    func testAFetchUnderAReplacedKeyWritesNothing() throws {
        WidgetShelf.saveCredentials(credentials(key: "hq_widget_new"))
        XCTAssertFalse(WidgetShelf.saveSummary(sampleData(), fetchedWith: "hq_widget_old"))
        XCTAssertNil(WidgetShelf.loadSummary())
        XCTAssertTrue(WidgetShelf.saveSummary(sampleData(), fetchedWith: "hq_widget_new"))
    }

    func testASummaryForAnotherPersonThanTheKeyIsNotWritten() throws {
        WidgetShelf.saveCredentials(credentials(person: "bo"))
        XCTAssertFalse(WidgetShelf.saveSummary(sampleData(), fetchedWith: "hq_widget_one"))
        XCTAssertNil(WidgetShelf.loadSummary())
    }

    // MARK: A key the server ended

    func testAKeyTheServerRefusedIsDroppedButNeverANewerOne() throws {
        WidgetShelf.saveCredentials(credentials(key: "hq_widget_new"))
        WidgetShelf.dropCredentials(ifKey: "hq_widget_old")
        XCTAssertEqual(WidgetShelf.loadCredentials()?.key, "hq_widget_new")
        WidgetShelf.dropCredentials(ifKey: "hq_widget_new")
        XCTAssertNil(WidgetShelf.loadCredentials())
    }

    func testTheSavedKeyIsKeptOnlyForTheSamePersonDeviceAndServer() {
        let saved = credentials()
        let base = "https://example.org/hq"
        XCTAssertTrue(WidgetSync.keepsKey(saved, personId: "ada", deviceId: "d1", baseURL: base))
        XCTAssertFalse(WidgetSync.keepsKey(saved, personId: "bo", deviceId: "d1", baseURL: base))
        XCTAssertFalse(WidgetSync.keepsKey(saved, personId: "ada", deviceId: "d2", baseURL: base), "a new sign-in is a new device")
        XCTAssertFalse(WidgetSync.keepsKey(saved, personId: "ada", deviceId: "d1", baseURL: "https://other.example"))
        XCTAssertFalse(WidgetSync.keepsKey(credentials(device: nil), personId: "ada", deviceId: "d1", baseURL: base),
                       "a key with no device recorded is replaced")
    }

    func testCredentialsRoundTripWithTheDevice() throws {
        WidgetShelf.saveCredentials(credentials(device: "d9"))
        XCTAssertEqual(WidgetShelf.loadCredentials()?.deviceId, "d9")
    }
}
