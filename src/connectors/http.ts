import { z } from 'zod';
import { ToolError } from '../tools/define';
import { connectorTool, defineConnector, readJson, type ConnectorDefinition } from './define';

export type HttpConnectorOptions = {
	slug: string;
	name: string;
	description: string;
	baseUrl: string;
	auth?: 'bearer' | { header: string };
	allowWrites?: boolean;
	secretHelp?: string;
};

const MAX_REDIRECTS = 4;

export function httpConnector(options: HttpConnectorOptions): ConnectorDefinition {
	const base = options.baseUrl.replace(/\/+$/, '');
	const methods = options.allowWrites === true ? (['GET', 'POST', 'PUT', 'PATCH', 'DELETE'] as const) : (['GET'] as const);
	return defineConnector({
		slug: options.slug,
		name: options.name,
		description: options.description,
		secretHelp: options.secretHelp,
		tools: [
			connectorTool({
				name: `${options.slug.replace(/-/g, '_')}_request`,
				description: `Call the ${options.name} API at ${base}. ${options.description}`,
				input: z.object({
					method: z.enum(methods).default('GET'),
					path: z.string().startsWith('/').describe(`Path under ${base}, with any query string`),
					body: z.record(z.string(), z.unknown()).optional(),
				}),
				activity: `Calling ${options.name}`,
				async run(input, { secret, fetch }) {
					if (/%2f|%5c/i.test(input.path)) throw new ToolError('encoded slashes are not allowed in the path');
					const auth = options.auth ?? 'bearer';
					const credentials: Record<string, string> =
						auth === 'bearer' ? { authorization: `Bearer ${secret}` } : { [auth.header]: secret };
					let { method, body } = input;
					let url = new URL(base + input.path);
					// Redirects are followed by hand: fetch keeps custom auth headers across origins.
					for (let hop = 0; ; hop++) {
						const target = `${url.origin}${url.pathname}`;
						if (target !== base && !target.startsWith(`${base}/`)) {
							throw new ToolError(hop === 0 ? 'path escapes the base URL' : 'redirected outside the base URL');
						}
						const response = await fetch(url, {
							method,
							redirect: 'manual',
							headers: {
								accept: 'application/json',
								...(body === undefined ? {} : { 'content-type': 'application/json' }),
								...credentials,
							},
							body: body === undefined ? undefined : JSON.stringify(body),
						});
						const location = response.headers.get('location');
						if (response.status < 300 || response.status > 399 || location === null) return readJson(response, options.name);
						if (hop === MAX_REDIRECTS) throw new ToolError(`${options.name} redirected too many times`);
						if (response.status === 303 || (method === 'POST' && response.status !== 307 && response.status !== 308)) {
							method = 'GET';
							body = undefined;
						}
						url = new URL(location, url);
					}
				},
			}),
		],
	});
}
