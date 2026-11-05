import Foundation
import XCTest

/// Which conversations a Mac offers, and when sync is on, paused, signed out or waiting for
/// the notice. Pure: nothing here reads or writes this Mac's real configuration.
final class ConfigTests: XCTestCase {
  let server = "https://hq.example.test"

  func testNamesComeFromTheBundleId() {
    XCTAssertTrue(SessionSyncIdentity.helperBundleID.hasSuffix(".session-sync"))
    XCTAssertEqual(SessionSyncIdentity.helperBundleID, SessionSyncIdentity.appBundleID + ".session-sync")
    XCTAssertFalse(SessionSyncIdentity.appBundleID.hasSuffix(".session-sync"))
    XCTAssertTrue(SessionSyncConfig.directory.path.hasSuffix("Application Support/\(SessionSyncIdentity.appBundleID)/session-sync"))
    XCTAssertEqual(SyncCredential.service, SessionSyncIdentity.helperBundleID)
  }

  func testDetectedSourcesAreClaudeAndCodexFoldersOnly() throws {
    let scratch = Scratch()
    for path in [
      ".codex", ".claude/projects", ".claude-work/projects", ".claude-empty",
      "Library/Application Support/Claude-3p/code-config/projects", "Library/Application Support/Claude/other",
      ".other/provider-homes/claude/projects", ".other/provider-homes/codex",
    ] { _ = try scratch.folder(path) }
    // /var is /private/var on a Mac: compare the real path of each side.
    let home = URL(fileURLWithPath: scratch.root.path).resolvingSymlinksInPath().path + "/"
    let found = SessionSyncConfig.detectedSources(home: scratch.root).map { source -> String in
      let path = URL(fileURLWithPath: source.path).resolvingSymlinksInPath().path
      XCTAssertTrue(path.hasPrefix(home), path)
      return source.provider + " " + String(path.dropFirst(home.count))
    }
    XCTAssertEqual(
      Set(found),
      ["codex .codex", "claude .claude", "claude .claude-work",
       "claude Library/Application Support/Claude-3p/code-config"],
      "a folder with no projects is not a source, and no other tool's home is read")
  }

  func testSyncIsOnAfterSignInUnlessPausedAndSignOutIsNotAPause() throws {
    let old = #"{"enabled":true,"personID":"p","baseURL":"\#(server)","sources":[{"provider":"claude","path":"/extra"}]}"#
    let stored = try JSONDecoder().decode(SessionSyncConfig.self, from: Data(old.utf8))
    XCTAssertNil(stored.paused)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self).contains("paused"))
    let fresh = try XCTUnwrap(SessionSyncConfig.resuming(nil, personID: "p", baseURL: server))
    XCTAssertTrue(fresh.enabled)
    XCTAssertNil(fresh.paused)
    let signedOut = stored.signedOut()
    XCTAssertFalse(signedOut.enabled)
    XCTAssertNil(signedOut.paused, "sign-out is not a pause")
    let back = SessionSyncConfig.resuming(signedOut, personID: "p", baseURL: server)
    XCTAssertEqual(back?.enabled, true)
    XCTAssertEqual(back?.sources, stored.sources, "signing in again keeps the added folders")
    let paused = stored.pausedByPerson()
    XCTAssertEqual(paused.paused, true)
    XCTAssertFalse(paused.enabled)
    XCTAssertNil(SessionSyncConfig.resuming(paused, personID: "p", baseURL: server), "a pause survives a sign-in")
    XCTAssertNil(SessionSyncConfig.resuming(paused.signedOut(), personID: "p", baseURL: server), "and a sign-out")
    XCTAssertNil(SessionSyncConfig.resuming(paused, personID: "q", baseURL: server), "and another person signing in")
    XCTAssertNil(SessionSyncConfig.resuming(paused, personID: "p", baseURL: "http://localhost:8790"), "and another server")
    XCTAssertNil(SessionSyncConfig.resuming(paused, personID: "p", baseURL: server, ignoringPause: true)?.paused, "Resume clears it")
    let other = SessionSyncConfig.resuming(paused, personID: "q", baseURL: server, ignoringPause: true)
    XCTAssertEqual(other?.sources.isEmpty, true, "another person gets none of the first person's folders")
  }

  func testNothingUploadsUntilTheNoticeIsAnswered() throws {
    let fresh = try XCTUnwrap(SessionSyncConfig.resuming(nil, personID: "p", baseURL: server))
    XCTAssertTrue(fresh.enabled)
    XCTAssertFalse(fresh.hasAcceptedRules)
    XCTAssertFalse(fresh.isSyncing, "a fresh Mac uploads nothing until the answer")
    let again = try XCTUnwrap(SessionSyncConfig.resuming(fresh, personID: "p", baseURL: server))
    XCTAssertFalse(again.isSyncing, "signing in again is not the answer")
    let answered = fresh.acceptingRules()
    XCTAssertTrue(answered.isSyncing)
    XCTAssertTrue(answered.signedOut().hasAcceptedRules && !answered.signedOut().isSyncing)
    XCTAssertTrue(answered.pausedByPerson().hasAcceptedRules && !answered.pausedByPerson().isSyncing)
    XCTAssertFalse(
      SessionSyncConfig(enabled: true, personID: "p", baseURL: server, sources: [], rules: 0).isSyncing,
      "an answer to other rules is not an answer to these")
    XCTAssertTrue(String(decoding: try JSONEncoder().encode(answered), as: UTF8.self).contains("\"rules\":\(SessionSyncConfig.currentRules)"))
  }

  func testOnlyTheCurrentSignInIsKept() {
    let mine = SessionSyncConfig(enabled: true, personID: "p", baseURL: server, sources: [])
    let accounts = ["\(server)/p", "\(server)/q", "https://other.example.test/p"]
    XCTAssertEqual(SyncCredential.staleAccounts(accounts, keeping: mine), ["\(server)/q", "https://other.example.test/p"])
    XCTAssertEqual(SyncCredential.staleAccounts(accounts, keeping: nil), accounts, "sign-out keeps none")
    XCTAssertEqual(SyncCredential.staleAccounts([], keeping: mine), [])
  }

  func testTheFirstAnswerWinsTheRaceBetweenAReadAndItsTimer() async {
    let value: String? = await withCheckedContinuation { continuation in
      let answer = SyncCredential.OneShot(continuation)
      answer.resume("read")
      answer.resume(nil)
    }
    XCTAssertEqual(value, "read")
    let late: String? = await withCheckedContinuation { continuation in
      let answer = SyncCredential.OneShot(continuation)
      answer.resume(nil)
      answer.resume("too late")
    }
    XCTAssertNil(late)
  }

  func testTheStatusFileHoldsNoConversationText() throws {
    let status = SessionSyncStatus(checkedAt: Date(), synced: 2, pending: 1, errors: ["claude/abc: Waiting for conversation text"])
    let text = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
    XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]).keys), ["checkedAt", "synced", "pending", "errors"])
  }
}
