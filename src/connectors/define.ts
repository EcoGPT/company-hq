import type { z } from 'zod';
import { defineTool, ToolError, type Tool, type ToolContext } from '../tools/define';
import type { Vault } from './vault';

export type ConnectorToolContext = ToolContext & { secret: string; fetch: typeof fetch };

export type ConnectorTool<S extends z.ZodType = z.ZodType> = Omit<Tool<S>, 'run' | 'available'> & {
	run(input: z.infer<S>, ctx: ConnectorToolContext): unknown;
};

export type ConnectorDefinition = {
	slug: string;
	name: string;
	description: string;
	secretHelp?: string;
	tools: ConnectorTool[];
	// Throw a ToolError when the service rejects the secret; any other error only warns.
	verify?(secret: string, fetch: typeof globalThis.fetch): Promise<void>;
};

export function defineConnector(connector: ConnectorDefinition): ConnectorDefinition {
	if (!/^[a-z][a-z0-9-]{0,31}$/.test(connector.slug)) throw new Error(`connector slugs are kebab-case: ${connector.slug}`);
	return connector;
}

export async function verifySecret(
	connector: ConnectorDefinition,
	secret: string,
	fetchImpl: typeof fetch = fetch,
	timeoutMs = 10_000,
): Promise<string | null> {
	if (connector.verify === undefined) return null;
	const signal = AbortSignal.timeout(timeoutMs);
	const timedFetch = ((input: Parameters<typeof fetch>[0], init?: RequestInit) =>
		fetchImpl(input, { ...init, signal: init?.signal ? AbortSignal.any([init.signal, signal]) : signal })) as typeof fetch;
	let timer: ReturnType<typeof setTimeout> | undefined;
	const timeout = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error(`no answer after ${timeoutMs / 1000}s`)), timeoutMs);
	});
	try {
		await Promise.race([connector.verify(secret, timedFetch), timeout]);
		return null;
	} catch (error) {
		if (error instanceof ToolError) throw error;
		return `Could not check the ${connector.name} secret: ${error instanceof Error ? error.message : String(error)}`;
	} finally {
		clearTimeout(timer);
	}
}

export function connectorTool<S extends z.ZodType>(tool: ConnectorTool<S>): ConnectorTool {
	return tool;
}

export function connectorTools(connector: ConnectorDefinition, vault: Vault, fetchImpl: typeof fetch = fetch): Tool[] {
	return connector.tools.map((tool) =>
		defineTool({
			...tool,
			description: `${tool.description} (${connector.name})`,
			available: () => vault.has(connector.slug),
			async run(input, ctx) {
				const secret = await vault.get(connector.slug);
				if (secret === null) throw new ToolError(`${connector.name} is not connected — an admin can add its key`);
				return tool.run(input, { ...ctx, secret, fetch: fetchImpl });
			},
		}),
	);
}

export async function readJson(response: Response, service: string): Promise<unknown> {
	const text = await response.text();
	if (!response.ok) throw new ToolError(`${service} answered ${response.status}: ${text.slice(0, 300)}`);
	try {
		return JSON.parse(text);
	} catch {
		return text;
	}
}
