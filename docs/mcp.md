# MCP

HQ serves the Model Context Protocol at `POST /mcp` (streamable HTTP, JSON
responses). Any MCP client (a coding agent, an IDE, a desktop chat app) can
read and act in HQ as the person who owns the key.

## Connecting

Mint a key for yourself, or for a service seat you add for a bot:

```sh
bun hq key ada --label laptop-agent
bun hq invite ci-bot --service
bun hq key ci-bot --label ci
```

Use the key from `bun hq key` (or one made on the app's MCP keys card). Whatever
label a key is given, it is a plain key: it acts as its person, in the rooms they
are in, and nothing more. It cannot do an admin's work on who may sign in (adding
people, promoting, removing); that takes the admin's own signed-in device. `bun hq
key` refuses someone an admin removed.

A key from `bun hq invite` (or `bun hq setup`) is a sign-in key only: it adds
devices in the app and is refused as a bearer. An invite stops adding them
`HQ_INVITE_TTL_DAYS` (7) days after it was made; a key from `bun hq key` has no
such limit.

Then add a remote HTTP server to your client. The exact config file differs by
client, but the fields are the same:

```json
{
  "url": "http://localhost:8787/mcp",
  "headers": { "Authorization": "Bearer hq_..." }
}
```

## What the client gets

- Every tool in the registry: the core chat tools, every app's tools, and
  connected connectors. A new app's tools appear without any extra work.
- Tools run as the key's owner. Room membership applies, so the client can't
  read or post in rooms that person isn't in.
- Assistant-only tools (`remember`, `forget`) are hidden.
- Tool results come back as text (strings as they are, anything else as
  JSON), with `isError: true` when a call failed validation or the tool
  refused.

Supported methods are `initialize`, `ping`, `tools/list` and `tools/call`.
Protocol versions 2025-06-18, 2025-03-26 and 2024-11-05 are accepted.
Notifications get a 202. `GET /mcp` (server-initiated streams) is not
supported.

A common use: let a coding agent check the team's task list and post a summary
to a room when it finishes a job. Coding agents can also report what they are
working on to the Agents board; see [Agents](agents.md).
