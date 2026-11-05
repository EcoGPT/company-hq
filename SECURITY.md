# Security

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub: open the
repository's **Security** tab and choose **Report a vulnerability**. Include the
steps to reproduce, what an attacker gains, and the commit you tested.

Fixes land on `main`; there are no release branches to backport to.

## What counts

HQ runs as one process that a team hosts for itself, so the interesting
boundaries are between people on the same HQ:

- a member reading or posting in a conversation they aren't in, directly, over
  MCP, over the socket, or by asking the assistant
- a member doing something that needs the admin role
- a key that still works after it is revoked
- a connector secret reaching a prompt, a tool result, a log, or a host other
  than the connector's API
- an uploaded file or picture that a browser would run or show as a page, or
  any request that reads or writes files outside HQ's data folder

Out of scope: what an admin can do with their own HQ (they can edit its code),
and what the configured model provider sees (every turn is sent to it).

## Keys, devices and limits

- A **sign-in key** (`bun hq setup`, `bun hq invite`, or the one the app's
  Settings gets for a new person) can do one thing: trade itself for a device
  bearer at `POST /v1/enroll`. An invite key does that for `HQ_INVITE_TTL_DAYS`
  (default 7) days after it was made, used or not. A setup key does not expire. Neither is ever a bearer: both
  are refused everywhere but enroll, and `bun hq invite <handle>` ends a person's
  old invite and setup keys (their devices carry on). A device's bearer, a key
  from `bun hq key` and an MCP key cannot enroll, so revoking a device ends that
  device. Keys are stored only as SHA-256 hashes. The server makes every key (256
  random bits); nobody chooses one, and `POST /v1/keys` refuses a `key` field.
- Adding people, promoting, removing and restoring are admin work that needs a
  signed-in device: an MCP key or `bun hq key` key acts as its person in rooms
  and tools (`read,send` is their whole access except this) but gets
  `admin_only` here. The acting admin is checked again once the request body has
  arrived, and a change that leaves no admin who signs in is `last_admin`. A
  removed admin comes back as a member. `POST /v1/keys` adds new people only;
  giving someone who exists a new key is the operator's `bun hq invite`.
- Enrolling checks the key first and always admits a good one. Only wrong keys
  count: 20 per 5 minutes per address (an IPv6 caller is its /64), and 200 per 5
  minutes for the whole server, so a stranger cannot lock people out of signing
  in but cannot guess quickly from many addresses either. Its body is capped at
  4 KB, every other JSON body at 1 MB; only the upload routes take
  `HQ_MAX_UPLOAD_MB`, and they stream to disk.
- Removing a person freezes them: every key and device stops at once, and the
  row and their messages stay. Restoring needs a fresh key.
- Files are never deleted, so each person has an upload quota
  (`HQ_UPLOAD_QUOTA_MB`, default 2048) and at most 20 uploads not yet attached to
  a message. Uploads in flight hold back the room they may still fill, so
  uploads at once cannot pass the quota. Pictures are checked by their first
  bytes; SVG is refused.
- A socket takes frames up to 64 KB, a person has at most 10, typing and sync
  requests are paced per connection, and a person's replays share 2,000
  messages per 10 seconds across all their sockets.

Known and accepted: a member can delete (archive) any group but General, and add
anyone to any group; commands run from a separate process
(`bun hq invite`, `bun hq chat`) do not reach sockets already open; the
automation and connector admin routes still accept an admin's `bun hq key` key
(scripts use them); a meeting recording is held in memory while it is read (up
to 100 MB).

## Push notifications

Off unless the host sets all four `HQ_APNS_*` values ([docs/push.md](docs/push.md)).

- **The key** is an Apple push key (`.p8`) that can send notifications as the
  host's app. It is read from `HQ_APNS_KEY_FILE` and is never stored in the
  database or logged (only its id is). Keep the file outside the data folder
  and out of git (`*.p8` and `*.pem` are ignored by git and Docker), and
  readable by HQ alone; mount it read-only under Docker. If one leaks, revoke it
  in your Apple account and make another.
- **What reaches Apple** is, per push: the device token, the conversation and
  message ids and, with the default `HQ_PUSH_PREVIEW=full`, the sender's name,
  the room's name and the first 240 characters of the message. `hidden` sends
  the sender's name and "New message". Apple's servers and the phone's lock
  screen see what is sent; HQ does not encrypt it end to end. A read sync
  carries ids only.
- **Who** a push goes to follows the socket's rule: a device of a person who is in
  the room now, never the author, a removed person, a revoked device or an
  archived room. A device token belongs to one device, so one that changes hands
  moves with the last report. A push sent to a person who should not see it counts
  as a vulnerability.
- Device tokens are kept in the database (`push_tokens`), one row per device, and
  are removed at sign-out. They are not logged.

### Ring pushes

- **What reaches Apple** for a ring: the device token, the call and conversation
  ids, the caller's name, when the ring ends and, with `HQ_PUSH_PREVIEW=full`,
  the room's title. `hidden` keeps the title back, as it does for messages.
- **Who** is rung: only the people the call names, and each only while they are
  in the room (checked again just before the push is sent), never a removed
  person, a revoked device or an archived room. A ring that has run out, or whose
  call has ended, is not sent. A ring that reaches a person outside the room
  counts as a vulnerability.
- The phone's VoIP token is kept beside its alert token in `push_tokens`, with
  its own environment (a phone that refused notifications still rings), moves
  with the last device to report it like the alert token, and is removed at
  sign-out. It is not logged.

## Calls

Off unless the host sets `HQ_CALLS_SFU_APP_ID` and a secret ([docs/calls.md](docs/calls.md)).

- **The secret** is the host's Cloudflare Realtime SFU App Secret. It is read from
  `HQ_CALLS_SFU_SECRET` or the file `HQ_CALLS_SFU_SECRET_FILE`, never stored in the
  database, never sent to an app and never logged (the app id is). The relay's address
  comes from the host's settings, never from a request. If it leaks, rotate it in the
  Cloudflare dashboard.
- **One relay app serves every call** on the server, and a relay track is reached by a
  session id and a track name. So HQ names every track itself (`<device id>-<source>`),
  passes on a subscribe only for tracks in the caller's own call right now, and closes or
  unsubscribes only on the caller's own stored session. It records what each seat pulls,
  and whatever takes a seat out (leaving, a rejoin, the sweep, a revoked device, a removed
  person) closes what it sent and what it pulled at the relay. Pulling media from a call
  you are not seated in counts as a vulnerability.
- **Call frames** go only to the room's members now who have not been removed.
- **Who** may be in a call follows the room: members only, checked on every request, and an
  archived room is closed. Seats are for signed-in devices; a script or MCP key cannot take
  one. A revoked device, a removed person and someone who left the room lose their seats,
  and a device not heard from for 45 seconds is taken out.
- **Limits:** 64 KB per call request, 3 published tracks and 64 subscribed tracks per
  request, `HQ_CALLS_MAX_PARTICIPANTS` devices per call (20), 10 new calls per person
  in 10 minutes, and 20 rejoins per device a minute.
- **What leaves the server:** WebRTC offers and answers, track names and session ids go to
  Cloudflare's API. Audio and video go from the devices through Cloudflare's relay; WebRTC
  encrypts them on the way, but the relay can read them. Names, messages and room titles do
  not go to Cloudflare.

## Call recordings and transcripts

Every call is recorded per person and, when the host has set up speech-to-text, transcribed
after it ends ([docs/calls.md](docs/calls.md#recordings-transcripts-and-recaps)). The app says so
before anyone joins.

- **Who** can open a call's record, transcript and recordings: the members of its room now,
  checked on every request, like its messages. Reading the record and transcript takes any of
  the member's keys, as reading their chat does. Downloading a recording takes the app's own
  sign-in (a device): a script or MCP key gets 403, so a key handed to an outside agent reads
  what was said but cannot pull the audio. Only a signed-in device seated in the live call can
  send audio, and only its own seat's.
- **What leaves the server:** each recorded piece goes to the host's speech-to-text provider
  after the call, and the transcript (names, times and what was said) to the host's chat model
  for the recap. Nothing of it goes to Cloudflare.
- **Untrusted text:** a transcript is what people said. The recap prompt tells the model to
  treat it as quoted text and never follow instructions in it; a meeting's recap can still file
  tasks from what was said, as a pasted transcript can.
- **Limits:** audio frames of at most one second, audio more than 10 seconds ahead of real
  time dropped, 4 hours per person per call, `HQ_CALLS_RECORDING_QUOTA_MB` (10,240) for all
  call audio, and retranscribes at 3 an hour per call and 10 an hour per person, counted in the
  database, since each one costs the host money.
- **Never deleted:** recordings stay on disk like every other file. A host who must remove one
  deletes it from `files/calls/` by hand.

## Widgets

The Mac app's desktop widgets use a **widget key** ([docs/widgets.md](docs/widgets.md)). What it
can and cannot do:

- **Can:** read the summary of its one person: their own tasks that they may see (titles,
  statuses, due dates, board names, comment counts), and their name and picture id.
- **Cannot:** anything else. It is not an API key and is refused by every other route, the
  socket and `/mcp`. It cannot send, complete or change a task, read a room, or mint
  another key (that needs a device bearer). The widgets have no write paths.
- **Where it lives:** the app puts it in the App Group folder it shares with the widget
  extension, readable only by code signed by the same team. The device bearer stays in the
  Keychain and never reaches the extension. Anyone who can read that folder (the signed-in
  person's own account) can read the summary with the key, and no more.
- **Kept as:** a SHA-256 hash in its own table, compared in constant time; shown once. One
  live key per device; minting again, `DELETE /v1/widgets/key`, revoking the device or
  removing the person ends it. Signing out asks the server to end it on a best-effort basis:
  the app empties the shared folder first, but if the Mac is offline the request is not
  retried and the key stays live until the device is revoked. It has no expiry otherwise.
- A summary or a key shown to a person who should not have it counts as a vulnerability.

## Agent sessions

A helper app on a person's Mac can copy their Claude Code and Codex conversations to HQ ([docs/sessions.md](docs/sessions.md)).
It does nothing unless someone installs and signs it in.

- **What is stored**, per conversation: its title, the working folder (an absolute path on that Mac), the git branch, the
  text of the user and assistant messages, and the workspace-relative paths of files it touched, in the database. Only the
  latest snapshot is kept. Tool calls, reasoning, pictures and files are not sent. A person's total is held to
  `HQ_TRANSCRIPT_QUOTA_MB` (default 512), and to 5,000 sessions. Archived conversations count and nothing deletes one. Past
  the quota a person gets 413 `quota_exceeded`, until the person running the server raises `HQ_TRANSCRIPT_QUOTA_MB` (it
  applies at once) or removes sessions. At 5,000 sessions it is 413 `session_limit`, which only removing sessions lifts.
- **Who reads it**: every member can list and open every other member's synced conversation. Archiving a conversation hides
  it from everyone but its owner. A removed person's conversations stay readable, as their messages do. The people who run
  the server can read all of it, and so can anyone with a copy of the database or a backup.
- **Secret hiding is best effort.** The helper hides credential-shaped strings before it uploads, and the server hides them
  again on every other member's read (`apps/tasks/redact.ts`), and never shows them the working folder or the file list.
  No list of patterns catches every secret: a key in a form it does not know is stored and shown. Tell people to treat
  anything typed into a coding chat as readable by the whole team.
- **Only a signed-in device** reaches these routes. A script key (`bun hq key`) or an MCP key is refused, and no MCP tool or
  assistant prompt returns conversation text, so an agent holding a key cannot read other people's chats. Titles and
  intents an agent reports over MCP are the agent's own notes and stay separate.
- Nothing deletes a conversation: archiving only hides it. Removing one for good is a database edit by whoever runs the
  server. Foreign keys are on and nothing cascades, so delete a session's text, then its task links, then the session
  (`<id>` is `agent_sessions.id`):

  ```sql
  DELETE FROM agent_session_transcripts WHERE session_id = '<id>';
  DELETE FROM agent_session_tasks WHERE session_id = '<id>';
  DELETE FROM agent_sessions WHERE id = '<id>';
  ```

## Prompt injection

The assistant reads text nobody vetted (messages, docs, meeting transcripts,
GitHub issues and files), and that text can tell it to call tools. What limits it:

- In a room, tools read only conversations everyone in that room is in; over
  MCP, only the key holder's. Only people's messages start a turn, and a turn
  gets at most `maxHops` (default 24) rounds of tool calls.
- The bundled GitHub connector only reads. The bundled apps have no open
  web-fetch tool, and `fetchPublic` (for apps) refuses private, loopback and
  link-local addresses.

It can still act: post, DM anyone on this HQ, file tasks, and schedule
meetings, which adds the attendees to the room. So injected text can try to
send what it read to someone else. A connector's token is shared by all of HQ.
Connect services with least-scope, read-only tokens, and don't connect one
whose data some members shouldn't see.
