# Agent sessions

People run Claude Code and Codex on their Macs. A small helper app on each Mac copies those conversations to HQ, and
teammates see them on the app's Agents board and can open a transcript. This page is the server's side: the
`/v1/agent-sessions` routes, where the text is kept, who may read it, and how secrets are hidden. The code is
`apps/tasks/transcripts.ts` and `apps/tasks/redact.ts`.

Read [SECURITY.md](../SECURITY.md), "Agent sessions", before you turn this on for a team: **every member can read every
synced conversation, and so can whoever runs the server.**

## What is stored

For each conversation, the latest snapshot only: its title, the working folder and git branch, the text of the user and
assistant messages (not tool calls, reasoning, pictures or files), and the workspace-relative paths of the files it touched.
A new snapshot replaces the old one; its revision number and SHA-256 move on. There is no search over the text.

It is one row of `agent_sessions` (the table the MCP tools `start_session` and `check_session` write), found by the person,
the provider (`claude` or `codex`) and the conversation's id on their Mac. A session an agent reported over MCP and a
conversation the helper synced are the same row if they name the same conversation. The snapshot text is in
`agent_session_transcripts`, which only these routes read.

A sync never changes `state` or `last_seen_at`: those are the agent's own check-ins. An agent that reports in again with
`start_session` on a session its owner archived makes it live again (it is no longer archived); un-archiving one puts an
ended session back to idle. An archived session is hidden from `active_sessions` and `GET /apps/tasks/api/sessions` for
everyone but its owner. A row first made by a sync starts idle
and never checked in, and its activity time is its newest message, so importing old history does not put it on the board
as active. Nothing the conversation said reaches an MCP tool: `active_sessions`, `start_session` and the others answer
from the agent's own title and intent.

## Routes

All need a signed-in device's bearer. A script key (`bun hq key`) or an MCP key is refused with 403 `device_only`, so an
agent holding one cannot read other people's conversations. Every answer is `Cache-Control: no-store`.

The helper's routes work on the caller's own sessions. `:provider` is `claude` or `codex`; `:source` is 1 to 128 letters,
digits, `_` or `-` (anything else is 400 `invalid_identity`).

| Route                                                 | Answer                                                                                                                        |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `GET /v1/agent-sessions`                              | the caller's own, newest first: `{sessions, next_before}`. `before`, `task_id`, `include_archived=1`. 50 a page               |
| `GET /v1/agent-sessions/:provider/:source`            | `{session}`, or 404 `not_found`                                                                                               |
| `PUT /v1/agent-sessions/:provider/:source`            | store a snapshot: `{status, session, stored_verbatim, body_sha256}`                                                           |
| `PUT /v1/agent-sessions/:provider/:source/activity`   | `{status: "unchanged", session}`: a newer activity time and touched files for text the server already holds                   |
| `GET /v1/agent-sessions/:provider/:source/transcript` | the stored snapshot, with `X-HQ-Snapshot-Sha256` and `X-HQ-Revision`                                                          |
| `PUT /v1/agent-sessions/:provider/:source/archive`    | body `{archived}`; `{session}`. Archiving hides it from everyone else; nothing is deleted                                     |
| `GET /v1/agent-sessions/active`                       | the Agents board, any member: `{sessions, next_cursor}`. `cursor`, `limit` (1 to 50), `since_minutes` (1 to 1440, default 10) |
| `GET /v1/agent-sessions/by-id/:id`                    | `{thread, session}`, for any member; the app's `?open=1` is accepted and changes nothing                                      |
| `GET /v1/agent-sessions/by-id/:id/transcript`         | any member's, redacted unless it is the caller's own                                                                          |

Anything else under `/v1/agent-sessions` answers 404: this server keeps no tool-call history, takes no hook calls, has no
session messaging, sync-status or coverage pages, and links sessions to tasks only through the MCP tools
`start_session` and `link_session_tasks` (or a `task_ref` in a snapshot, below).

`GET /v1/agent-sessions?task_id=` lists only the **caller's own** sessions linked to that task, by design: it is the helper's
list. Everyone's sessions on a task are on the board (`/active`), whose rows carry their tasks.

### Storing a snapshot

`PUT` takes `{base_revision, activity_at?, files_touched?, snapshot}` and nothing else. `base_revision` is the revision the
helper last saw (0 for a conversation the server has not got). The snapshot is
`{projection: "conversation-text-v1", title, cwd, git_branch, task_ref, messages}`, with messages
`{id, role: "user" | "assistant", text, timestamp}`. `task_ref` is `HQ-<number>`, or null; a task it names that the caller can
see is linked to the session. A task they cannot see (hidden, or its room archived or left) or that does not exist is ignored:
the snapshot is still stored, so a conversation never stops syncing because its task went away. Unknown keys are refused.

- Same text as stored: `status: "unchanged"`, `body_sha256: null`; only the activity time and files are recorded.
- Otherwise `base_revision` must equal the stored revision, or the answer is 409 `revision_conflict`.
- `session.sha256` is the SHA-256 of the JSON array
  `[projection, title, cwd, git_branch, task_ref, [[id, role, text, timestamp], ...]]`, compact, UTF-8. The helper computes
  the same. `body_sha256` is the SHA-256 of the stored body.
- `activity_at` (milliseconds) is the later of the helper's value and the newest message time, never after now, and never
  moves back. A time more than a minute ahead is 400 `invalid_activity_time`.

### What the app reads

`thread` is a board row: `session_id`, `intent`, `state`, `last_seen_at`, `last_activity_at`, `title`, `owner_person_id`,
`owner_name`, `provider`, `git_branch`, the `tasks` (`{id, ref, title}`) and their `projects` (`{id, name}`). A task the
viewer cannot see (it was filed in a room they are not in) is left out entirely. `title` is the conversation's title, else
the agent's own.

`session` is `id`, `source_id`, `provider`, `title`, `git_branch`, `task_id`, `task_ids`, `revision`, `message_count`,
`created_at`, `updated_at`, `activity_at`, `archived_at` and `tool_history` (always false here). The owner also gets `cwd`,
`sha256`, `bytes`, `files_touched` and `repo`. See `test/fixtures/swift-wire.sessions.json`.

`GET /v1/projects` answers `open_transcripts: true`, which tells the app to ask for `?open=1`.

## Who reads what

- Any member may list the board and open any member's conversation, with one exception: an **archived** session is its
  owner's alone.
- The **owner** reads their own text exactly as stored, with its hash.
- **Everyone else** gets every title, branch, intent and message run through the secret-hiding list below, a null `sha256`
  (the hash covers the text before hiding, so it would let a reader check a guess at a hidden value), no `cwd` and no
  `files_touched`.
- Task titles on a session follow the viewer's view of the task, as everywhere in Tasks.
- No MCP tool and no assistant prompt returns any of it.

**A removed person** is frozen, as in chat: their keys stop and they can write nothing more, but their conversations stay
where they were and stay readable to the others, as their messages do. They leave the board when their last activity ages
out of its window. Nothing is deleted.

## Hiding secrets

`apps/tasks/redact.ts` replaces anything that looks like a credential with `[REDACTED]`: private key blocks, this server's
own keys (`hq_` and 40 or more characters), common vendor key prefixes, bearer tokens, JWTs, `password=` style pairs,
upper-case `*_KEY=` environment lines, passwords in URLs, credential headers and `curl -u`. It also drops the value under
a key named like a secret in any JSON it finds inside the text. The Mac helper hides the same patterns before it uploads.

This is **best effort**. No list of patterns catches every secret, and a secret in a form it does not know is stored and
shown. The person who runs the server reads what is stored, with the owner's own text exactly as the helper sent it.

## Limits

| What                            | Limit                                                                                      |
| ------------------------------- | ------------------------------------------------------------------------------------------ |
| a snapshot body                 | 1 MiB (1,048,576 bytes) for the whole request, envelope included (413 `payload_too_large`) |
| title, working folder, branch   | 200, 2048, 256 characters                                                                  |
| messages in a snapshot          | 10,000, each id unique and up to 256 characters, each text up to 500,000 characters        |
| files touched                   | 50 relative paths of up to 512 characters, never absolute or climbing out                  |
| the activity and archive bodies | 64 KB and 1 KB                                                                             |
| stored text per person          | `HQ_TRANSCRIPT_QUOTA_MB`, default 512, over all their sessions (413 `quota_exceeded`)      |
| sessions per person             | 5,000, MCP-reported ones included (413 `session_limit`)                                    |

A replacement that is smaller than the stored snapshot is always accepted, so lowering the quota never locks a person out.
The quota is read when a snapshot arrives, so changing it needs no restart.

### When a person is over a limit

Every stored conversation counts, archived ones included, and nothing here deletes one. A snapshot that cannot be taken
because of what a person already holds is a 413 with one of two codes, and they are recovered differently:

| Code             | Means                                                        | The way out                                                                                             |
| ---------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| `quota_exceeded` | adding this would take their stored text past the quota      | the person running the server raises `HQ_TRANSCRIPT_QUOTA_MB` (it applies at once), or removes sessions |
| `session_limit`  | they already hold 5,000 sessions and this would be a new one | removes sessions; no setting changes it, and raising the quota does not help                            |

Archiving frees nothing for either. A smaller replacement for a conversation they already have is always accepted, and so is
an update to one they already hold. The helper should show either as "your HQ is full for you", not retry it.

**Removing a session by hand** is a database edit by whoever runs the server. Foreign keys are on and nothing cascades, so
delete in this order, for each session id (`agent_sessions.id`): its text, then its task links, then the session.

```sql
DELETE FROM agent_session_transcripts WHERE session_id = '<id>';
DELETE FROM agent_session_tasks WHERE session_id = '<id>';
DELETE FROM agent_sessions WHERE id = '<id>';
```

Deleting the session first fails with a foreign key error. The helper will send the conversation again on its next pass
unless the person archived it on their Mac or stopped syncing.

The board shows each person's newest 50 sessions in the window, however many they have, so one member's thousands of
conversations cannot make every app page through hundreds of answers.

## Data

Migrations `tasks/010` and `tasks/011` add columns to `agent_sessions` (`cwd`, `synced_title`, `synced_branch`, `revision`, `sha256`,
`bytes`, `message_count`, `activity_at`, `archived_at`, `files_touched`) and the table `agent_session_transcripts`. The synced
title and branch are columns of their own, apart from the `title` and `branch` the MCP tools read and write. Nothing is
rebuilt: existing rows keep their ids and everything an agent reported.
