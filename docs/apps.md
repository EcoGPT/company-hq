# Building apps

Everything in HQ besides chat is an app: a folder under `apps/` that exports one
`defineApp` call and is listed in `hq.config.ts`. App code imports from
`@hq/sdk` only; tests also import helpers from `src/`.

```sh
bun hq new app standup
bun test apps/standup
```

## The shape

```ts
defineApp({
	slug: 'standup',          // kebab-case; namespaces migrations and URLs
	name: 'Standup',
	description: 'Daily check-ins.',
	icon: '☀',
	briefing: '...',          // appended to the assistant's system prompt
	migrations: [...],        // your tables
	tools: [...],             // for the assistant and MCP
	routes: [...],            // your HTTP API
	automations: [...],       // scheduled jobs (see automations.md)
	setup(app) { ... },       // runs once at boot; may return a teardown
});
```

Every field except `slug`, `name` and `description` is optional. An app can be
only tools, or only an automation.

## Tables

Migrations are an append-only ladder. HQ prefixes each id with the app slug
(`001_items` becomes `standup/001_items`), runs it once inside a transaction,
and records it in `_migrations`.

```ts
migrations: [
	{ id: '001_entries', up: 'CREATE TABLE standup_entries (id TEXT PRIMARY KEY, ...)' },
	{ id: '002_mood', up: 'ALTER TABLE standup_entries ADD COLUMN mood TEXT' },
],
```

Never edit an applied step. Add a new one. Prefix table names with the app
slug so two apps can't collide. Reference `people(id)` and
`conversations(id)` freely.

Query with `hub.db`, which is a `bun:sqlite` database in strict mode, so named
parameters drop the `$` in the bindings object:

```ts
hub.db.query('SELECT * FROM standup_entries WHERE created_by = $who').all({ who: caller.id });
```

For anything bigger than a couple of queries, put the migrations and a small
store class in `store.ts` next to `app.ts` (see `apps/tasks/store.ts`). The
scaffolder starts you that way.

## Tools

```ts
defineTool({
	name: 'add_standup',                 // snake_case, unique across HQ
	description: 'Save a standup entry.',  // the model reads this; be specific
	input: z.object({ today: z.string().min(1), blockers: z.string().optional() }),
	activity: 'Saving a standup',        // shown in the room while it runs
	run: (input, { hub, caller, conversationId }) => { ... },
});
```

- `input` is the whole contract. The model sees the JSON Schema generated from
  it, and every call is validated against it before `run`.
- `caller` is whoever is calling: the assistant in chat, or the key owner over
  MCP. Check permissions against it.
- `viewers` lists the other people who will see the result (everyone in the
  thread, when the assistant calls). A tool that reads conversations should
  check `canSee(ctx, conversationId)` from `@hq/sdk`, which requires both the
  caller and every viewer to be members.
- `conversationId` is set when the assistant calls from a thread. Store it to
  link a record to where it came from.
- `timezone` is the assistant's IANA zone. Resolve words like "tomorrow" in it
  (`resolveDay(text, ctx.timezone ?? defaultTimezone())`) so they match the
  dates in the assistant's prompt.
- Return anything JSON-serializable. Results over 12k characters are truncated
  for the model.
- Throw `ToolError('message')` to refuse cleanly. The message goes back to the
  model, which can correct itself or explain the refusal. Thrown from a route,
  it becomes a 400.
- `personByHandle(hub, '@bo')` and `roomFor(ctx, conversationId)` resolve
  people and rooms with HQ's standard errors; `roomFor` applies `canSee`.
  `asToolError(() => call())` turns an outside service's failure into a
  `ToolError`.
- `audience: 'assistant'` hides a tool from MCP. `available(ctx)` hides it
  until something is configured.

Good tool descriptions do more for the assistant than prompt tweaks. Say when
to use the tool, not only what it does.

## Routes

```ts
routes: [
	{ method: 'GET', path: 'entries', handler: ({ hub, url }) => [...] },
	{ method: 'POST', path: 'entries', handler: async ({ req, person, app }) => {
		const body = await readBody(req, z.object({ today: z.string() }));
		app.emit('changed');
		return { ok: true };
	} },
	{ method: 'DELETE', path: 'entries/:id', access: 'admin', handler: ({ params }) => {} },
],
```

Routes are served at `/apps/<slug>/api/<path>` and need a signed-in person
(`access: 'admin'` to restrict further). Return a value to send JSON, a
`Response` for anything else, or nothing for a 204. Throw `HttpError(404, '...')`
for errors.

`access: 'public'` serves a route without sign-in, for callers that can't hold
an HQ key, like signed callbacks from another service. `person` is then `null` unless a
key was sent. A public route must authenticate the request itself, usually by
checking a signature over the raw body (`await req.text()`):

```ts
{ method: 'POST', path: 'events', access: 'public', handler: async ({ req }) => {
	const raw = await req.text();
	if (!(await verify(req.headers, raw))) throw new HttpError(401, 'bad signature');
	return { ok: true };
} },
```

Request bodies, public or not, are capped at 1 MB, and anything larger gets a
413 `payload_too_large` before your handler sees it. Set `maxBodyBytes` on the
route if it needs more.

## Talking to the team

`setup(app)` and automations get an `AppContext`:

- `app.assistant.post(conversationId, text)` posts as the assistant.
- `app.assistant.ask(prompt)` makes a single model call with the assistant's
  persona and no tools, which suits summaries and drafts.
- `app.emit(name, data)` puts an `app.event` on the bus. App events stay
  inside the server; an app that needs a socket frame sends one through the
  `frame` bus event (see [protocol.md](protocol.md#frames-from-features)).
- `app.tools.has(name)` and `app.tools.call(name, input, { conversationId })`
  use another app's tools, as the assistant unless you pass a `caller`.
  Meetings files recap action items through Tasks this way.
- `app.secrets.get(slug)` reads a connector's secret from the vault, and
  `app.secrets.has(slug)` says whether one is set. Register a connector for
  each secret the app needs, so admins can set it with `bun hq connect`.
  Apps are trusted code: any app can read any secret and the whole database.
  Review a third-party app the way you'd review a dependency before adding it
  to `hq.config.ts`.
- `app.fetch` is the `fetch` HQ was given. Use it for outbound calls so tests
  can swap in a fake.
- `app.hub` gives you people, conversations, messages, the bus and the db.
  `hub.general()` is the #general room. `hub.conversations.ensureRoom(key,
title)` gives an app its own stable room.

React to chat with the bus:

```ts
setup(app) {
	return app.hub.bus.on((event) => {
		if (event.type === 'message.created' && event.message.body.includes('#standup')) { ... }
	});
},
```

## Testing

Tests live next to the app. `createHq({ apps: [app] })` boots an in-memory HQ
in a few milliseconds:

```ts
import { createHq } from '@hq/sdk/testing';

const hq = createHq({ apps: [standup] });
const ctx = { hub: hq.hub, caller: hq.assistant.self };
expect((await hq.registry.call('add_standup', { today: 'docs' }, ctx)).ok).toBe(true);
```

Without an assistant config, the in-memory HQ's assistant is `@assistant`.
To test it with your tools, pass `provider: scripted([...])` and script the
tool calls the model would make (see `test/assistant-turn.test.ts`).
`@hq/sdk/testing` also has `client(hq, key)` for calling routes, `admin(hq)`
for a signed-in admin, and mock embedders and transcribers.
