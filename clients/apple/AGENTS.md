# clients/apple

The native Mac and iPhone apps. `README.md` builds and tests them; `docs/` explains how
they are put together. Run commands from this folder, and run `xcodegen generate` before
every build (`HQ.xcodeproj` is generated, never committed).

## Session sync

`Sources/SessionSyncAgent` (the `HQSessionSync` login item), `Sources/SessionSyncShared`
(compiled into the helper and the app), `Sources/macOS/SessionSync*` (the app's side).
The contract is `docs/session-sync.md`. Rules that keep it safe to ship:

- It opens Claude and Codex files **read-only** and uploads message **text only**:
  never reasoning, tool calls or results, images or attachments. It writes nothing into
  anyone's Claude or Codex settings.
- Secrets are hidden on the Mac before hashing or upload: the 13 patterns in
  `SessionCollector.redactionSpecs` (the server's list, copied as it is, and
  its JSON-key rule; `test/fixtures/redaction-cases.json` is the shared test), secret-named
  environment values, and the bearer. Blocks a tool injected into a user message
  (`SyncTitle.injected`) are cut out first. A new pattern or block gets a test.
- The bearer reaches the helper only over the `--configure` stdin pipe, into the helper's
  own Keychain item. It is sent only to the server the app is signed in to, never follows a
  redirect, and `https://` or localhost `http://` only (`SyncTransport.allowed`). Sign-out
  has the helper delete it (`--forget`); a refused conversation is held, not resent
  (`RefusalMemo`).
- Names come from the app's bundle id (`SessionSyncIdentity`); no literal bundle id, host or
  company anywhere.
- An upload body never passes the server's 1 MiB cap (`SessionCollector.maxBytes`).
- It starts only in a `team` build (`HQ_SESSION_SYNC`), asks first (the notice), stops on
  Pause and sign-out, and a Debug or test build never registers the login item
  (`SessionSyncGate`).
- Tests: scheme `HQSessionSyncTests-Mac` (helper), `HQTests` (`SessionSyncAgentTests`,
  `LiveSessionSyncTests`).
