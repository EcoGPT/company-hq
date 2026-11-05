# Getting started

From a fresh clone to a team using HQ. Each step takes a few minutes, and each
one works before you do the next.

## 0. What you need

- [Bun](https://bun.sh) 1.3 or newer (`curl -fsSL https://bun.sh/install | bash`)
- A model. Any of these works:
  - [Ollama](https://ollama.com) on your machine, with a model that does tool
    calls (`ollama pull qwen3:14b`)
  - An API key for OpenAI, Groq, Together, Mistral, DeepSeek or anything else
    that serves `/chat/completions`
  - An Anthropic API key
  - Nothing yet. HQ runs with an offline echo model until you pick one.

## 1. Run it

```sh
git clone https://github.com/EcoGPT/company-hq.git hq
cd hq
bun install
bun hq setup --name "Ada Lovelace" --handle ada
```

`setup` creates `.env`, writes a fresh vault key to `data/vault.key` if you
don't have one, asks which model to use (it finds local Ollama models on its
own), creates you as the first admin, and prints a server address and a sign-in key.
Start the server:

```sh
bun dev
```

Open the HQ app ([`clients/apple`](../clients/apple)), enter the address and the
key, and you land in #general, where the assistant has left a short welcome.

## 2. Talk to the assistant

Tag it in a room, or DM it. Things to try with the default apps:

| Say                                                                  | What happens                                   |
| -------------------------------------------------------------------- | ---------------------------------------------- |
| `@atlas file a task for me to write the launch post, due Friday`     | A task appears in **Tasks**, owned by you      |
| `@atlas remind me in 2 hours to check the deploy`                    | A DM from the assistant at that time           |
| `@atlas schedule a 30 minute design review with @bo tomorrow at 3pm` | A meeting, reminded in this room, on calendars |

`bun hq chat` opens the same conversation in your terminal.

## 3. Bring the team

```sh
bun hq invite bo --name "Bo Chen"
```

That prints the server address and Bo's sign-in key. Bo can add as many devices
with it as they like (a Mac and a phone, say), for 7 days after it was made
(`HQ_INVITE_TTL_DAYS`), used or not. Each device gets a bearer of its own, so one
lost phone can be revoked alone; the sign-in key itself is never a bearer. After
the 7 days Bo is told to ask an admin for a new one: run `bun hq invite bo`
again, which also cancels the old key. Admins can also add a new teammate from
the app's Settings; giving someone who is already in a new key is always `bun hq
invite`.
Before you send the address to anyone else, put HQ somewhere they can reach and
tell it its address:

```sh
# .env
HQ_PUBLIC_URL=https://hq.example.com
HQ_TIMEZONE=America/New_York
```

`HQ_PUBLIC_URL` is the address `bun hq invite` prints, and makes calendar feeds
absolute.
`HQ_TIMEZONE` is the zone the assistant uses when it tells people times.

To run it on a server, use Docker:

```sh
docker build -t hq .
docker run -d --name hq -p 8787:8787 -v hq-data:/data --env-file .env hq
docker exec -it hq bun bin/hq.ts setup --name "Ada Lovelace" --handle ada
docker restart hq
docker exec -it hq bun bin/hq.ts invite bo
```

The container keeps its own database in the `/data` volume, so run `setup`
there once to make yourself its admin, then restart the container so the
server picks up the vault key that `setup` wrote to `/data`. Don't set `HQ_DB` in the env file, or
the database ends up outside the volume.

Outside Docker, HQ only listens on `127.0.0.1`. Set `HQ_HOST=0.0.0.0` to
reach it from other machines; the image already does.

Put it behind any HTTPS proxy (Caddy, nginx, a Cloudflare tunnel). Back up
the whole `/data` volume: SQLite runs in WAL mode, so recent writes can sit
in `hq.sqlite-wal` next to the database, and the vault key is `vault.key`
beside it. Keep a copy of that key somewhere safe; without it, every
connector secret has to be entered again.

## 4. Connect your tools

```sh
bun hq connect            # what's available and what's connected
bun hq connect github     # paste a token; it stays hidden
```

Each connector's tools appear for the assistant once its secret is set.

## 5. Make it yours

- **The assistant:** edit `assistant/persona.md`, then `bun hq chat` to try it.
  [docs/assistant.md](assistant.md) covers names, surfaces and limits.
- **An app:** `bun hq new app standup --description "Daily notes"` writes a
  working app with a test, and the dev server picks it up right away.
  [docs/apps.md](apps.md) is the full reference.
- **An automation:** `bun hq new automation nudge --app standup`.
  [docs/automations.md](automations.md) covers schedules.
- **Other AI:** embeddings and speech-to-text are off until you set a model
  for them. See [docs/ai.md](ai.md).

## 6. Keep it healthy

- `bun hq doctor` shows the model, which AI capabilities are on, every app,
  automation and connector, and the last week of model usage.
- HQ upgrades its database on boot. Back up `/data` before pulling a new
  version.
- `bun hq invite <handle>` makes a new sign-in key for anyone who lost theirs;
  they enter it in the app. `POST /v1/devices/:id/revoke` signs one device out,
  and `DELETE /v1/mcp-keys/:id` revokes one of your own MCP keys.
- `bun hq revoke <handle>` offboards someone: every key they hold stops
  working, open sessions close within a minute, and their calendar link goes
  dead.

## Upgrading from the browser client

This version speaks the HQ app's protocol and no longer serves a browser client.
In the browser version the key in a sign-in link became a login once it was used.
Now a key from `bun hq setup` or `bun hq invite` only signs a device into the
app, and is refused everywhere else. So:

- **Existing members must be re-invited.** Run `bun hq invite <handle>` for each
  person and send them the address and key it prints; they enter both in the HQ
  app. Their messages, rooms and history are untouched.
- **MCP clients need a key from `bun hq key <handle>`** (or the app's MCP keys
  card) if they were using a sign-in link's key. Keys that `bun hq key` made
  before keep working.
- Admins add new people from the app's Settings, or with `bun hq invite`.
