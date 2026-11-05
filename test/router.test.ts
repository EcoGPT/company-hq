import { describe, expect, spyOn, test } from 'bun:test';
import { z } from 'zod';
import { Hub } from '../src/core/hub';
import { HttpError, readBody, Router } from '../src/http/router';
import { anthropic } from '../src/llm/anthropic';
import { ProviderError } from '../src/llm/types';

function setup() {
	const hub = Hub.open();
	const admin = hub.people.create({ name: 'Ada', handle: 'ada', role: 'admin' });
	const member = hub.people.create({ name: 'Bo', handle: 'bo' });
	return {
		hub,
		adminKey: hub.keys.mint(admin.id).secret,
		memberKey: hub.keys.mint(member.id).secret,
	};
}

const call = (router: Router, hub: Hub, path: string, init: RequestInit & { key?: string } = {}) =>
	router.handle(
		new Request(`http://hq.test${path}`, {
			...init,
			headers: { ...(init.key ? { authorization: `Bearer ${init.key}` } : {}), 'content-type': 'application/json' },
		}),
		hub,
	);

describe('router', () => {
	test('a member route fills params, requires a key and returns JSON', async () => {
		const { hub, memberKey } = setup();
		const router = new Router().get('/v1/things/:id', ({ params, person }) => ({ id: params.id, by: person.handle }));
		expect(await (await call(router, hub, '/v1/things/42', { key: memberKey }))!.json()).toEqual({ id: '42', by: 'bo' });
		expect((await call(router, hub, '/v1/things/42'))!.status).toBe(401);
		expect(await call(router, hub, '/nope')).toBeNull();
	});

	test('an admin route refuses members', async () => {
		const { hub, adminKey, memberKey } = setup();
		const router = new Router().post('/v1/admin', () => ({ ok: true }), 'admin');
		expect((await call(router, hub, '/v1/admin', { method: 'POST', key: memberKey }))!.status).toBe(403);
		expect((await call(router, hub, '/v1/admin', { method: 'POST', key: adminKey }))!.status).toBe(200);
	});

	test('public routes need no key; wrong methods are 405, undefined is 204, HttpError keeps its status', async () => {
		const { hub, memberKey } = setup();
		const router = new Router()
			.public('GET', '/healthz', () => 'ok')
			.post('/v1/empty', () => undefined)
			.public('GET', '/teapot', () => {
				throw new HttpError(418, 'short and stout');
			});
		expect(await (await call(router, hub, '/healthz'))!.json()).toBe('ok');
		const wrong = (await call(router, hub, '/healthz', { method: 'POST' }))!;
		expect(wrong.status).toBe(405);
		expect(wrong.headers.get('allow')).toBe('GET');
		expect(await wrong.json()).toEqual({ error: 'method not allowed' });
		expect((await call(router, hub, '/v1/empty', { method: 'POST', key: memberKey }))!.status).toBe(204);
		expect((await call(router, hub, '/teapot'))!.status).toBe(418);
		expect(await (await call(router, hub, '/teapot'))!.json()).toEqual({ error: 'short and stout' });
	});

	test('readBody parses against the schema and rejects with an HttpError', async () => {
		const schema = z.object({ title: z.string() });
		const ok = new Request('http://x', { method: 'POST', body: JSON.stringify({ title: 't' }) });
		expect(await readBody(ok, schema)).toEqual({ title: 't' });
		const bad = new Request('http://x', { method: 'POST', body: JSON.stringify({ title: 1 }) });
		await expect(readBody(bad, schema)).rejects.toBeInstanceOf(HttpError);
	});

	test('a wildcard captures the rest of the path', async () => {
		const { hub } = setup();
		const router = new Router().public('GET', '/files/*', ({ params }) => params.rest);
		expect(await (await call(router, hub, '/files/a/b.txt'))!.json()).toBe('a/b.txt');
	});
});

describe('tool errors in routes', () => {
	test('become a 400 with their message', async () => {
		const { ToolError } = await import('../src/tools/define');
		const hub = Hub.open();
		const router = new Router().public('GET', '/refuse', () => {
			throw new ToolError('nobody has the handle @ghost');
		});
		const response = (await router.handle(new Request('http://hq.test/refuse'), hub))!;
		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: 'nobody has the handle @ghost' });
	});
});

describe('model provider errors in routes', () => {
	test('become a 502 naming only the provider and status', async () => {
		const provider = anthropic({
			apiKey: 'sk-ant-secret',
			fetch: (async () =>
				Response.json(
					{ type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' } },
					{ status: 401 },
				)) as unknown as typeof fetch,
		});
		const hub = Hub.open();
		const router = new Router().public('POST', '/recap', () =>
			provider.complete({ model: 'claude-test', messages: [{ role: 'user', content: 'hi' }] }),
		);
		using _ = spyOn(console, 'error').mockImplementation(() => {});
		const response = (await router.handle(new Request('http://hq.test/recap', { method: 'POST' }), hub))!;
		expect(response.status).toBe(502);
		const body = await response.json();
		expect(body).toEqual({ error: 'model provider error: anthropic (401)' });
		expect(JSON.stringify(body)).not.toContain('invalid x-api-key');
		expect(console.error).toHaveBeenCalledWith(
			'[http] POST /recap',
			expect.objectContaining({ message: 'anthropic: invalid x-api-key' }),
		);
	});

	test('say "no response" when the provider never answered', async () => {
		const hub = Hub.open();
		const router = new Router().public('POST', '/recap', () => {
			throw new ProviderError('openai-compatible', null, 'connect ECONNREFUSED, key ...abcd');
		});
		using _ = spyOn(console, 'error').mockImplementation(() => {});
		const response = (await router.handle(new Request('http://hq.test/recap', { method: 'POST' }), hub))!;
		expect(await response.json()).toEqual({ error: 'model provider error: openai-compatible (no response)' });
	});
});
