# Desktop widgets

The Mac app can put two widgets on the desktop: **My Tasks** (a ring of the tasks
assigned to you and the ones you are working on) and **Board** (your tasks as the
board draws them: To do, In progress, Blocked). They are read-only. Tapping a task
opens its card in HQ.

The server's part is small: a **widget key** that can read one person's summary and
nothing else, and the summary. Nothing is configured on the server; widgets are on
whenever the Tasks app is. With no Tasks app the summary is empty.

The app's part needs your own Apple team, because the app and the widget share a
folder only a team-signed pair can open. A build without a team has no widgets and
is otherwise unchanged. The steps are in
[`clients/apple/README.md`](../clients/apple/README.md), "Desktop widgets".

## How it works

1. The signed-in app asks for a widget key with its device bearer
   (`POST /v1/widgets/key`) and writes it, with the server's address, into the shared
   folder (the App Group). The device bearer never leaves the app.
2. The widget extension reads the key from there and fetches
   `GET /v1/widgets/summary` itself, every 15 minutes. While HQ runs, the app also
   fetches after the board changes and tells the widgets to redraw.
3. Signing out empties the shared folder and asks the server to revoke the key. The request is best
   effort: if the Mac is offline it is not retried, and the key lives until its device is revoked.

## The widget key

- Format `hq_widget_<id>_<secret>`: a 12-character id and a 43-character secret (both
  base64url). It is shown once, when it is made.
- Kept apart from API keys, in its own table (`widget_keys`). Only the SHA-256 of the
  secret is stored, and it is compared in constant time. It is not an API key: it signs
  in to no other route, to the socket or to `/mcp`.
- One live key per device. Asking again ends the earlier key of that device, and
  `DELETE /v1/widgets/key` ends it (with the device bearer or with the key itself).
- It stops working when its device is revoked or its person is removed.
- It has no expiry. It lives until one of the above.

## Routes

All three answer `Cache-Control: no-store`, errors included.

| Route                     | Who                      | Answer                                                        |
| ------------------------- | ------------------------ | ------------------------------------------------------------- |
| `POST /v1/widgets/key`    | a device bearer          | `201 {"key"}`. A widget key gets `403 device_bearer_required` |
| `DELETE /v1/widgets/key`  | a device bearer or a key | `204`                                                         |
| `GET /v1/widgets/summary` | a device bearer or a key | the summary below                                             |

A script's or an MCP key is a bearer but not a device: it gets `403
device_bearer_required` here. No sign-in, or a key that is wrong, revoked or malformed,
gets `401 unauthorized`.

## The summary

```json
{
  "version": 1,
  "generated_at": "2026-09-28T15:00:00.000Z",
  "me": { "id": "…", "name": "Ada", "avatar_id": null },
  "work": {
    "in_progress": 3,
    "open": 6,
    "blocked": 1,
    "done_week": 4,
    "next_due": { "…": "a task, as below" },
    "tasks": [
      {
        "id": "…",
        "number": 41,
        "ref": "HQ-<number>",
        "title": "Draft the onboarding guide",
        "status": "in_progress",
        "project_name": "Docs site",
        "comment_count": 2,
        "due_at": null,
        "touched_at": "2026-09-28T14:10:00.000Z"
      }
    ]
  }
}
```

- The person's own tasks, only ones they can see. A task nobody took counts as its
  filer's, as the board does. Hidden tasks are left out.
- `in_progress`, `open` and `blocked` count every task owed. `done_week` counts the ones
  finished in the last seven days. `tasks` lists at most five of each status, in_progress
  first, then blocked, then open (to-do sorted by due date, undated last; the others by
  last change). `next_due` is the soonest due date among everything owed, even past the
  five listed.
- `ref` is `HQ-<number>`, `null` for a task with no number. `project_name` is the first
  board the task is on.
- Dates are ISO 8601 with milliseconds.

## For app authors

`src/widgets` is core and imports no app. An app adds its work with the `widgetWork` hook
in its definition (`src/apps/define.ts`): `widgetWork(app, person)` returns a `WidgetWork`
for that person and must return only what they may see. The first app that has the hook
supplies the work; a hook that throws leaves it empty. The Tasks app (`apps/tasks/app.ts`)
is the one that has it.

## Not here

- Completing a task, or taking an alert, from a widget. The widgets only read.
- Widget pushes. The widget refreshes from the app and on its 15-minute timeline.
- Statistics and alerts widgets: they depend on a company's own analytics and paging.
- An iPhone widget.
