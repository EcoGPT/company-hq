import { describe, expect, test } from 'bun:test';
import tasks from '../apps/tasks/app';
import { createHq } from '../src/hq';
import { admin } from './helpers';

function rpc(hq: ReturnType<typeof createHq>, key: string | null, body: unknown) {
	return hq.fetch(
		new Request('http://hq.test/mcp', {
			method: 'POST',
			headers: { 'content-type': 'application/json', ...(key ? { authorization: `Bearer ${key}` } : {}) },
			body: JSON.stringify(body),
		}),
	) as Promise<Response>;
}

describe('mcp', () => {
	test('initialize, list and call tools as the key holder', async () => {
		const hq = createHq({ apps: [tasks] });
		const ada = admin(hq);
		const init = await (
			await rpc(hq, ada.key, { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } })
		).json();
		expect(init.result.protocolVersion).toBe('2025-06-18');
		expect(init.result.instructions).toContain('@ada');
		expect((await rpc(hq, ada.key, { jsonrpc: '2.0', method: 'notifications/initialized' })).status).toBe(202);

		const list = await (await rpc(hq, ada.key, { jsonrpc: '2.0', id: 2, method: 'tools/list' })).json();
		const names = list.result.tools.map((t: { name: string }) => t.name);
		expect(names).toContain('add_task');
		expect(names).not.toContain('remember');
		expect(list.result.tools.find((t: { name: string }) => t.name === 'add_task').inputSchema.type).toBe('object');

		const call = await (
			await rpc(hq, ada.key, {
				jsonrpc: '2.0',
				id: 3,
				method: 'tools/call',
				params: { name: 'add_task', arguments: { title: 'From MCP' } },
			})
		).json();
		expect(call.result.isError).toBe(false);
		expect(JSON.parse(call.result.content[0].text).title).toBe('From MCP');
	});

	test('assistant-only tools and bad calls are errors', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const call = await (
			await rpc(hq, ada.key, {
				jsonrpc: '2.0',
				id: 1,
				method: 'tools/call',
				params: { name: 'remember', arguments: { fact: 'nope' } },
			})
		).json();
		expect(call.result.isError).toBe(true);
		const unknown = await (await rpc(hq, ada.key, { jsonrpc: '2.0', id: 2, method: 'resources/list' })).json();
		expect(unknown.error.code).toBe(-32601);
	});

	test('auth is required; GET is not supported', async () => {
		const hq = createHq();
		expect((await rpc(hq, null, { jsonrpc: '2.0', id: 1, method: 'ping' })).status).toBe(401);
		const get = (await hq.fetch(new Request('http://hq.test/mcp'))) as Response;
		expect(get.status).toBe(405);
		expect(get.headers.get('allow')).toBe('POST');
		expect(await get.json()).toEqual({ error: 'method not allowed' });
	});
});
