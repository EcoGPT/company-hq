import Foundation
import XCTest

/// The cases the server and the Mac must agree on: the same text goes in, the same text
/// comes out. The file is the server's (`test/fixtures/redaction-cases.json` at the repo
/// root), read from there; this test is red until that file is in the checkout.
final class RedactionFixtureTests: XCTestCase {
  struct Case: Decodable {
    var name: String
    var input: String
    var expected: String
    var mode: String?
  }

  /// `clients/apple/Tests-SessionSync/<this file>` is four steps below the repo root.
  static func fixtureURL(file: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("test/fixtures/redaction-cases.json")
  }

  func testEverySharedCaseGivesTheExpectedText() throws {
    let url = Self.fixtureURL()
    let data = try XCTUnwrap(try? Data(contentsOf: url), "the shared redaction cases are missing at \(url.path)")
    let cases = try JSONDecoder().decode([Case].self, from: data)
    XCTAssertGreaterThanOrEqual(cases.count, 90)
    XCTAssertGreaterThanOrEqual(cases.filter { $0.mode == "json" }.count, 6)
    for item in cases {
      let out = item.mode == "json" ? SessionCollector.redactString(item.input) : SessionCollector.redactPatterns(item.input)
      XCTAssertEqual(out, item.expected, item.name)
    }
  }

  func testOtherScriptsBesideASecretDoNotHideIt() {
    for text in ["密钥sk-proj-FAKEFAKEFAKEFAKE", "トークンghp_FAKEFAKEFAKEFAKE", "令牌hq_" + String(repeating: "A", count: 43), "cléghp_FAKEFAKEFAKEFAKE"] {
      let out = SessionCollector.redactPatterns("x \(text) y")
      XCTAssertTrue(out.contains("[REDACTED]") && !out.contains("FAKEFAKE"), out)
    }
  }

  func testAValueUnderASecretNamedKeyIsDroppedWholeInJSONText() {
    XCTAssertEqual(
      SessionCollector.redactString(#"{"env":{"API_KEY":"x"},"n":1}"#), #"{"env":{"API_KEY":"[REDACTED]"},"n":1}"#)
    XCTAssertEqual(SessionCollector.redactString(#"[{"authorization":{"a":"b"}}]"#), #"[{"authorization":"[REDACTED]"}]"#)
    let plain = #"{ "command" : "ls" }"#
    XCTAssertEqual(SessionCollector.redactString(plain), plain, "JSON with nothing to hide keeps its formatting")
    XCTAssertEqual(SessionCollector.redactString("not json"), "not json")
    // `redact` applies it to every message, after the sign-in and before the environment values.
    XCTAssertEqual(
      SessionCollector.redact(#"{"password":"x"}"#, credential: "", secrets: []), #"{"password":"[REDACTED]"}"#)
  }
}
