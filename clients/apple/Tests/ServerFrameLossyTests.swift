import XCTest

@testable import HQ

/// A replay batch survives one message this build cannot read: the bad element drops alone, where it used to turn the whole
/// `sync_batch` into `.unknown` and lose up to 100 replayed messages. A
/// single `message` frame stays strict (`ServerFrameDecodeTests`).
final class ServerFrameLossyTests: XCTestCase {
    private func messageJSON(_ id: String) -> String {
        """
        {"id":"\(id)","conversation_id":"c1","sender_person_id":"p1","sender_name":"Bo",
         "content":"hello","created_at":"2026-10-14T12:00:00.000Z","reactions":[],"attachments":[]}
        """
    }

    func testOneUnreadableMessageDropsAloneFromASyncBatch() {
        let json = #"{"type":"sync_batch","messages":[\#(messageJSON("m1")),{"id":42},\#(messageJSON("m3"))]}"#
        guard case let .syncBatch(messages) = ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("the batch was dropped whole")
        }
        XCTAssertEqual(messages.map(\.id), ["m1", "m3"])
    }

    func testABatchWithNoMessagesKeyIsStillUnknown() {
        guard case .unknown = ServerFrame.decode(Data(#"{"type":"sync_batch"}"#.utf8)) else {
            return XCTFail("a batch with no messages decoded")
        }
    }
}
