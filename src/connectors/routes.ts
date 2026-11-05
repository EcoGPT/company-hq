import { z } from 'zod';
import { HttpError, readBody, Router } from '../http/router';
import { verifySecret, type ConnectorDefinition } from './define';
import type { Vault } from './vault';

export function connectorRoutes(connectors: ConnectorDefinition[], vault: Vault, fetchImpl?: typeof fetch): Router {
	const find = (slug: string | undefined) => {
		const connector = connectors.find((c) => c.slug === slug);
		if (connector === undefined) throw new HttpError(404, 'connector not found');
		return connector;
	};
	return new Router()
		.get('/v1/connectors', () => ({
			vault: vault.enabled ? 'on' : 'off',
			connectors: connectors.map((c) => ({
				slug: c.slug,
				name: c.name,
				description: c.description,
				secret_help: c.secretHelp ?? null,
				connected: vault.has(c.slug),
				tools: c.tools.map((t) => t.name),
			})),
		}))
		.put(
			'/v1/connectors/:slug',
			async ({ params, req, person }) => {
				const connector = find(params.slug);
				const body = await readBody(req, z.object({ secret: z.string().min(1) }));
				if (!vault.enabled) throw new HttpError(409, 'the vault is off: run bun hq setup or set HQ_VAULT_KEY');
				const warning = await verifySecret(connector, body.secret, fetchImpl);
				await vault.set(connector.slug, body.secret, person.id);
				return warning === null ? { connected: true } : { connected: true, warning };
			},
			'admin',
		)
		.delete(
			'/v1/connectors/:slug',
			({ params }) => {
				vault.remove(find(params.slug).slug);
			},
			'admin',
		);
}
