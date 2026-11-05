# Session sync: what leaves the Mac, and how to host it

Session sync lets teammates see each other's coding sessions: the Agents board lists
them, and anyone on the server can open the conversation as text. A small background
helper inside the Mac app reads the person's Claude Code and Codex conversations on
that Mac and uploads them to the server the app is signed in to. Paths are under
`clients/apple/`.

It is **on by default after sign-in**, with a first-run notice, and it can be paused.
It only runs in a build signed with an Apple team (see [Signing](#signing)).

## For the person using it

- **The notice.** The first time sync would start for you on a Mac, the app says:
  your Claude Code and Codex conversations from the last 7 days, and new ones, are
  uploaded as text to _your server's address_; everyone on this server and the person
  who runs it can read them; secrets are hidden on a best-effort basis; Pause stops
  it. Nothing is uploaded until you press **OK**. Closing the panel is not an answer:
  it asks again at the next launch. **Pause** in the notice starts nothing. When the
  notice's wording changes (`SessionSyncConfig.currentRules`), everyone is asked again
  and nothing uploads until they answer.
- **Pause and Resume.** Settings → Coding → Session sync has **Pause** (and **Resume**
  once paused). A pause holds across sign-ins, other people signing in on this Mac,
  and other servers, until someone presses Resume.
- **Sign-out stops it.** Signing out stops the helper, removes its login item, and asks
  the helper to delete the sign-in it holds in its Keychain (`HQSessionSync --forget`). What
  is guaranteed: the app records that this delete is owed (an empty `forget-pending` file in
  the session-sync folder, with no secret in it) and asks again at every launch until the
  helper exits 0, meaning nothing is left; a new sign-in settles it too, because the helper
  keeps only the current person's and server's sign-in. What is not: until the delete
  succeeds (the helper times out after 20 seconds, is missing, or cannot delete an item made
  by a differently signed build) the device key stays in that Keychain item and is still a
  working key for the server, which the person running it can revoke. Sign-outs, sign-ins and
  these deletes run one at a time, so a late delete never removes a newer sign-in. Signing
  out is not a pause: signing in again starts sync (the notice is not shown twice for the
  same person and server). A second person or server signing in on this Mac replaces the
  first's saved sign-in.
- **Folders.** Settings → Coding lists the folders it reads. **Add Claude Folder…**
  adds a `CLAUDE_CONFIG_DIR` the app does not find on its own.
- **Login Items.** The first start asks macOS to allow the helper under System
  Settings → General → Login Items & Extensions. Until you allow it, nothing runs.
- **Dry run.** `HQSessionSync --dry-run [--since-days N]` (inside
  `HQ.app/Contents/Library/LoginItems/HQSessionSync.app/Contents/MacOS/`) lists
  what would sync, with titles and counts. It never contacts the server and writes
  nothing.

## What it reads

| Tool        | Where                                                                                                                                                                                                                                                                           |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude Code | `projects/*/<session>.jsonl` under `~/.claude`, `~/.claude-*` and the Claude desktop app's `Library/Application Support/Claude*/code-config`, plus folders added in Settings. Read-only. Archive flags come from `claude-code-sessions/*.json` beside the desktop app's folder. |
| Codex       | `~/.codex/state_*.sqlite` and `thread_history_1.sqlite`, opened read-only; rollout JSONL files and `session_index.jsonl`.                                                                                                                                                       |

- **Which conversations.** Any whose last activity was in the last 7 days, from any
  folder. Older ones are never read.
- **Skipped.** Runs a program started (`claude -p`, `codex exec`), and Codex's own
  subagent threads (approval reviews, spawned helpers). A conversation you archived in
  Claude's desktop app or Codex is hidden on the server, never uploaded.
- **Never read.** Reasoning, images, audio and attachments, tool calls and their
  results, other tools' folders. Only the text of user and assistant messages.
- **Nothing is written** into anyone's Claude or Codex settings: no hooks, no
  configuration.

## What leaves the Mac

Per conversation, as JSON over `https://` (or `http://` to localhost):

- the message text (user and assistant), with each message's id, role and time;
- a title (the tool's own name for the chat, else the first thing you typed, at most
  200 characters), the working folder's absolute path, the git branch;
- the names of files the conversation edited, relative to their git checkout (at most
  50), and the time of its last activity.

It is not sent: the bearer anywhere but the `Authorization` header of requests to the
server you signed in to, your machine's name, or anything about other apps.

### What is hidden before upload

On the Mac, before the text is hashed or sent (best effort; a regular-expression
filter will miss things, so keep secrets out of prompts):

1. Private key blocks.
2. This server's own keys: `hq_` followed by 40 or more URL-safe characters.
3. Vendor keys: `sk-…`, `ghp_/gho_/ghu_/ghs_/ghr_…`, `github_pat_…`, `AKIA…`/`ASIA…`,
   `pscale_tkn_/pscale_pw_…`, `sk_live_/rk_live_…`, `whsec_…`, `xox?-…`, `AIza…`, `xai-…`,
   `gsk_…`, `SG.…`, Slack webhook URLs.
4. `Bearer …` tokens, JWTs, `api_key=…`/`token: …`/`password=…` assignments,
   `NAME_KEY=value` environment lines, `user:password@` in URLs, `Authorization:` /
   `Cookie:` headers, and `curl -u user:pass`.
5. The values of this Mac's own secret-named environment variables (names containing
   KEY, TOKEN, SECRET or PASSWORD), and the helper's own bearer.

The list is the server's (`apps/tasks/redact.ts`), copied as it is: the same 13 patterns in
the same order, every repeat bounded, and every word boundary an ASCII lookaround (so a secret
written right after Chinese, Japanese or accented letters is still hidden). A string that is
itself JSON also has the value under any key named like a secret (`api_key`, `token`,
`secret`, `password`, `authorization`, `cookie`, `private_key`) dropped whole before the
patterns apply; a rewritten object has its keys sorted. Three tests keep the Mac and the server
in step: one reads the server's `test/fixtures/redaction-cases.json` (90 cases) and expects
the same output for each, one runs the server's hostile 500,000-character inputs for timing
(about a third of a second at worst on the author's Mac), and one checks long real credentials
are still hidden.

Blocks a tool injected beside what you typed are cut out of **user** messages before
that: `<system-reminder>` (which carries CLAUDE.md and memory files),
`<environment_context>`, `<instructions>`/`<user_instructions>` (Codex wraps
AGENTS.md in these), `<permissions instructions>`, `<collaboration_mode>` and
`<user-prompt-submit-hook>`. A message that was only such a block is not uploaded. A
block that never closes loses everything after it.

### Who can read it

Everyone signed in to the server can open any synced conversation, and so can the person
who runs the server (who also holds the database). Secret-looking strings are hidden again
by the server for everyone but the conversation's owner, but the owner's copy is stored as
the helper sent it. Archiving a conversation hides it; the server keeps what it was sent.
Plan for that: say so in your own onboarding.

### Limits

One upload body (the whole JSON request) is at most **1,048,576 bytes (1 MiB)**, at most
10,000 messages, and at most 500,000 characters in a message. A longer conversation keeps
its **newest** messages that fit and replaces the rest with one note saying how many
earlier messages were left out; a longer message is cut and ends with a marker. The helper
measures the body with the widest revision and time a request can carry, so it never sends
one the server would refuse.

The labels are cut to what the server takes: title 200, working folder 2,048 and branch 256
characters, 50 file names of up to 512 (file names and the branch go through the same
secret patterns as the text). A single line in a Claude or Codex file over 16 MiB is
skipped, so the one message is lost, not the conversation. A message whose id is over 256 characters is skipped alone, and a timestamp over 64 characters goes as null.

A conversation the server refuses (400, or 413 for size, storage quota or the 5,000-conversation cap) is held: it is not
sent again until its content changes, or for an hour, and Settings keeps showing the
reason. A refusal for one conversation does not stop the others.

## Signing

| `HQ_SIGNING_MODE` | Session sync                                         |
| ----------------- | ---------------------------------------------------- |
| `local` (default) | **Off.** Settings says so in one line. Nothing runs. |
| `team`            | On, as described above.                              |

Why: the helper keeps the sign-in in its **own Keychain item** (service
`<bundle id>.session-sync`), which the app hands it over a pipe, never on the command
line or disk. The Keychain ties an item to the code that made it. A `team` build has the
same signing identity across updates; an ad-hoc `local` build has a new one every build.

What was tried on a Mac (macOS 27.0.1, Xcode 26.6), in `local` mode:

- The helper and the app build, embed and sign ad hoc (`Signature=adhoc`, no team).
- The helper's real Keychain code, built twice as two ad-hoc binaries with one identifier
  (a stand-in for "before and after a rebuild"): the build that saved the item read it
  back; **the other build's read did not return in 5 minutes** (killed), even with the
  no-interaction flag set. In the app that is the helper hanging on a system prompt nobody
  can answer, so a rebuilt `local` helper would be silently stuck.
- Registering the login item (`SMAppService`) in `local` mode **was not tried**: it installs
  a login item on the Mac, which needs its owner's say-so. Unverified.

So `local` leaves sync off. `team` mode is **unverified**: it needs your Apple team, and
was compiled, not run. With a team, the helper should read its own item across updates;
the helper stops waiting after 5 seconds and says "Sign-in unavailable" if it cannot.

Debug builds (`DerivedData`, a worktree) never register the login item or stop another
install's helper, even in `team` mode, unless `HQ_ALLOW_SYSTEM_REGISTRATION=1`;
`HQ_NO_SYSTEM_REGISTRATION=1` (and any unit-test host) blocks all of it.

### Names

Everything is named from the app's bundle id (`BUNDLE_ID_PREFIX`, `Config/Signing.xcconfig`),
so a fork never shares state with another build. With `org.example.hq`:

- helper bundle id `org.example.hq.session-sync`, embedded at
  `HQ.app/Contents/Library/LoginItems/HQSessionSync.app`;
- Keychain service `org.example.hq.session-sync`, account `<server>/<person id>`;
- folder `~/Library/Application Support/org.example.hq/session-sync/` (`config.json`,
  `status.json`, `helper.lock`, `helper.stamp`), mode 0700/0600.

## What a server must provide

The helper calls these with the device bearer; the app adds the last row. A server that
answers 404 for them gets "The server does not support session sync" in Settings and
nothing else. `:provider` is `claude` or `codex`; `:source` is the tool's own conversation
id (`[A-Za-z0-9_-]{1,128}`). Only the **owner** may call the first six.

| Call                                                  | Body → reply                                                                                                                                                                |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /v1/agent-sessions/:provider/:source`            | → `{"session": {sha256, revision, message_count, activity_at, files_touched, archived_at}}`, or 404                                                                         |
| `PUT /v1/agent-sessions/:provider/:source`            | `{base_revision, snapshot, activity_at?, files_touched?}` → `{status, session, stored_verbatim?}`. 409 when `base_revision` is not the stored revision. Body at most 1 MiB. |
| `PUT /v1/agent-sessions/:provider/:source/activity`   | `{sha256, activity_at?, files_touched?}` → `{status: "unchanged", session}`. 409 when `sha256` is not the stored one.                                                       |
| `GET /v1/agent-sessions/:provider/:source/transcript` | → the stored snapshot, exactly as sent (the helper compares it to what it sent)                                                                                             |
| `PUT /v1/agent-sessions/:provider/:source/archive`    | `{archived: bool}` → `{session}`                                                                                                                                            |
| `GET /v1/agent-sessions/by-id/:id/transcript`         | (the app) → `{messages: [{id, role, text, timestamp}]}` for any member who may open it; secrets hidden unless the reader owns it                                            |

The snapshot is `{projection: "conversation-text-v1", title, cwd, git_branch, task_ref: null,
messages: [{id, role: "user"|"assistant", text, timestamp}]}`. Its `sha256` is the SHA-256
of the canonical JSON array `[projection, title, cwd, git_branch, task_ref, [[id, role, text,
timestamp], …]]` (compact, `/` unescaped, keys in order, `null` for a missing value). The
helper reads the receipt (`sha256` and `message_count` must match what it sent) and the
transcript back; `stored_verbatim: true` skips the second.

The helper redirects nowhere (a redirect is an error) and sends only to the address the app
signed in to: `https://` anywhere, or `http://` for `localhost`, `127.0.0.1` and `::1`.

## Tests

- `HQSessionSyncTests-Mac` (scheme of the same name): the helper's code with no host app,
  against a fake server in-process: collector, redaction, injected blocks, the 1 MiB
  boundary, the transport (revisions, the activity route, read back, archive, redirects),
  config and pause logic, titles, the keeper.
- `HQTests`: `SessionSyncAgentTests` (when the app may touch the system, the order of the
  notice, sign-in hand-off and start, the notice's words) and `LiveSessionSyncTests`
  (below).
- `LiveSessionSyncTests` drives the helper's real transport as one person against a real
  server and reads the conversation as another through the app's real `HQClient`. It needs
  `HQ_LIVE_SERVER`, `HQ_LIVE_KEY_A` and `HQ_LIVE_KEY_B` like `LiveServerTests`
  (`TEST_RUNNER_` prefix with `xcodebuild`), and is skipped without them.
