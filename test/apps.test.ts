import { describe, expect, test } from 'bun:test';
import { defineApp, defineAssistant, json, z } from '@hq/sdk';
import { defineTool } from '../src/tools/define';
import { createHq } from '../src/hq';
import { scripted } from '../src/llm';
import { admin, client } from './helpers';

const counter = defineApp({
	slug: 'counter',
	name: 'Counter',
	description: 'Counts things',
	briefing: 'Use bump to count.',
	migrations: [{ id: '001_counts', up: 'CREATE TABLE counter_counts (name TEXT PRIMARY KEY, n INTEGER NOT NULL)' }],
	tools: [
		defineTool({
			name: 'bump',
			description: 'Bump a counter',
			input: z.object({ name: z.string() }),
			run: ({ name }, { hub }) =>
				hub.db
					.query<{ n: number }, { name: string }>(
						'INSERT INTO counter_counts (name, n) VALUES ($name, 1) ON CONFLICT(name) DO UPDATE SET n = n + 1 RETURNING n',
					)
					.get({ name })!.n,
		}),
	],
	routes: [
		{
			method: 'GET',
			path: 'counts',
			handler: ({ hub }) => hub.db.query('SELECT * FROM counter_counts').all(),
		},
		{ method: 'POST', path: 'ping', handler: ({ app }) => json({ pong: app.slug }) },
	],
});

describe('apps', () => {
	test('migrations, tools and routes all mount', async () => {
		const hq = createHq({ apps: [counter] });
		const ada = admin(hq);
		const as = client(hq, ada.key);
		await hq.registry.call('bump', { name: 'coffee' }, { hub: hq.hub, caller: ada.person });
		await hq.registry.call('bump', { name: 'coffee' }, { hub: hq.hub, caller: ada.person });
		expect((await as('GET', '/apps/counter/api/counts')).body).toEqual([{ name: 'coffee', n: 2 }]);
		expect((await as('POST', '/apps/counter/api/ping')).body).toEqual({ pong: 'counter' });
		expect((await as('GET', '/v1/apps')).body[0]).toEqual({
			slug: 'counter',
			name: 'Counter',
			description: expect.any(String),
			icon: null,
			tools: ['bump'],
		});
		expect((await hq.fetch(new Request('http://hq.test/apps/counter')))?.status).toBe(404);
		expect(hq.hub.db.query("SELECT id FROM _migrations WHERE id = 'counter/001_counts'").get()).not.toBeNull();
	});

	test('briefings reach the assistant prompt', async () => {
		const provider = scripted([{ content: 'ok' }]);
		const hq = createHq({
			provider,
			apps: [counter],
			assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', model: 'm' }),
		});
		const ada = admin(hq);
		hq.hub.messages.send({ conversationId: hq.hub.general().id, authorId: ada.person.id, body: '@atlas hi' });
		await hq.assistant.runner.idle();
		const system = provider.requests[0]!.messages[0]!.content;
		expect(system).toContain('### Counter\nUse bump to count.');
	});

	test('setup gets a context that can post', () => {
		const hq = createHq({
			apps: [
				defineApp({
					slug: 'greeter',
					name: 'Greeter',
					description: 'Says hi',
					setup: (app) => {
						app.assistant.post(app.hub.general().id, 'hello team');
					},
				}),
			],
		});
		expect(hq.hub.messages.list(hq.hub.general().id).map((m) => m.body)).toEqual(['hello team']);
	});

	test('public routes skip sign-in but still see the caller when there is one', async () => {
		const hq = createHq({
			apps: [
				defineApp({
					slug: 'hooks',
					name: 'Hooks',
					description: 'Inbound hooks',
					routes: [
						{
							method: 'POST',
							path: 'in',
							access: 'public',
							handler: async ({ req, person, app }) => ({ app: app.slug, body: await req.text(), by: person?.handle ?? null }),
						},
						{ method: 'GET', path: 'private', handler: ({ person }) => person.handle },
					],
				}),
			],
		});
		const ada = admin(hq);
		expect((await client(hq)('POST', '/apps/hooks/api/in', { x: 1 })).body).toEqual({ app: 'hooks', body: '{"x":1}', by: null });
		expect((await client(hq, ada.key)('POST', '/apps/hooks/api/in', {})).body.by).toBe('ada');
		expect((await client(hq)('GET', '/apps/hooks/api/private')).status).toBe(401);
	});

	test('apps read connector secrets from the vault and call out through the injected fetch', async () => {
		const seen: string[] = [];
		const fakeFetch = (async (input: string | URL, init: RequestInit = {}) => {
			seen.push(`${input} ${(init.headers as Record<string, string>).authorization}`);
			return Response.json({ ok: true });
		}) as unknown as typeof fetch;
		const hq = createHq({
			vaultKey: 'test-key',
			fetch: fakeFetch,
			apps: [
				defineApp({
					slug: 'caller',
					name: 'Caller',
					description: 'Calls out',
					routes: [
						{
							method: 'POST',
							path: 'go',
							handler: async ({ app }) => {
								if (!app.secrets.has('svc')) return { configured: false };
								const token = await app.secrets.get('svc');
								return (await app.fetch('https://svc.test/x', { headers: { authorization: `Bearer ${token}` } })).json();
							},
						},
					],
				}),
			],
		});
		const as = client(hq, admin(hq).key);
		expect((await as('POST', '/apps/caller/api/go')).body).toEqual({ configured: false });
		await hq.vault.set('svc', 's3cret');
		expect((await as('POST', '/apps/caller/api/go')).body).toEqual({ ok: true });
		expect(seen).toEqual(['https://svc.test/x Bearer s3cret']);
	});

	test('apps can call each other through tools', async () => {
		const hq = createHq({ apps: [counter] });
		const app = hq.apps.get('counter')!;
		expect(app.tools.has('bump')).toBe(true);
		expect(app.tools.has('nope')).toBe(false);
		await app.tools.call('bump', { name: 'x' });
		expect(await app.tools.call('bump', { name: 'x' })).toEqual({ ok: true, value: 2 });
		expect(await app.tools.call('nope', {})).toEqual({ ok: false, error: 'unknown tool: nope' });
	});

	test('duplicate slugs and bad slugs are refused', () => {
		expect(() => createHq({ apps: [counter, counter] })).toThrow('counter');
		expect(() => defineApp({ slug: 'Bad Slug', name: '', description: '' })).toThrow();
	});
});

describe('app.tools.call scoping', () => {
	test('a call made for a conversation only reaches what its members can see', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const secret = hq.hub.conversations.createRoom({ title: 'Ada only', createdBy: ada.person.id });
		hq.hub.messages.send({ conversationId: secret.id, authorId: ada.person.id, body: 'launch code 42' });
		const shared = hq.hub.conversations.createRoom({ title: 'Shared', createdBy: ada.person.id, memberIds: [bo.id] });
		const { appContext } = await import('../src/apps/mount');
		const tools = appContext(hq.hub, 'probe', {
			assistant: { self: hq.assistant.self, post: () => ({}) as never, ask: async () => '' },
			secrets: { has: () => false, get: async () => null },
			ai: {} as never,
			registry: hq.registry,
		}).tools;
		const scoped = await tools.call('read_conversation', { conversation_id: secret.id }, { conversationId: shared.id });
		expect(scoped.ok).toBe(false);
		const own = await tools.call('read_conversation', { conversation_id: secret.id }, { conversationId: secret.id });
		expect(JSON.stringify(own)).toContain('launch code 42');
	});
});

describe('public route bodies', () => {
	const hooks = defineApp({
		slug: 'sink',
		name: 'Sink',
		description: 'Takes bodies',
		routes: [
			{ method: 'POST', path: 'in', access: 'public', handler: async ({ req }) => ({ bytes: (await req.text()).length }) },
			{
				method: 'POST',
				path: 'big',
				access: 'public',
				maxBodyBytes: 4 * 1024 * 1024,
				handler: async ({ req }) => ({ bytes: (await req.arrayBuffer()).byteLength }),
			},
		],
	});
	const post = (hq: ReturnType<typeof createHq>, path: string, body: BodyInit, headers: Record<string, string> = {}) =>
		hq.fetch(new Request(`http://hq.test/apps/sink/api/${path}`, { method: 'POST', body, headers })) as Promise<Response>;

	test('are capped at 1 MB unless the route allows more', async () => {
		const hq = createHq({ apps: [hooks] });
		const mb = 1024 * 1024;
		expect(await (await post(hq, 'in', 'x'.repeat(10))).json()).toEqual({ bytes: 10 });
		expect((await post(hq, 'in', 'x'.repeat(mb + 1))).status).toBe(413);
		expect(await (await post(hq, 'big', 'x'.repeat(2 * mb))).json()).toEqual({ bytes: 2 * mb });
	});

	test('a streamed body without a length is cut off too', async () => {
		const hq = createHq({ apps: [hooks] });
		const chunk = new Uint8Array(256 * 1024);
		let sent = 0;
		const stream = new ReadableStream<Uint8Array>({
			pull(controller) {
				if (sent++ < 8) controller.enqueue(chunk);
				else controller.close();
			},
		});
		expect((await post(hq, 'in', stream)).status).toBe(413);
	});
});
