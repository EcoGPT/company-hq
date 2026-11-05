import Foundation
import XCTest

/// The "already synced" memo holds every chat a pass walks: a second sorted sweep
/// over more chats than any fixed capacity computes no acknowledgement again.
struct AcknowledgementMemoTests {
  static func check(_ condition: Bool, _ message: String) {
    guard !condition else { return }
    XCTFail(message)
  }

  static func snapshot(_ index: Int, revision: String) -> SyncSnapshot {
    SyncSnapshot(
      title: "Chat \(index)", cwd: "/work", branch: nil,
      messages: [SyncMessage(id: "m\(index)", role: "user", text: "Message \(index)", timestamp: nil)],
      revision: revision)
  }

  static func run() throws {
    let config = SessionSyncConfig(
      enabled: true, personID: "fixture", baseURL: "http://localhost:8797",
      sources: [])
    let transport = try SyncTransport(config: config, token: "fixture", scopeCheck: { true })
    defer { transport.close() }

    // This Mac's status.json lists 1,920 candidates; main.swift walks them sorted.
    let keys = (0..<1920).map { String(format: "claude/%05d", $0) }.sorted()
    let snapshots = keys.indices.map { snapshot($0, revision: "r\($0)") }
    var first: [String] = []
    let start = SyncTransport.acknowledgementHashes
    for (key, snapshot) in zip(keys, snapshots) { first.append(try transport.acknowledgement(snapshot, key: key)) }
    let firstPass = SyncTransport.acknowledgementHashes - start
    var second: [String] = []
    for (key, snapshot) in zip(keys, snapshots) { second.append(try transport.acknowledgement(snapshot, key: key)) }
    let secondPass = SyncTransport.acknowledgementHashes - start - firstPass
    print("hashes per pass over \(keys.count) unchanged chats: first \(firstPass), second \(secondPass)")
    check(firstPass == keys.count, "the first sweep hashes each chat once, got \(firstPass)")
    check(secondPass == 0, "the second sweep over unchanged chats hashes none, got \(secondPass)")
    check(first == second, "a remembered acknowledgement equals the computed one")

    // A chat that changed (new revision) hashes once and is then remembered.
    let changed = snapshot(7, revision: "r7-next")
    let before = SyncTransport.acknowledgementHashes
    let ack = try transport.acknowledgement(changed, key: keys[7])
    check(SyncTransport.acknowledgementHashes == before + 1, "a new revision is hashed")
    check(try transport.acknowledgement(changed, key: keys[7]) == ack, "the new revision is remembered")
    check(SyncTransport.acknowledgementHashes == before + 1, "the new revision is hashed once")
    print("PASS a second sorted sweep over 1,920 unchanged chats computes no acknowledgement; a changed chat costs one")

    // One entry per chat: a new revision replaces the old one, which is not served again.
    let memo = AcknowledgementMemo()
    let start2 = Date()
    memo.set("claude/a", revision: "1", "ack-1", now: start2)
    memo.set("claude/a", revision: "2", "ack-2", now: start2)
    check(memo.count == 1, "a new revision replaces the chat's entry")
    check(memo.value("claude/a", revision: "1", now: start2) == nil, "an old revision misses")
    check(memo.value("claude/a", revision: "2", now: start2) == "ack-2", "the latest revision hits")
    // The hourly sweep drops only chats unused for longer than the sync window.
    memo.set("claude/b", revision: "1", "ack-b", now: start2)
    let day: TimeInterval = 86400
    check(memo.value("claude/a", revision: "2", now: start2.addingTimeInterval(6 * day)) == "ack-2", "a used chat hits")
    memo.set("claude/c", revision: "1", "ack-c", now: start2.addingTimeInterval(7.5 * day))
    check(memo.count == 2, "the sweep drops the chat unused for over 7 days, got \(memo.count)")
    check(memo.value("claude/b", revision: "1") == nil, "the dropped chat misses")
    check(memo.value("claude/a", revision: "2") == "ack-2", "a chat used inside the window survives the sweep")
    print("PASS one entry per chat, and the sweep drops only chats idle past the sync window")
  }
}
