# Connectors

A connector gives the assistant tools for an outside service that needs a
secret. The secret is stored encrypted and handed to the tool at call time.
It never appears in a prompt, a tool result, or a log.

## Turning one on

```sh
bun hq connect github     # paste the token; it is read from stdin, not argv
```

or `PUT /v1/connectors/github { "secret": "..." }` as an admin. Until a
connector is connected, its tools are hidden from the assistant and from MCP.

The bundled GitHub connector checks the secret with
the service before storing it. A secret the service rejects is refused with a
400; if the service cannot be reached or does not answer within 10 seconds,
the secret is stored and a warning is returned
(`{ "connected": true, "warning": "..." }`) or printed by the CLI.

## The vault

Secrets are encrypted with AES-256-GCM using a key derived from
`HQ_VAULT_KEY`. Each secret gets a fresh IV, and the connector's slug is bound
in as associated data, so a row copied to another slug fails to decrypt.
`bun hq setup` generates the key into `vault.key` next to the database
(`data/vault.key` by default, readable only by you), where the server finds
it when `HQ_VAULT_KEY` is unset. An `HQ_VAULT_KEY` in the environment wins
over the file.

Without either the vault is off: every connector reads as not
connected, and storing a secret is refused. If you lose the key, you re-enter
every connector secret; there is no recovery.

## Any REST API in one call

```sh
bun hq new connector weather --base-url https://api.weather.example/v2
```

```ts
import { httpConnector } from '@hq/sdk';

export default httpConnector({
  slug: 'weather',
  name: 'Weather',
  description: 'Current conditions and forecasts by city.',
  baseUrl: 'https://api.weather.example/v2',
  auth: { header: 'x-api-key' }, // or 'bearer' (the default)
  secretHelp: 'Create a key at weather.example/account.',
  // allowWrites: true,               // GET only unless set
});
```

This gives the assistant one `weather_request` tool that takes a method, a
path under the base URL, and an optional JSON body. Paths that escape the base
URL are refused, and so are redirects that leave it.

## Hand-written connectors

For a better tool surface, write the tools yourself. Each tool receives
`secret` and `fetch` in its context:

```ts
import { connectorTool, defineConnector, readJson, z } from '@hq/sdk';

export default defineConnector({
  slug: 'github',
  name: 'GitHub',
  description: 'Read issues, pull requests and files.',
  secretHelp: 'A fine-grained token with read access.',
  tools: [
    connectorTool({
      name: 'github_list_issues',
      description: 'List issues or pull requests in a repository.',
      input: z.object({ repo: z.string(), state: z.enum(['open', 'closed', 'all']).default('open') }),
      async run({ repo, state }, { secret, fetch }) {
        const response = await fetch(`https://api.github.com/repos/${repo}/issues?state=${state}`, {
          headers: { authorization: `Bearer ${secret}` },
        });
        return readJson(response, 'GitHub');
      },
    }),
  ],
});
```

Return only what the model needs: trimmed fields beat raw API payloads, both
for cost and for answer quality. `readJson` turns non-2xx responses into a
`ToolError` that includes the status and the start of the body.

Add an optional `verify(secret, fetch)` to check a secret when it is saved.
Throw a `ToolError` when the service says the secret is invalid; any other
error (a network failure, a 5xx) only produces a warning.

Register the connector in `hq.config.ts` under `connectors: [...]`. Tests can
pass a fake `fetch` to `createHq` (see `test/connectors.test.ts`).
