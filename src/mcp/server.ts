import type { Hub } from '../core/hub';
import type { Person } from '../core/people';
import { bearer, HttpError, methodNotAllowed } from '../http/router';
import { ProviderError } from '../llm/types';
import { errorMessage, toSpec } from '../tools/define';
import { formatResult, type ToolRegistry } from '../tools/registry';

const SUPPORTED = ['2025-06-18', '2025-03-26', '2024-11-05'];

type JsonRpcRequest = { jsonrpc: '2.0'; id?: string | number | null; method: string; params?: Record<string, unknown> };

class RpcError extends Error {
	constructor(
		readonly code: number,
		message: string,
	) {
		super(message);
	}
}

function rpcError(id: JsonRpcRequest['id'], code: number, message: string): Response {
	return Response.json({ jsonrpc: '2.0', id: id ?? null, error: { code, message } });
}

export function createMcp(hub: Hub, registry: ToolRegistry, info: { name: string; version: string }) {
	async function dispatch(person: Person, request: JsonRpcRequest): Promise<unknown> {
		const ctx = { hub, caller: person };
		switch (request.method) {
			case 'initialize': {
				const asked = String(request.params?.protocolVersion ?? '');
				return {
					protocolVersion: SUPPORTED.includes(asked) ? asked : SUPPORTED[0],
					capabilities: { tools: { listChanged: false } },
					serverInfo: info,
					instructions: `You are connected to HQ as ${person.name} (@${person.handle}). Tools act with your access: you can only read and post in conversations you are a member of.`,
				};
			}
			case 'ping':
				return {};
			case 'tools/list':
				return {
					tools: registry.list('everyone', ctx).map((tool) => {
						const spec = toSpec(tool);
						return { name: spec.name, description: spec.description, inputSchema: spec.parameters };
					}),
				};
			case 'tools/call': {
				const name = String(request.params?.name ?? '');
				const result = await registry.call(name, request.params?.arguments ?? {}, ctx, 'everyone');
				return { content: [{ type: 'text', text: formatResult(result, 100_000) }], isError: !result.ok };
			}
			default:
				throw new RpcError(-32601, `method not found: ${request.method}`);
		}
	}

	return async function handle(req: Request): Promise<Response> {
		if (req.method !== 'POST') return methodNotAllowed(['POST']);
		const auth = hub.keys.check(bearer(req));
		if (!auth.ok) return Response.json({ error: auth.error }, { status: 401, headers: { 'www-authenticate': 'Bearer' } });
		const { person } = auth;
		let request: JsonRpcRequest;
		try {
			request = (await req.json()) as JsonRpcRequest;
		} catch (error) {
			// A body cut off for being too large gets the same answer as one that said so up front.
			if (error instanceof HttpError) throw error;
			return rpcError(null, -32700, 'parse error');
		}
		if (typeof request !== 'object' || request === null || typeof request.method !== 'string') {
			return rpcError(null, -32600, 'invalid request');
		}
		if (request.id === undefined || request.id === null) return new Response(null, { status: 202 });
		try {
			return Response.json({ jsonrpc: '2.0', id: request.id, result: await dispatch(person, request) });
		} catch (error) {
			if (error instanceof RpcError) return rpcError(request.id, error.code, error.message);
			if (error instanceof ProviderError) console.error('[mcp] provider error', error);
			return rpcError(request.id, -32603, errorMessage(error));
		}
	};
}
