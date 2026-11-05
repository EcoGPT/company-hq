import Foundation
import XCTest

/// A line longer than the limit costs that one message, not the conversation.
final class OversizedLineTests: XCTestCase {
  let scratch = Scratch()

  private func ids(_ cache: IncrementalJSONL, _ url: URL, limit: Int = 1000) throws -> [String] {
    try cache.fold(url, purpose: "test", maxLine: limit, initial: { [String]() }) { state, _, row in
      state.append(row["id"] as? String ?? "?")
      return true
    }.state
  }

  private func line(_ id: String, padding: Int = 0) -> Data {
    Data((#"{"id":"\#(id)","pad":""# + String(repeating: "x", count: padding) + "\"}\n").utf8)
  }

  private func append(_ data: Data, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  func testAWholeLineOverTheLimitIsSkippedAndTheRestIsRead() throws {
    let url = scratch.root.appendingPathComponent("a.jsonl")
    try append(line("one") + line("big", padding: 5000) + line("two") + line("big2", padding: 70_000) + line("three"), to: url)
    XCTAssertEqual(try ids(IncrementalJSONL(), url), ["one", "two", "three"])
  }

  func testALineStillBeingWrittenIsDroppedAsItGrowsAndReadingResumesAfterIt() throws {
    let url = scratch.root.appendingPathComponent("b.jsonl")
    let cache = IncrementalJSONL()
    try append(line("one"), to: url)
    XCTAssertEqual(try ids(cache, url), ["one"])
    // The start of a huge line, without its newline: already past the limit.
    try append(Data((#"{"id":"big","pad":""# + String(repeating: "x", count: 3000)).utf8), to: url)
    XCTAssertEqual(try ids(cache, url), ["one"])
    try append(Data(String(repeating: "y", count: 200_000).utf8), to: url)
    XCTAssertEqual(try ids(cache, url), ["one"], "more of the same line is still dropped")
    try append(Data("\"}\n".utf8) + line("two"), to: url)
    XCTAssertEqual(try ids(cache, url), ["one", "two"], "the next line after the long one is read")
    try append(line("three"), to: url)
    XCTAssertEqual(try ids(cache, url), ["one", "two", "three"])
    XCTAssertEqual(try ids(IncrementalJSONL(), url), ["one", "two", "three"], "a cold read agrees with the incremental one")
  }

  func testALineAtTheLimitIsStillRead() throws {
    let url = scratch.root.appendingPathComponent("c.jsonl")
    let fits = line("fits", padding: 900)
    XCTAssertLessThanOrEqual(fits.count - 1, 1000)
    try append(fits + line("after"), to: url)
    XCTAssertEqual(try ids(IncrementalJSONL(), url), ["fits", "after"])
  }
}
