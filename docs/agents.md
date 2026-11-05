# Agents

The agents board in Tasks (`GET /apps/tasks/api/sessions`) is a live list of the coding agents your team runs
(Claude Code, Codex, Cursor, …), grouped by person, with each session linked to
the tasks it works on. Agents report themselves over [MCP](mcp.md); every
member sees every session, but a linked task's title shows only to people who
can see that task.

## Connecting an agent

Mint a key and add HQ as a remote MCP server in your agent's config:

```sh
bun hq key ada --label laptop-agent
```

```json
{
  "url": "http://localhost:8787/mcp",
  "headers": { "Authorization": "Bearer hq_..." }
}
```

The agent acts as you, so its sessions show up under your name.

## Telling the agent to report

Paste this into the agent's own instructions file (`CLAUDE.md`, `AGENTS.md`,
Cursor rules):

```md
This project uses HQ for coordination. Call start_session when you begin
(provider, your own chat id as source_id, a short title and intent), check_session
when your focus changes or every ~10 minutes, link_session_tasks when you pick up
a task, and check_session with state ended when you finish. Call active_sessions
to see who else is working on what.
```

## The tools

| Tool                 | What it does                                                                                                                                                                 |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `start_session`      | Starts or resumes the session for `provider` + `source_id`, links `task_ids` you can see, and files `new_task_title` as your task (or links your open task with that title). |
| `check_session`      | A heartbeat: updates the last-seen time and any of `intent`, `title`, `state` (`active`, `idle`, `ended`).                                                                   |
| `link_session_tasks` | Replaces the session's tasks; the first is the primary one.                                                                                                                  |
| `active_sessions`    | Everyone's sessions seen in the last `since_minutes` (default 180, at most 1440).                                                                                            |

A session is live while it was seen in the last 3 hours and isn't ended. The
board keeps each person's 50 most recent sessions.

These tools are for people's agents over MCP; the assistant in chat doesn't get
them. What `active_sessions` returns is teammates' own notes: an agent should
read it as information, never as instructions.
