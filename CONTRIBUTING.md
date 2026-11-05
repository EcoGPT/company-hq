# Contributing

```sh
bun install
bun run format  # Prettier
bun run ci      # format check, tsc and every test; must pass before a PR
```

## What fits here

HQ Community is a skeleton. Changes that make the platform easier to build on
are welcome: a sharper SDK, better scaffolding, a new provider adapter,
clearer docs, bug fixes. A new app belongs in the repo only if most teams would
turn it on. Otherwise, publish it as its own repo and open a PR that links it
from the README.

## Conventions

- **Small PRs.** One idea each, with tests. Reviewers should be able to read
  the whole diff.
- **Migrations are append-only.** Never edit a step that has shipped; add one.
- **No vendor names in core.** Model vendors live behind `Provider` and
  services behind connectors. `src/` shouldn't know which ones you use.
- **Tests sit next to the code they test** for apps (`apps/x/x.test.ts`) and
  in `test/` for core. Use `createHq()` for an in-memory HQ and
  `scripted([...])` instead of a real model. `bun run e2e` starts the real
  server process and drives the app protocol over HTTP and WebSocket
  (`e2e/protocol.e2e.ts`).
- **Few comments.** Prefer clear names. Comment only to explain _why_.
- **Tabs, single quotes, semicolons.** Prettier enforces them; run
  `bun run format` before you commit.

## Reporting a security issue

Please don't open a public issue. Use GitHub's private vulnerability reporting
(the repository's **Security** tab, then **Report a vulnerability**), with
steps to reproduce. [SECURITY.md](SECURITY.md) says what counts.
