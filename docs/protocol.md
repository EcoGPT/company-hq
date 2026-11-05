# The app protocol

What the native HQ app ([`clients/apple`](../clients/apple)) speaks to this
server: sign-in, people, chat, and one live socket. It is JSON over HTTP plus
one WebSocket, all under `/v1`. The code is in `src/wire/` and
`src/realtime/socket.ts`; the tests in `test/wire.test.ts`,
`test/socket.test.ts` and `e2e/protocol.e2e.ts` are the executable version of
this page.

The wire only grows. Fields are added, never removed or repurposed, and a
client ignores frames and keys it does not know. `wire_version` (now `1`) is
bumped only if that ever has to change.

## Conventions

- Keys are `snake_case`. Times are ISO 8601 strings (`2026-10-31T09:41:00.000Z`).
- Ids are uuidv7 strings. They sort as plain strings in the order they were
  made, even within one millisecond, because clients compare them as strings to
  find the newest message (`src/core/ids.ts`).
- Every non-2xx answer is `{"error": "<code>"}`. The codes below are stable;
  anything else a client sees is a bug.
- Deleting or leaving answers `{"ok": true}`; a bare 204 would not decode.
- Anything a person is not allowed to see answers `404 not_found`, the same as
  something that does not exist. That includes an archived room, which has no
  members to anyone.
- Request bodies are JSON unless a route says raw bytes. A body that does not
  parse or fit is `400 invalid_body`.

## Sign-in

`POST /v1/enroll` (no bearer):

```json
{ "key": "hq_…", "device_name": "Ada's MacBook", "person_name": "Ada" }
```

`key` is a sign-in key: from `bun hq setup`, from `bun hq invite`, or one an
admin got for a new person in the app's Settings (`POST /v1/keys`). Nothing else enrolls: not a
device's bearer, not a key from `bun hq key`, not a key from the MCP keys card.
An **invite** key adds devices (a Mac and a phone, say) until `HQ_INVITE_TTL_DAYS`
(default 7) days after it was made, whether or not it was used; after that an
admin makes a new one. It is never a bearer: every other route, `/mcp` and the
socket refuse it with `401 unauthorized`, because devices have bearers of their
own. A **setup** key (the first admin's) does not expire and is no bearer
either; `bun hq invite <handle>` for that person ends it. `person_name` is
accepted and ignored: the person already exists, named by whoever added them.
The first admin is whoever ran `bun hq setup`.

`201`:

```json
{ "bearer": "hq_…", "device_id": "…", "person": { … }, "wire_version": 1 }
```

Every enroll makes a new device with a bearer of its own. A bearer is an
ordinary API key (stored only as a SHA-256 hash, shown once), so it also works
on `/mcp`. Send it as `Authorization: Bearer <bearer>` on every route and on the
socket; a key in the query string is ignored.

| Status | Error               | When                                                                                                                                            |
| ------ | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 400    | `invalid_body`      | missing key, names too long                                                                                                                     |
| 401    | `invalid_key`       | not a live sign-in key (including a device bearer or an API key)                                                                                |
| 401    | `invite_expired`    | an invite key more than `HQ_INVITE_TTL_DAYS` old; ask an admin for a new one                                                                    |
| 413    | `payload_too_large` | a body over 4 KB                                                                                                                                |
| 429    | `rate_limited`      | more than 20 wrong keys in 5 minutes from one address, or 200 from all addresses together; has `retry_after` seconds and a `Retry-After` header |
| 503    | `not_configured`    | nobody has been added yet; run `bun hq setup`                                                                                                   |

The key is checked first, and a good one is always let in. Only wrong keys count
toward the limit, per caller address, so junk from a shared address can slow
guessing but never keeps a real person out. The server as a whole answers 200
wrong keys per 5 minutes, which is what stops guessing from many addresses; a
correct key is never counted. An IPv6 caller is its whole /64. Behind a reverse
proxy you run, set `HQ_TRUST_PROXY=1` so the last `X-Forwarded-For` entry is
used; without it every caller shares the proxy's address.

A revoked device, or any bad bearer, gets `401 {"error":"unauthorized"}` and its
open sockets close with code `4001`. Revoke one device with
`POST /v1/devices/:id/revoke` (its owner, or an admin), or everything a person
holds with `bun hq revoke <handle>`.

## Shapes

**Person**: `id`, `name`, `kind` (`person`, `bot` for the built-in assistant,
`service`), `is_admin`, `avatar_id` (or null), `removed_at` (when an admin
removed them, else null). Removing freezes: the row, their messages and their
place in rooms stay, and their keys and devices stop; nothing is deleted.

**Conversation** (each person's own copy): `id`, `kind` (`dm` or `group`; a
room is a group), `title` (null for a DM or an unnamed group), `member_ids`,
`created_at`, `last_message`, `unread_count`, `read_marks`
(`[{person_id, last_read_message_id}]`), `room_slug` (set for General: a
standing room cannot be renamed, left or deleted), `avatar_id`.

**Message**: `id`, `conversation_id`, `sender_person_id`, `sender_name`,
`content`, `created_at`, `edited_at`, `deleted_at`, `edit_history`
(`[{content, edited_at}]`, oldest first, the last 20 versions at most; the
server keeps every version, and a conversation's `last_message` carries none), `reactions`
(`[{emoji, person_ids}]`), `attachments`, `reply_to`
(`{id, content, sender_name}` or null), `kind`, `via`. An unsent message keeps
its id and position but has empty `content`, no reactions, no attachments and no
history; the text stays in the database and is never handed out again.

**Attachment**: `id`, `file_name`, `content_type`, `byte_size`, `width`, `height`.

`test/fixtures/swift-wire.json` lists the keys the app's Swift structs decode.
`test/wire-decode.test.ts` checks every Person, Conversation, Message, enroll
response and frame the server emits against it: no key the app ignores, none it
needs missing. Regenerate the fixture from the app's `Wire.swift` when its
structs change.

## Routes

All need a bearer except enroll and `/healthz`.

| Method and path                             | Body                                                                   | Answer                                               |
| ------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------- |
| `GET /v1/people`                            |                                                                        | `{people}`                                           |
| `GET /v1/me`                                |                                                                        | `{person}`                                           |
| `GET /v1/calls`                             |                                                                        | `{calls, meetings, ringing}`; see [Calls](#calls)    |
| `POST /v1/keys`                             | `{person_name}` (admin): adds a new person and makes their sign-in key | `{ok, person_name, key}`; 201; the key is shown once |
| `POST /v1/people/:id/role`                  | `{is_admin}` (admin)                                                   | `{person}`                                           |
| `POST /v1/people/:id/remove`                | (admin) freezes: keys and devices stop, nothing is deleted             | `{person}`                                           |
| `POST /v1/people/:id/restore`               | (admin) unfreezes; they need a fresh key                               | `{person}`                                           |
| `GET /v1/mcp-keys`                          |                                                                        | `{keys}`: yours, with `scopes` as `"read,send"`      |
| `POST /v1/mcp-keys`                         | `{label, scopes: ["read","send"]}`                                     | `{id, key, label}`; 201; the key is shown once       |
| `DELETE /v1/mcp-keys/:id`                   | your own key, or any if you are an admin                               | `{ok}`                                               |
| `PUT /v1/me/avatar`                         | raw PNG, JPEG, HEIC or WebP, up to 5 MiB                               | `{person}`                                           |
| `DELETE /v1/me/avatar`                      |                                                                        | `{person}`                                           |
| `GET /v1/avatars/people/:person/:avatar`    |                                                                        | the picture; only the current id is served           |
| `GET /v1/conversations`                     |                                                                        | `{conversations}`, newest activity first             |
| `POST /v1/conversations`                    | `{kind:"dm", person_id}` or `{kind:"group", person_ids, title?}`       | `{conversation}`; 201 new, 200 an existing DM        |
| `GET /v1/conversations/:id`                 |                                                                        | `{conversation}`                                     |
| `PATCH /v1/conversations/:id`               | `{title}` (null or empty clears it)                                    | `{conversation}`                                     |
| `DELETE /v1/conversations/:id`              |                                                                        | `{ok}`; closes the room for everyone                 |
| `POST /v1/conversations/:id/members`        | `{person_ids}`                                                         | `{conversation}`                                     |
| `DELETE /v1/conversations/:id/members/me`   |                                                                        | `{ok}`                                               |
| `PUT /v1/conversations/:id/image`           | raw PNG, JPEG, HEIC or WebP, up to 5 MiB                               | `{conversation}`                                     |
| `DELETE /v1/conversations/:id/image`        |                                                                        | `{conversation}`                                     |
| `GET /v1/avatars/conversations/:id/:avatar` |                                                                        | the picture; members only                            |
| `GET /v1/conversations/:id/messages`        | query `limit` (1 to 100, default 50), `before` or `after` a message id | `{messages}`, oldest first                           |
| `POST /v1/conversations/:id/messages`       | `{client_msg_id, content, reply_to_message_id?, attachment_ids?}`      | `{message}`; 201, or 200 for a retry                 |
| `PATCH /v1/messages/:id`                    | `{content}` (author only)                                              | `{message}`                                          |
| `DELETE /v1/messages/:id`                   | (author only) unsend                                                   | `{message}`                                          |
| `POST /v1/messages/:id/reactions`           | `{emoji}` (1 to 8 characters); toggles                                 | `{message}`                                          |
| `POST /v1/conversations/:id/read`           | `{message_id}`                                                         | `{last_read_message_id}`; never moves back           |
| `POST /v1/conversations/:id/unread`         |                                                                        | `{conversation}`; private to you                     |
| `GET /v1/search?q=`                         | at least 2 characters                                                  | `{messages}`, up to 50, only where you are a member  |
| `POST /v1/conversations/:id/attachments`    | the file's raw bytes                                                   | `{attachment}`                                       |
| `GET /v1/attachments/:id`                   |                                                                        | the file                                             |
| `POST /v1/devices/:id/revoke`               |                                                                        | `{ok}`                                               |
| `POST /v1/devices/apns-token`               | `{environment?, status?, token?}` (device bearer); see push.md         | `{ok}`; 400 `invalid_body`                           |
| `DELETE /v1/devices/apns-token`             | (device bearer) sign-out: clears this device's push tokens             | `{ok}`                                               |

Without `before` or `after` a page is the newest `limit` messages; `before`
pages back from a message. Send with the same `client_msg_id` again after a
lost answer and you get the first message back; the same id in another
conversation is `409 client_msg_id_reused`. A `reply_to_message_id` from another
conversation is dropped. Message text is at most 16,384 bytes; `400 empty_message`
if there is no text and no attachment.

Errors you will meet on chat routes: `not_found` (404, not a member, or no
such thing), `forbidden` (403, editing or unsending someone else's message),
`message_deleted` (409), `person_not_found` (404), `not_a_group` and
`standing_room` (409), `invalid_attachment` (400). Any JSON body over 1 MB is
`413 payload_too_large`.

On the admin routes (`POST /v1/keys`, `POST /v1/people`, `/v1/people/:id/role|remove|restore`)
a member gets `403 admin_only`, and so does an admin's MCP key or `bun hq key`
key: admin work needs a signed-in device, checked again once the request body
has arrived. Beyond that: `key_not_allowed` (400, `POST /v1/keys` has a `key`
field: the server makes every key, and refuses one rather than ignore it),
`person_exists` (409, someone already has that name or handle, the assistant
included: `POST /v1/keys` adds new people only, and giving an existing person a
new key is the operator's `bun hq invite <handle>`), `person_removed` (409,
restore them first), `not_yourself`, `already_removed` and `not_removed` (409),
`last_admin` (409, that would leave nobody who signs in as an admin), and
`scope_unsupported` (400, an MCP key can only be `read` and `send`, which is the
person's whole access except these admin routes). Removing an admin makes them a
member: restored, they must be promoted again.

## Attachments

Upload the file as the request body with its type in `Content-Type` and its
name, percent-encoded, in `x-hq-file-name`; images may add `x-hq-image-width`
and `x-hq-image-height`. The limit is `HQ_MAX_UPLOAD_MB` (default 100); over it
is `413 file_too_large`, an empty body is `400 empty_file`. Bytes are streamed to
`<data folder>/files/` and never held in memory. The file name loses control and
right-to-left characters.

Files are never deleted, so each person is limited instead. Uploads arriving at
once share the quota: each holds back the most it can still add (its declared
length, else the per-file limit, but never more than the room left) until it
ends, so five at once cannot together pass it.

| Status | Error              | When                                                                                                    |
| ------ | ------------------ | ------------------------------------------------------------------------------------------------------- |
| 413    | `quota_exceeded`   | the person has uploaded `HQ_UPLOAD_QUOTA_MB` (default 2048) in all, sent or not, and this would pass it |
| 429    | `too_many_uploads` | 20 of their uploads are not attached to a sent message yet; send one, then upload again                 |

Profile and group pictures are PNG, JPEG, HEIC or WebP (never SVG), checked by
their first bytes after they are streamed to disk and capped at 5 MiB.

An upload is not attached to anything until a message lists its id in
`attachment_ids`. Until then only the uploader can fetch it; a message can only
claim the sender's own unclaimed uploads from the same conversation (up to 10).

A download needs the bearer and membership in the conversation, and is refused
once its message is unsent. It is always served as a download, never a page:
`Content-Disposition: attachment`, `X-Content-Type-Options: nosniff` and a
`sandbox` content security policy. HTML, SVG, XML and script types are handed
out as `application/octet-stream`.

## The socket

`GET /v1/ws` with `Authorization: Bearer <bearer>` (a request without
`Upgrade: websocket` gets 426, a bad bearer 401).

- **hello**: sent first. `device_id`, `person_id`, `online_person_ids`,
  `wire_version`.
- **Keepalive**: the client sends the text `ping`; the server answers `pong`. A
  socket that sends nothing for 75 seconds is closed (`4002`). A device that
  reconnects closes its own older socket that has gone quiet (`4000`); one that
  is still pinging stays. A revoked device is closed with `4001`, including
  when it was revoked from another process (`bun hq revoke`): the server
  notices on the next ping or the next frame.
- **Limits**: a frame over 64 KB closes the socket. A person keeps at most 10
  connections; the 11th closes the oldest with `4000`. Each connection has its
  `typing` frames passed on once a second and its `sync` requests served once
  every 2 seconds; the excess is dropped. A dropped `sync` is still answered
  with `sync_complete` and `is_partial: true`, so the app is not left waiting.
  The next page of a replay (a `sync` from exactly the last id of a short one)
  is not held to that pace. A person's replays are also budgeted together, over
  all their sockets: 2,000 messages per 10 seconds. Past it a `sync` is answered
  the same way, with no data, and the app (which stops when a replay does not
  move its cursor) asks again on its next connect or foreground.

Client frames (JSON text):

- `{"type":"sync","since_message_id":"…"}`: replay what was missed (the key is
  left out when the client has no cursor). Answered with `sync_batch` frames of
  up to 100 messages, oldest first, across every open conversation the person
  is in, at most 500 in all, then always `sync_complete`.
  `is_partial` is true when the 500 were used up: ask again from the newest id
  received. Replay carries new messages only; edits, unsends and tapbacks made
  while away come from re-reading the conversation.
- `{"type":"typing","conversation_id":"…"}`.
- `{"type":"call_heartbeat","call_id":"…"}`: keeps this device's seat in a call
  (see [Calls](#calls)). Not answered.
- Anything else gets `{"type":"error","code":"invalid_frame"}`; the socket
  stays open.

Server frames, each sent only to people who are members of the conversation it
is about (or to everyone, for people):

| `type`                 | Payload                                                     | When                                                                                  |
| ---------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `message`              | `message`                                                   | a new message, to the sender's sockets too                                            |
| `message_updated`      | `message`                                                   | an edit, an unsend or a tapback                                                       |
| `conversation_updated` | `conversation` (that person's copy)                         | a new room, a rename, members or a picture changed, mark unread                       |
| `conversation_removed` | `conversation_id`                                           | deleted, or you left                                                                  |
| `typing`               | `conversation_id`, `person_id`, `expires_at` (5 seconds on) | someone typed; the typist's own sockets get it too                                    |
| `read`                 | `conversation_id`, `person_id`, `last_read_message_id`      | a read position moved                                                                 |
| `presence`             | `person_id`, `is_online`                                    | a person's first socket opened or last one closed (to everyone)                       |
| `person_updated`       | `person`                                                    | a picture changed, or a person was added (to everyone)                                |
| `bot_state`            | `conversation_id`, `person_id`, `label`, `expires_at`       | the assistant is working (`"Thinking"`, a tool's label); `label` null when it is done |
| `sync_batch`           | `messages`                                                  | in reply to `sync`                                                                    |
| `sync_complete`        | `is_partial`                                                | ends a `sync`                                                                         |
| `error`                | `code`                                                      | `invalid_frame`                                                                       |

An archived room delivers nothing, even to someone an event names.

### Frames from features

The call frames are listed under [Calls](#calls), and the frames of the planning, library and
meetings apps in their own guides. A feature sends its frames through the `frame` bus event
(`src/core/events.ts`) and takes a client frame through `onClientFrame` on the socket; an
app's `app.event` bus events stay inside the server.

## Calls

Live calls, with media through the host's own relay: [calls.md](calls.md) is the host's guide.
Every call route needs a member of the call's room (anyone else, or an archived room, gets 404).
Every `POST` and `PUT` needs a signed-in device (403 `device_only` for a script or MCP key),
and the media and flag routes need that device seated in the live call (409 `not_in_call`). A
relay failure is 502 with `sfu_unavailable`, `sfu_rejected` or `sfu_bad_response`; a request
that a rejoin overtook is 409 `session_superseded`. Bodies are capped at 64 KB.

| Method and path                         | Body                                                                                                        | Answer                                                                                                 |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `GET /v1/calls`                         |                                                                                                             | `{calls, meetings, ringing}`: the 50 latest calls in rooms you are in, ended ones too                  |
| `POST /v1/calls`                        | `{kind: "conversation", conversation_id}` or `{kind: "meeting", meeting_id?}`; `client_build`               | `{call, session_id, generation, capabilities: ["quiet_tracks"]}`; join and rejoin                      |
| `GET /v1/calls/:id`                     |                                                                                                             | `{call}`; also this device's heartbeat                                                                 |
| `POST /v1/calls/:id/publish`            | `{session_description: {sdp, type: "offer"}, tracks: [{mid, source: "mic"\|"cam"\|"screen", is_enabled?}]}` | `{session_description, refused: [{mid, source, error_code}]}`                                          |
| `POST /v1/calls/:id/subscribe`          | `{tracks: [{session_id, track_name}]}` (up to 64)                                                           | `{tracks: [{mid?, track_name?, error_code?}], requires_immediate_renegotiation, session_description?}` |
| `PUT /v1/calls/:id/renegotiate`         | `{session_description: {sdp, type: "answer"}}`                                                              | `{ok}`                                                                                                 |
| `POST /v1/calls/:id/unsubscribe`        | `{mids}`                                                                                                    | `{ok}`                                                                                                 |
| `POST /v1/calls/:id/unpublish`          | `{mids, sources}`                                                                                           | `{ok}`                                                                                                 |
| `POST /v1/calls/:id/state`              | any of `is_muted`, `is_camera_on`, `is_screen_sharing`, `is_hand_raised`                                    | `{call}`; flags left out are left alone                                                                |
| `POST /v1/calls/:id/decline`            | `{}`                                                                                                        | `{ok}`; stops your ring on all your devices                                                            |
| `POST /v1/calls/:id/leave`              | `{}`                                                                                                        | `{ok}`; the call ends with its last seat                                                               |
| `GET /v1/calls/:id/record`              |                                                                                                             | `{call, summary?, recap_at?, transcript, recordings}`; see below                                       |
| `GET /v1/calls/:id/recording/:deviceId` |                                                                                                             | that device's whole recording as a WAV; a device only; 404 if it has none                              |
| `POST /v1/calls/:id/retranscribe`       | `{}`                                                                                                        | `{ok: true}` once started; see below                                                                   |
| `WS /v1/calls/:id/transcribe`           | binary audio frames, text `ping`                                                                            | `pong`; the audio feed, see below                                                                      |

- **Joining.** `kind: "conversation"` joins the room's live call (a meeting's call held in the room
  counts) or starts one, which does not ring in a room made for a meeting. `kind: "meeting"`
  with a `meeting_id` joins that meeting's call in its room, adding you to the room; a cancelled
  meeting is 409 `meeting_cancelled`, one you cannot see 404 `meeting_not_found`. With no
  `meeting_id` it is a Quick Call: a meeting made now, with a room of its own. Joining again
  from the same device is a rejoin: `generation` counts up, its flags are cleared and its old
  tracks end. A device sits in one call at a time. Starting calls is limited per person
  (429 `too_many_calls`) and rejoining per device (429 `too_many_rejoins`); a full call is 409 `call_full`. Calls off: 503 `not_configured`.
- **`call`** is `{id, conversation_id, kind, meeting_id, title, started_by_person_id, started_at,
ended_at, participants, tracks}`. `participants` holds one seat per device, `{device_id,
person_id, session_id, is_muted, is_camera_on, is_screen_sharing, is_hand_raised, joined_at,
left_at}`, including seats that left. `tracks` holds the live tracks, `{track_name,
session_id, device_id, person_id, source, created_at, ended_at}`. A camera or screen track
  is listed only while its flag is on.
- **Tracks** are named by the server, `<device_id>-<source>`. Subscribe takes only tracks in the
  call's roster now; any other answers `error_code: "unknown_track"`. Unsubscribe and unpublish
  act on the caller's own session.
- **Liveness.** The app beats every 15 s with the socket's `call_heartbeat` frame and by reading
  `GET /v1/calls/:id`. A seat not heard from for 45 s is taken out of the call.
- **`ringing`** lists `{call, caller_name, conversation_title, expires_at}` for each call ringing
  you now. A new call in a direct message or group rings its other people for 45 s; meetings
  never ring.
- **The audio feed.** `WS /v1/calls/:id/transcribe` with the device's `Authorization: Bearer`
  header. It is refused before the upgrade unless a signed-in device holds a present seat in the
  live call (401, 403 `device_only`, 404, 409 `not_in_call`). Binary frames are 16 kHz mono
  signed 16-bit little-endian audio, an even number of bytes, at most 32,000 (one second); text
  `ping` is answered `pong`. Anything else closes the feed (1007 for bad audio, 1003 for other
  text). Audio counts as the seat's heartbeat. One feed per seat: a new one closes the old with
  4000; the feed closes with 4003 when the seat leaves or the call ends, and 4001 when the key is
  revoked. How audio is kept: [calls.md](calls.md#recordings-transcripts-and-recaps).
- **The record.** `transcript` is the call's current version, `[{person_id, name, text, at_ms}]`
  in time order across people; `at_ms` is epoch milliseconds at the start of the line's piece.
  `recordings` is `[{device_id, person_id, name, seconds}]`, one per device that sent audio. `summary` and `recap_at` are
  there once the recap ran. `seconds` is the length of that device's WAV. There is no `health`.
- **Retranscribe.** Room members on a device; only for a call that ended at least 3 s ago
  (409 `call_live`, 409 `too_soon`), with no transcript being written for it (409
  `transcribing`), 3 an hour per call and 10 per person (429 `too_many_retranscribes`), and 503 `not_configured`
  without speech-to-text. It answers as soon as the new version is started; read `/record` again
  for the result.

Frames:

| `type`            | Payload                                                   | To whom                                                                       |
| ----------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `call_state`      | `call`                                                    | the room's members and anyone seated, on every change to the roster or a flag |
| `call_ended`      | `call_id`, `ended_at`                                     | the same, when the last seat leaves                                           |
| `call_ring`       | `call`, `caller_name`, `conversation_title`, `expires_at` | each person being rung                                                        |
| `call_ring_ended` | `call_id`                                                 | that person's devices: answered, declined, run out or the caller left         |

The server bus also carries `call.ringing` and `call.ended` events for features such as push.

## Planning

Tasks, projects and their comments (`/v1/tasks`, `/v1/projects`, and the `tasks`
frame) are described in [planning.md](planning.md).

## Library and meetings

Files, documents and scheduled meetings (`/v1/library`, `/v1/files`, `/v1/documents`, `/v1/meetings`,
`/v1/meeting-series`, and the `meetings` of `/v1/calls`) are described in [library.md](library.md).

## Push

The app reports its push token with the two `apns-token` routes above. A host who sets the
`HQ_APNS_*` values gets message and read-sync pushes; see [push.md](push.md) for the host's
guide and `clients/apple/docs/push.md` for the payloads.

## Widgets

The Mac app's desktop widgets read one person's tasks with a **widget key** that works on
no other route. Three routes, all `Cache-Control: no-store`:

| Route                     | Sign-in                  | Answer                                                        |
| ------------------------- | ------------------------ | ------------------------------------------------------------- |
| `POST /v1/widgets/key`    | a device bearer          | `201 {"key"}`; a widget key gets `403 device_bearer_required` |
| `DELETE /v1/widgets/key`  | a device bearer or a key | `204`                                                         |
| `GET /v1/widgets/summary` | a device bearer or a key | `{version, generated_at, me, work}`                           |

A widget key is `hq_widget_<id>_<secret>`, kept as a hash, one live key per device; minting again
ends the earlier one, and it stops when the device is revoked or the person removed. `work`
holds the person's `in_progress`, `open`, `blocked` and `done_week` counts, the soonest
`next_due` task, and up to five `tasks` of each status (`id`, `number`, `ref`, `title`,
`status`, `project_name`, `comment_count`, `due_at`, `touched_at`). See [widgets.md](widgets.md).

## Agent sessions

Coding conversations synced from people's Macs (`/v1/agent-sessions`, and `open_transcripts` in `GET /v1/projects`) are
described in [sessions.md](sessions.md): the routes, who reads what, and how secrets are hidden. Every answer is `no-store`
and needs a device's bearer; a snapshot request is at most 1 MiB, envelope included (413 `payload_too_large`), and a person's stored text is held
to `HQ_TRANSCRIPT_QUOTA_MB` (413 `quota_exceeded`) and 5,000 sessions (413 `session_limit`); see [sessions.md](sessions.md).

## Configuration

| Variable                    | Default    | Meaning                                                                           |
| --------------------------- | ---------- | --------------------------------------------------------------------------------- |
| `HQ_MAX_UPLOAD_MB`          | 100        | largest attachment                                                                |
| `HQ_UPLOAD_QUOTA_MB`        | 2048       | most one person may upload in all                                                 |
| `HQ_TRANSCRIPT_QUOTA_MB`    | 512        | most one person's synced coding conversations may hold in all                     |
| `HQ_MAX_BODY_MB`            | upload + 1 | largest body the server accepts; only uploads get it (JSON is 1 MB, sign-in 4 KB) |
| `HQ_INVITE_TTL_DAYS`        | 7          | days after it was made that an invite key can sign a device in                    |
| `HQ_TRUST_PROXY`            | off        | `1` to count sign-in attempts by `X-Forwarded-For`                                |
| `HQ_APNS_KEY_FILE`          | unset      | Apple push key (.p8); push is off unless all four `HQ_APNS_*` are set             |
| `HQ_APNS_KEY_ID`            | unset      | that key's id                                                                     |
| `HQ_APNS_TEAM_ID`           | unset      | your Apple team id                                                                |
| `HQ_APNS_TOPIC`             | unset      | the app's bundle id                                                               |
| `HQ_PUSH_PREVIEW`           | `full`     | `hidden` sends the sender and "New message" only ([push.md](push.md))             |
| `HQ_CALLS_SFU_APP_ID`       | unset      | your Cloudflare Realtime SFU app; calls are off without it ([calls.md](calls.md)) |
| `HQ_CALLS_SFU_SECRET`       | unset      | its App Secret, or `HQ_CALLS_SFU_SECRET_FILE` for a file holding it               |
| `HQ_CALLS_SFU_URL`          | Cloudflare | the relay API's address                                                           |
| `HQ_CALLS_MAX_PARTICIPANTS` | 20         | devices in one call                                                               |

Uploads and pictures live in a `files` folder beside the database (`/data/files`
under Docker), so the volume you back up holds everything.
