import XCTest

@testable import HQ

// What the chat views used to pay per scroll frame (iPhone) and twice per
// body: ordering the whole loaded transcript. Both views now order once per
// body pass. No test can observe a SwiftUI body, so this prints the cost.
final class TranscriptOrderCostTests: XCTestCase {
    func testOrderingFourHundredRows() {
        let start = ISO8601.parse("2026-09-20T00:00:00Z").timeIntervalSince1970
        let rows = (0..<400).map { index -> Message in
            let created = ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: start + Double(index * 97 % 400) * 60)
            )
            return Message(
                id: "m-\(index)", conversationId: "studio", senderPersonId: "scout", senderName: "Scout",
                content: "Hello", createdAt: created
            )
        }
        _ = TranscriptLayout.orderedMessages(rows)
        let runs = 50
        let begin = CFAbsoluteTimeGetCurrent()
        var count = 0
        for _ in 0..<runs { count += TranscriptLayout.orderedMessages(rows).count }
        let mean = (CFAbsoluteTimeGetCurrent() - begin) * 1_000 / Double(runs)
        print("TranscriptOrderCostTests timing: \(String(format: "%.3f", mean)) ms per orderedMessages at 400 rows")
        XCTAssertEqual(count, 400 * runs)
    }
}
