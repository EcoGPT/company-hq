# HQ Community

**Team chat with an AI teammate in every room, and apps you write in one file.**

HQ is a small, self-hosted hub for a team: rooms and DMs, an assistant that
reads the thread and gets work done with real tools, and apps for tasks, docs,
meetings and reminders that it can use. It runs as one Bun process with one
SQLite file and no build step. People use it from the native HQ app for iPhone
and Mac, which lives in [`clients/apple`](clients/apple) and talks to the
server over the [app protocol](docs/protocol.md); coding agents use it over
MCP.

## Why HQ

- **The assistant works where the team talks.** Tag `@atlas` in any room and it
  reads the thread, calls tools, and answers there. A request like "file a task
  for Bo, due Friday" becomes a task in Tasks.
- **Every feature is an app you can read.** An app is one `defineApp` call:
  tables, assistant tools, an HTTP API, and scheduled automations. `bun hq new app` writes a working one with a test.
- **Bring any model.** Ollama or any other `/chat/completions` endpoint
  (OpenAI, Groq, Together, Mistral, DeepSeek, vLLM), or Anthropic's Messages
  API. Other vendors take one adapter function.
- **Keys stay out of the model.** Connector secrets are encrypted in a vault
  and handed to tools at call time. The model never sees them.
- **Use it from your editor.** Every tool is also served over MCP at `/mcp`,
  so coding agents act in HQ as the person who owns the key.

## Quickstart

You need [Bun](https://bun.sh) 1.3 or newer.

```sh
git clone https://github.com/EcoGPT/company-hq.git hq && cd hq
bun install
bun hq setup --name "Ada Lovelace" --handle ada
bun dev
```

`setup` writes `.env`, asks which model to use (it finds local Ollama models
on its own), makes you the first admin, and prints a server address and your
sign-in key. With `bun dev` running, open the HQ app ([`clients/apple`](clients/apple)),
enter the address and the key, and you are in. Without a model, the assistant
echoes what you say until you pick one.

```sh
bun hq chat          # talk to the assistant in your terminal
bun hq invite bo     # add a teammate and print the address and key they sign in with
bun hq connect       # list connectors; `bun hq connect github` adds a token
bun hq doctor        # the model, apps, tools, automations and recent usage
```

[Getting started](docs/getting-started.md) takes it from here to a team using
it: what to ask the assistant, inviting people, deploying, and connecting
your tools.

## What's in the box

| App or connector    | What it does                                                                                                                |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `apps/tasks`        | A shared to-do list the assistant files into from chat, and a live board of coding agents ([guide](docs/agents.md)).        |
| `apps/docs`         | The team's shelf of Markdown docs, with every earlier version kept and optional semantic search.                            |
| `apps/meetings`     | Schedules calls, reminds the room, turns recordings or notes into recaps with tasks, and gives each person a calendar feed. |
| `apps/reminders`    | "Remind me in 2 hours…" or "remind @bo tomorrow at 9…", delivered as a DM or in the room.                                   |
| `connectors/github` | Reads issues, pull requests and files.                                                                                      |

Turn any of them off by removing it from `hq.config.ts`.

Built in and off until you set it up: calls in the Mac and iPhone apps (ringing, meetings, screen sharing) through your own Cloudflare Realtime app ([guide](docs/calls.md)).

## Build an app

```sh
bun hq new app standup
bun test apps/standup
```

That writes `apps/standup/` (a table, two assistant tools, an API and a passing
test) and registers it in `hq.config.ts`. The dev server picks it up.
At its core, an app is one object:

```ts
import { defineApp, defineTool, z } from '@hq/sdk';

export default defineApp({
  slug: 'standup',
  name: 'Standup',
  description: 'Daily check-ins.',
  briefing: 'When someone posts their standup, save it with add_standup.',
  migrations: [{ id: '001_entries', up: 'CREATE TABLE standup_entries (...)' }],
  tools: [
    defineTool({
      name: 'add_standup',
      description: 'Save a standup entry.',
      input: z.object({ yesterday: z.string(), today: z.string() }),
      run: (input, { hub, caller }) => {
        /* write a row */
      },
    }),
  ],
  routes: [{ method: 'GET', path: 'entries', handler: ({ hub }) => [] }],
});
```

The zod schema is the tool's contract. HQ turns it into the JSON Schema the
model sees, validates every call against it, and hands validation errors back
to the model so it can retry. The same tool is available to the assistant and
over MCP.

To change how the assistant talks, edit `assistant/persona.md` and try it with
`bun hq chat`.

## Docs

- [Getting started](docs/getting-started.md): from clone to a team using it
- [Apps](docs/apps.md): tables, tools, routes and tests
- [The app protocol](docs/protocol.md): what the native app speaks: sign-in, people, chat, the live socket
- [The assistant](docs/assistant.md): persona, when it replies, memory
- [Models](docs/providers.md) and [other AI services](docs/ai.md): providers, retries, embeddings, speech
- [Automations](docs/automations.md): scheduled jobs and their run history
- [Connectors](docs/connectors.md): the vault and tools for outside APIs
- [MCP](docs/mcp.md): HQ's tools from coding agents and desktop clients
- [Agents](docs/agents.md): a live board of what each coding agent is working on
- [Meetings](docs/meetings.md): the biggest bundled app
- [Architecture](docs/architecture.md): how the pieces fit

## Deploy

```sh
docker build -t hq .
docker run -d -p 8787:8787 -v hq-data:/data --env-file .env hq
```

Put it behind HTTPS, set `HQ_PUBLIC_URL`, and back up the `/data` volume.
[Getting started](docs/getting-started.md#3-bring-the-team) covers the
details.

## Status

HQ Community is built by EcoGPT. It's small enough to read and meant to be
forked. Issues and pull requests are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately, as
[SECURITY.md](SECURITY.md) describes.

[MIT](LICENSE) licensed.
