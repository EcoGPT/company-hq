import XCTest
@testable import HQ

@MainActor
final class PlanningTextAutosaveTests: XCTestCase {
  func testNewEditsDuringARequestAreSavedAfterItWithoutOverwriting() async {
    var writes: [PlanningTextValue] = []
    var release: CheckedContinuation<Void, Never>?
    let editor = PlanningTextAutosave(value: .init(title: "Original", body: ""), titleLimit: 60, bodyLimit: 2000, key: "test", defaults: nil) { value, _ in
      writes.append(value)
      if writes.count == 1 { await withCheckedContinuation { release = $0 } }
    }
    editor.title = "First edit"
    let saving = Task { await editor.savePending() }
    while release == nil { await Task.yield() }
    editor.title = "Latest edit"
    editor.body = "Latest description"
    release?.resume()
    await saving.value
    XCTAssertEqual(writes.map(\.title), ["First edit", "Latest edit"])
    XCTAssertEqual(writes.last?.body, "Latest description")
    XCTAssertFalse(editor.hasChanges)
    XCTAssertNil(editor.error)
  }

  func testFailedDraftSurvivesReopeningAndCanRetry() async {
    let suite = "planning-autosave.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = PlanningTextValue(title: "Original", body: "")
    let editor = PlanningTextAutosave(value: original, titleLimit: 60, bodyLimit: 2000, key: "draft", defaults: defaults) { _, _ in
      throw URLError(.notConnectedToInternet)
    }
    editor.body = "Keep this draft"
    await editor.savePending()
    XCTAssertNotNil(editor.error)
    var stored: PlanningTextValue?
    let reopened = PlanningTextAutosave(value: original, titleLimit: 60, bodyLimit: 2000, key: "draft", defaults: defaults) { value, _ in stored = value }
    XCTAssertEqual(reopened.body, "Keep this draft")
    await reopened.savePending()
    XCTAssertEqual(stored?.body, "Keep this draft")
    XCTAssertNil(defaults.data(forKey: "draft"))
  }

  func testFlushSavesWithoutWaitingForTypingDebounceAndInvalidTextIsRetained() async {
    var writes: [PlanningTextValue] = []
    let editor = PlanningTextAutosave(value: .init(title: "Original", body: ""), titleLimit: 60, bodyLimit: 2000, key: "test", defaults: nil) { value, _ in writes.append(value) }
    editor.title = ""
    await editor.savePending()
    XCTAssertTrue(writes.isEmpty)
    XCTAssertNotNil(editor.error)
    editor.title = "Leaving the page"
    editor.flush()
    for _ in 0..<100 where writes.isEmpty { await Task.yield() }
    XCTAssertEqual(writes.last?.title, "Leaving the page")
    XCTAssertFalse(editor.hasChanges)
  }
}
