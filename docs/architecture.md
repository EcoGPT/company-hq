# Architecture

```
            HQ app (clients/apple)   MCP clients        bun hq (CLI)
                  │                       │                   │
          HTTP + /v1/ws (ws)           POST /mcp         direct (no server)
                  │                       │                   │
┌─────────────────▼───────────────────────▼───────────────────▼──────────┐
│ createHq()  src/hq.ts                                                  │
│                                                                        │
│  Router (core, wire, apps, automations, connectors)   MCP   Socket     │
│                                                                        │
│  ToolRegistry ◄── core tools · memory tools · app tools · connectors   │
│        ▲                                                               │
│  AssistantRunner ── runTurn ──► Provider (openai-compatible │ anthropic │ yours)
│        ▲                                                               │
│  Bus ◄─┴── Hub: people · keys · conversations · messages               │
│                                                                        │
│  Scheduler ── automations          Vault ── connector secrets          │
└─────────────────────────────────┬──────────────────────────────────────┘
                                  │
                         SQLite (one file, WAL)
```

## Pieces

- **Hub** (`src/core/`): people, API keys, devices, conversations, messages,
  tapbacks, read marks and attachments, all in one SQLite file (uploaded bytes
  sit in a `files` folder beside it). Changes emit a typed event on the **bus**.
- **Migrations** (`src/db/database.ts`): an append-only ladder. Each step's id
  starts with its owner: `core/`, `ai/` for usage tracking, or the app's slug.
- **Router** (`src/http/router.ts`): a small router with bearer auth and three
  access levels. Handlers return values, and the router turns them into
  responses.
- **App protocol** (`src/wire/`): the routes and JSON shapes the native app
  speaks: enroll, people, chat, attachments, pictures. See
  [protocol.md](protocol.md).
- **Socket** (`src/realtime/socket.ts`): a websocket per device that turns bus
  events into frames and sends each only to the people who can see that
  conversation.
- **Tools** (`src/tools/`): zod-typed functions. The registry is shared by the
  assistant and MCP, so a capability is written once.
- **Assistant** (`src/assistant/`): a runner that listens on the bus and runs
  one turn at a time per conversation through a `Provider`.
- **Apps** (`src/apps/`): `defineApp` bundles migrations, tools, routes,
  automations and a setup hook. `mount.ts` wires them in.
- **Scheduler** (`src/automations/`): cron and interval jobs with persisted
  run history.
- **Vault** (`src/connectors/`): AES-GCM secrets, and the wrapper that hands
  them to connector tools.
- **Boot** (`src/boot.ts`): turns `hq.config.ts` and env vars into a running
  HQ, shared by the server and the CLI.

## Migration ids set aside

Features built side by side each take their own ids, so none of them edits
another's list. `src/hq.ts` spreads every module's migrations once, where it
opens the database.

| Ids               | For                                                 |
| ----------------- | --------------------------------------------------- |
| `push/001`+       | push notifications (`src/push`)                     |
| `widgets/001`+    | home-screen widgets (`src/widgets`)                 |
| `tasks/003`–`009` | planning (after `tasks/001` and `002`, which exist) |
| `tasks/010`–`019` | agent sessions                                      |
| `docs/004`+       | docs (after `docs/001`–`003`)                       |
| `meetings/003`+   | meetings (after `meetings/001` and `002`)           |
| `library/001`+    | the library app (`apps/library`)                    |
| `calls/001`+      | live calls (`src/calls`)                            |

## Rules worth keeping

- **SQLite is the truth.** No cache sits in front of it, and nothing important
  lives only in memory. Back up the file.
- **Migrations only move forward.** Adding tables and columns is free.
  Renaming or dropping runs on live data the moment it deploys, so prefer a new
  column.
- **Connector secrets stay out of prompts.** They reach tools through their
  context, and tool results and model messages never contain them.
- **The assistant has a teammate's reach, not more.** Its tools run as its
  person row, under the same membership checks as everyone else. In a turn,
  they also only reach conversations that every other member of the current
  one is in, so it can't repeat a private room into a wider one.
- **Prefer keeping to deleting.** Doc edits keep earlier versions.
