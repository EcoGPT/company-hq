import XCTest
@testable import HQ

/// A chat that is selected but not on screen is not being read: a message that
/// arrives behind another page must banner and stay unread, and a message in
/// the chat on screen must stay silent and read. Hosted, on the chat fixture
/// like `OwnEchoTests`; the OS readings and the banner are the store's test
/// seams.
@MainActor
final class ReadBehindTakeoverTests: XCTestCase {
    private var previousScenario: String?

    override func setUp() async throws {
        previousScenario = ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
        setenv("HQ_UI_SCENARIO", "chat", 1)
        HQFixtureProtocol.contentMode = "ready"
    }

    override func tearDown() async throws {
        HQFixtureProtocol.contentMode = "ready"
        if let previousScenario {
            setenv("HQ_UI_SCENARIO", previousScenario, 1)
        } else {
            unsetenv("HQ_UI_SCENARIO")
        }
    }

    /// A store with the "studio" chat selected and HQ in front; `banners`
    /// collects the ids of the banners it asks for.
    private func fixtureStore(banners: BannerLog, isChatVisible: Bool) -> AppStore {
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()
        store.screenReading = { (isAppActive: true, isChatVisible: isChatVisible) }
        store.postBanner = { _, _, _, messageId in banners.ids.append(messageId) }
        store.openConversation("studio")
        return store
    }

    private final class BannerLog {
        var ids: [String] = []
    }

    private func incoming(_ id: String) -> Message {
        Message(
            id: id, conversationId: "studio", senderPersonId: "bo", senderName: "Bo",
            content: "hello \(id)", createdAt: "2026-10-29T12:00:00Z"
        )
    }

    private func unread(_ store: AppStore) -> Int {
        store.conversation("studio")?.unreadCount ?? -1
    }

    func testAMessageInAChatThatIsNotOnScreenBannersAndStaysUnread() {
        let banners = BannerLog()
        let store = fixtureStore(banners: banners, isChatVisible: false)
        let before = unread(store)
        store.handle(.message(incoming("zz-behind")))
        XCTAssertEqual(banners.ids, ["zz-behind"])
        XCTAssertEqual(unread(store), before + 1)
    }

    func testAMessageInTheChatOnScreenStaysSilentAndRead() {
        let banners = BannerLog()
        let store = fixtureStore(banners: banners, isChatVisible: true)
        store.handle(.message(incoming("zz-front")))
        XCTAssertTrue(banners.ids.isEmpty)
        XCTAssertEqual(unread(store), 0)
    }
}
