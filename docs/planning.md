# Planning: tasks, projects and comments

The native app's Tasks and Projects screens (the board, a task's card, a project's page, comments and drag-to-reorder) talk
to the **tasks app** (`apps/tasks`). The same app still serves the assistant's task tools, the agent tools and the
`/apps/tasks/api/*` page routes; they read and write the same rows.

Everything below is under `/v1`, signed in as for the rest of the app protocol (see [protocol.md](protocol.md)). The routes
are `mount: 'v1'` routes of the tasks app, in `apps/tasks/planning.ts`.

## Who sees and does what

- **Tasks and projects are a team board.** Every member reads them, and any member may create and edit them.
- **A task filed in a room keeps that room's privacy.** It is listed only for people in the room and for its owner; to
  anyone else it does not exist (a 404 on every route, and out of every list, count and frame). The owner sees the task but
  not which room it came from (`origin_conversation_id` is null for them). An archived room has no members, so only the
  owner still sees its tasks. This is the rule the assistant's tools already used.
- **Deleting hides.** `DELETE /v1/tasks/:id` marks the row hidden. The row, its number and its comments stay, and the
  number is never given to another task. Only the task's owner, whoever filed it, or an admin may delete (what the app
  offers). There is no un-delete route; restoring is clearing `hidden_at` in the database. Projects are archived, never
  deleted (`PATCH` with `archived`).
- **Comments are plain text**: stored and sent as typed (trimmed), never interpreted by the server, 1 to 4,000
  characters, with the author's name and id. A thread holds at most 1,000.

## Routes

| Route                                   | What it does                                                                                                        |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `GET /v1/tasks`                         | `{tasks}`: the whole board for the caller, in board order                                                           |
| `POST /v1/tasks`                        | `{task}` (201). `title`, optional `body`, `owner_person_id`, `project_id`, `due_at`                                 |
| `PATCH /v1/tasks/:id`                   | `{task}`. Any of `title`, `body`, `status`, `owner_person_id`, `due_at`, `project_id`, `project_ids`                |
| `DELETE /v1/tasks/:id`                  | `{ok}`. Hides the task                                                                                              |
| `POST /v1/tasks/:id/order`              | `{tasks}`. `before_task_id` or `after_task_id`; the answer is the whole board in its new order                      |
| `GET`, `POST /v1/tasks/:id/comments`    | `{comments}` oldest first (the newest 500), `{comment}` (201) for `{body}`                                          |
| `GET /v1/projects`                      | `{projects, planning, project_task_links, open_transcripts}`                                                        |
| `POST /v1/projects`                     | `{project}` (201). `name`, optional `body`, `owner_person_id`, `planning_state`, `tags`                             |
| `PATCH /v1/projects/:id`                | `{project}`. `name`, `body`, `status`, `owner_person_id`, `planning_state`, `planning_category`, `tags`, `archived` |
| `GET`, `POST /v1/projects/:id/comments` | as for a task                                                                                                       |

`GET /v1/projects` also answers the questions the app asks before it writes: `planning` and `project_task_links` are true,
and `open_transcripts` is true because any member may open a synced coding session ([sessions.md](sessions.md)).

## Shapes

The JSON keys are the ones the app decodes (`TeamTask`, `Project` and `HQComment` in the app's `Wire.swift`), listed in
`test/fixtures/swift-wire.planning.json` and checked by tests.

- **Status** is `open`, `in_progress`, `blocked` or `done`. The `tasks` table still allows only `open` and `done` in its
  `status` column, which the assistant's tools and the page routes use, so in progress and blocked are stored in a
  separate `progress` column on an open task. To the assistant a blocked task is open. Moving a task to done clears
  `progress`, and sets `resolved_at` and who resolved it.
- **Number.** Every task has a `number`, one more than the highest ever given, shown in the app as `HQ-<number>`. Rows that
  existed before are numbered by when they were filed. Tasks the assistant or an agent files are numbered too.
- **Owner.** The app needs an owner on every task. A task nobody owns (the assistant often files these) is shown with
  whoever filed it as its owner; the stored row keeps no owner.
- **Dates.** `due_at` and the other times are ISO 8601 with milliseconds. A due date the page or the assistant set (a
  date at midnight UTC) is sent as that instant.
- **Projects.** `status` is `active` or `done`; a board with open tasks cannot be completed (409). `planning_state` is
  `Now`, `Next` or `Backlog`. `tags` is a list; the app files a project under a team by its tags. `open_tasks`,
  `total_tasks` and `last_task_resolved_at` count only the tasks the caller can see. A task can sit on several projects
  (`project_ids`); `project_id` is the first.
- **Order.** Tasks have a board order. A new task goes last. `POST /v1/tasks/:id/order` puts a task before or after
  another, between that task and its neighbour. The answer is the board the caller sees, in the new order.

## Limits

Sizes are twice what the app lets a person type, because the app counts characters and the server counts UTF-16 units.

| What                      | Limit                                                              |
| ------------------------- | ------------------------------------------------------------------ |
| Task title, body          | 400, 16,000 characters                                             |
| Project name, description | 120, 4,000 characters                                              |
| Comment                   | 4,000 characters; 1,000 per task or project                        |
| Tags                      | 20 per project, 80 characters each                                 |
| Projects on a task        | 20                                                                 |
| Projects on the server    | 500 not archived                                                   |
| Request body              | 256 KB (tasks and projects), 64 KB (comments), 4 KB (order)        |
| The board and its frame   | every open task (2,000 at most) and the 300 most recently finished |
| One board frame           | 8 MB; past that its tail is cut (the app drops messages over 16)   |

## Live updates

The app listens for one socket frame, `tasks`: `{ "type": "tasks", "tasks": [...] }`, the whole board. When it gets one it
replaces its tasks and reads the projects again, so a change to a task, a project or a comment sends it. Changes made by
the assistant, an agent or the page routes send it too. A coding session checking in changes no task and sends nothing.

It is sent through the `frame` bus event, to each person with the board they may read. People who can see the same set of
room-filed tasks share one frame; removed people get none. A burst of changes is sent as one frame (the first change starts
a 100 ms timer, and the board is read when it fires).

## Not supported

These have no meaning on a community server yet, so the server answers the empty value the app decodes, or leaves the field
out.

- **Repeating tasks.** `recurring_tasks` is not sent, so the app says the server needs an update before it saves a
  schedule. A `recurrence` other than `null` in a request is refused with 400. `recurrence` and `next_task_id` are never
  sent.
- **Objectives and system projects.** `kind` and `system_key` are not sent, so every project is ordinary work.
- **`planning_order` and a project's `due_at`.** Not sent: nothing in the app uses them.
- **Task links on the web.** The app copies a link of the form `<server>/HQ-<number>`. This server does not serve that
  address.
- **Agent sessions** (`/v1/agent-sessions`) are separate.

## Data

Migrations `tasks/003` to `tasks/006` add columns to `tasks` (number, position, progress, hidden_at, completed_by,
touched_at) and the tables `projects`, `task_projects` and `planning_comments`. Nothing is rebuilt or deleted: existing
rows keep their ids, status and owner, and get a number and a position.
