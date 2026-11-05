import { afterEach, describe, expect, spyOn, test } from 'bun:test';
import type { Server } from 'bun';
import { defineApp, json, type AppDefinition } from '@hq/sdk';
import { createHq, type HqOptions } from '../src/hq';
import { migrations as pushMigrations } from '../src/push';
import type { SocketData } from '../src/realtime/socket';
import { admin, client, connect, enrolled, pair, serve, type Connection } from './helpers';

// The places a feature plugs into the server without editing a shared file: its own `/v1` routes, migrations, socket
// frames, online devices and the calls snapshot.

const app = (slug: string, extra: Partial<AppDefinition> = {}) => defineApp({ slug, name: slug, description: slug, ...extra });

describe('a route mounted at v1', () => {
	const things = app('things', {
		routes: [
			{ method: 'GET', path: '/v1/things', mount: 'v1', handler: ({ person }) => ({ for: person.handle }) },
			{ method: 'POST', path: '/v1/things', mount: 'v1', handler: async ({ req }) => json({ size: (await req.text()).length }) },
			{ method: 'GET', path: '/v1/things-admin', mount: 'v1', access: 'admin', handler: () => ({ ok: true }) },
			{ method: 'GET', path: 'inside', handler: () => ({ where: 'api' }) },
		],
	});

	test('is served at its own path behind sign-in, and nowhere under /apps', async () => {
		const { a, b, hq, ada } = await pair({ apps: [things] });
		expect(await a.as('GET', '/v1/things')).toEqual({ status: 200, body: { for: 'ada' } });
		expect((await client(hq)('GET', '/v1/things')).status).toBe(401);
		expect((await client(hq, 'hq_not-a-key')('GET', '/v1/things')).status).toBe(401);
		expect((await a.as('GET', '/apps/things/api/v1/things')).status).toBe(404);
		expect((await a.as('GET', '/apps/things/api/things')).status).toBe(404);
		// Access is the route's own: the member is refused where the admin is not.
		expect((await a.as('GET', '/v1/things-admin')).status).toBe(200);
		expect((await b.as('GET', '/v1/things-admin')).status).toBe(403);
		// And, as with core's people admin, from a signed-in device: an admin's script key is refused.
		expect((await client(hq, ada.key)('GET', '/v1/things-admin')).status).toBe(403);
		// A route without a mount is where it always was.
		expect((await a.as('GET', '/apps/things/api/inside')).body).toEqual({ where: 'api' });
		expect((await a.as('GET', '/v1/inside')).status).toBe(404);
	});

	test('takes no more body than a core /v1 route', async () => {
		const { a } = await pair({ apps: [things] });
		expect((await a.as('POST', '/v1/things', { text: 'x'.repeat(1000) })).status).toBe(200);
		const big = await a.as('POST', '/v1/things', { text: 'x'.repeat(1024 * 1024 + 1) });
		expect(big).toEqual({ status: 413, body: { error: 'payload_too_large' } });
	});

	test.each([
		['outside /v1', { method: 'GET', path: '/things' }],
		['not a path under /v1', { method: 'GET', path: '/v1' }],
		['sign-in, which is answered before any route', { method: 'POST', path: '/v1/enroll' }],
		['sign-in with a trailing slash', { method: 'POST', path: '/v1/enroll/' }],
		['the socket, likewise', { method: 'GET', path: '/v1/ws/' }],
		['a dot-dot segment', { method: 'GET', path: '/v1/x/../people' }],
		['an empty segment', { method: 'GET', path: '/v1//x' }],
		['a room’s own namespace, whose membership checks it would skip', { method: 'GET', path: '/v1/conversations/:id/tasks' }],
		['the same, bare', { method: 'GET', path: '/v1/conversations' }],
		['a message’s', { method: 'GET', path: '/v1/messages/:id/tasks' }],
		['an attachment’s', { method: 'GET', path: '/v1/attachments/:id/text' }],
		['no sign-in at all', { method: 'GET', path: '/v1/open', access: 'public' }],
		['a body cap above the server’s', { method: 'POST', path: '/v1/big', maxBodyBytes: 2 * 1024 * 1024 }],
	] as const)('refuses at startup a route that could not be served as core’s are: %s', (_, route) => {
		const bad = app('bad', { routes: [{ ...route, mount: 'v1', handler: () => ({}) }] });
		expect(() => createHq({ apps: [bad] })).toThrow(/bad: .* cannot/);
	});

	test('may lower the body cap', async () => {
		const small = app('small', {
			routes: [
				{ method: 'POST', path: '/v1/small', mount: 'v1', maxBodyBytes: 20, handler: async ({ req }) => json(await req.json()) },
			],
		});
		const { a } = await pair({ apps: [small] });
		expect((await a.as('POST', '/v1/small', { n: 1 })).status).toBe(200);
		expect((await a.as('POST', '/v1/small', { text: 'x'.repeat(100) })).status).toBe(413);
	});
});

describe('routes that can take the same request', () => {
	const route = (method: 'GET' | 'POST' | 'DELETE', path: string, mount?: 'v1') => ({ method, path, mount, handler: () => ({}) });
	const boot =
		(...apps: AppDefinition[]) =>
		() =>
			createHq({ apps });
	const one = (method: 'GET' | 'POST' | 'DELETE', path: string) => boot(app('x', { routes: [route(method, path, 'v1')] }));

	test.each([
		['core’s own path', 'GET', '/v1/people'],
		['core’s path with other parameter names', 'POST', '/v1/automations/:x/:y/run'],
		['a literal where core has a parameter (a member would beat an admin route)', 'DELETE', '/v1/connectors/github'],
		['a parameter where core has literals', 'GET', '/v1/:thing'],
		['a wildcard over core’s paths', 'GET', '/v1/*'],
		['a wildcard tail under a core path', 'GET', '/v1/people/*'],
		['the apps list', 'GET', '/v1/apps'],
	] as const)('an app v1 route may not take %s', (_, method, path) => {
		expect(one(method, path)).toThrow(/two routes overlap: .*/);
	});

	test('nor may two apps’ routes, or one app’s, however they are written', () => {
		const two = (a: string, b: string) => () =>
			createHq({ apps: [app('x', { routes: [route('GET', a, 'v1')] }), app('y', { routes: [route('GET', b, 'v1')] })] });
		expect(two('/v1/shared', '/v1/shared/')).toThrow('two routes overlap: GET /v1/shared and GET /v1/shared/');
		expect(two('/v1/things/:id', '/v1/things/:slug')).toThrow('two routes overlap');
		expect(two('/v1/things/new', '/v1/things/:id')).toThrow('two routes overlap');
		expect(two('/v1/things/:id/a', '/v1/things/*')).toThrow('two routes overlap');
		expect(boot(app('x', { routes: [route('GET', '/v1/t/:id', 'v1'), route('GET', '/v1/t/:id', 'v1')] }))).toThrow(
			'two routes overlap',
		);
	});

	test.each([
		['another method', 'POST', '/v1/things/:id'],
		['a longer path', 'GET', '/v1/things/:id/more'],
		['another literal', 'GET', '/v1/aaa/:id'],
	] as const)('do not conflict by %s', (_, method, path) => {
		const hq = createHq({ apps: [app('x', { routes: [route('GET', '/v1/things/:id', 'v1'), route(method, path, 'v1')] })] });
		expect(hq.apps.has('x')).toBe(true);
	});

	test('in an app’s routes under /apps only warn, so an app that started before still starts', () => {
		const warn = spyOn(console, 'warn').mockImplementation(() => {});
		try {
			const hq = createHq({
				apps: [
					app('x', { routes: [route('GET', 'same'), route('GET', '/same'), route('GET', 'item/new'), route('GET', 'item/:id')] }),
				],
			});
			expect(hq.apps.has('x')).toBe(true);
			expect(warn.mock.calls.map(([line]) => String(line))).toEqual([
				'[http] two routes overlap: GET /apps/x/api/same and GET /apps/x/api/same',
				'[http] two routes overlap: GET /apps/x/api/item/new and GET /apps/x/api/item/:id',
			]);
		} finally {
			warn.mockRestore();
		}
	});

	test('the bundled apps start without a warning', async () => {
		const warn = spyOn(console, 'warn').mockImplementation(() => {});
		try {
			const apps = await Promise.all(
				['docs', 'reminders', 'meetings', 'tasks', 'library'].map(async (slug) => (await import(`../apps/${slug}/app`)).default),
			);
			createHq({ apps });
			expect(warn).not.toHaveBeenCalled();
		} finally {
			warn.mockRestore();
		}
	});

	test('do not stop a method another router has on that path from being served: POST /v1/search next to core’s GET', async () => {
		const place = app('place', {
			routes: [{ method: 'POST', path: '/v1/search', mount: 'v1', handler: () => ({ placed: true }) }],
		});
		const { a, hq } = await pair({ apps: [place] });
		expect(await a.as('POST', '/v1/search')).toEqual({ status: 200, body: { placed: true } });
		expect((await a.as('GET', '/v1/search')).status).toBe(200);
		const other = await hq.fetch(new Request('http://hq.test/v1/search', { method: 'DELETE' }));
		expect(other?.status).toBe(405);
		expect(other?.headers.get('allow')?.split(', ').sort()).toEqual(['GET', 'POST']);
		// With no one else on the path the answer is what it was.
		const plain = await (await pair()).hq.fetch(new Request('http://hq.test/v1/search', { method: 'POST' }));
		expect(plain?.status).toBe(405);
		expect(plain?.headers.get('allow')).toBe('GET');
	});

	test('keep a handler’s own 405: only a router’s “this path takes other methods” falls through', async () => {
		const teapot = app('teapot', {
			routes: [
				{
					method: 'GET',
					path: 'tea',
					handler: () => new Response('mine', { status: 405, headers: { allow: 'POST', 'x-own': '1' } }),
				},
			],
		});
		const { hq, a } = await pair({ apps: [teapot] });
		const res = await hq.fetch(
			new Request('http://hq.test/apps/teapot/api/tea', { headers: { authorization: `Bearer ${a.bearer}` } }),
		);
		expect([res?.status, res?.headers.get('x-own'), await res?.text()]).toEqual([405, '1', 'mine']);
	});
});

describe('migrations from a feature module', () => {
	test('are run once, and a module with none adds nothing', () => {
		pushMigrations.push({ id: 'push/probe', up: 'CREATE TABLE push_probe (id TEXT PRIMARY KEY)' });
		try {
			const hq = createHq();
			expect(hq.hub.db.query("SELECT id FROM _migrations WHERE id = 'push/probe'").get()).not.toBeNull();
			expect(hq.hub.db.query("SELECT name FROM sqlite_master WHERE name = 'push_probe'").get()).not.toBeNull();
		} finally {
			pushMigrations.pop();
		}
		expect(createHq().hub.db.query("SELECT id FROM _migrations WHERE id = 'push/probe'").all()).toEqual([]);
	});
});

describe('the socket', () => {
	let server: Server<SocketData> | undefined;
	let open: Connection[] = [];
	afterEach(() => {
		for (const connection of open) connection.ws.close();
		open = [];
		void server?.stop(true);
	});
	const track = async (connection: Promise<Connection>) => {
		const ready = await connection;
		open.push(ready);
		return ready;
	};

	async function world(options: HqOptions = {}) {
		const made = await pair(options);
		server = serve(made.hq);
		const cy = await enrolled(made.hq, made.hq.hub.keys.mint(made.hq.hub.people.create({ name: 'Cy', handle: 'cy' }).id).secret);
		const sockets = {
			a: await track(connect(server, made.a.bearer)),
			b: await track(connect(server, made.b.bearer)),
			cy: await track(connect(server, cy.bearer)),
		};
		const got = async (sendFrame: () => void) => {
			sendFrame();
			await Promise.all(
				Object.values(sockets)
					.filter((s) => s.ws.readyState === WebSocket.OPEN)
					.map((s) => s.settle()),
			);
			const heard = (s: Connection) => s.frames.filter((f) => f.type === 'seam').map((f) => f.n);
			return { a: heard(sockets.a), b: heard(sockets.b), cy: heard(sockets.cy) };
		};
		return { ...made, cy, sockets, got };
	}

	describe('a frame event', () => {
		test('reaches the people in its audience, and no one else', async () => {
			const { hq, a, b, got } = await world();
			const audience = [a.person.id, b.person.id];
			expect(await got(() => hq.hub.bus.emit({ type: 'frame', audience, frame: { type: 'seam', n: 1 } }))).toEqual({
				a: [1],
				b: [1],
				cy: [],
			});
			expect(await got(() => hq.hub.bus.emit({ type: 'frame', audience: [], frame: { type: 'seam', n: 2 } }))).toEqual({
				a: [1],
				b: [1],
				cy: [],
			});
		});

		test('goes to everyone connected when the audience is “everyone”', async () => {
			const { hq, got } = await world();
			expect(await got(() => hq.hub.bus.emit({ type: 'frame', audience: 'everyone', frame: { type: 'seam', n: 1 } }))).toEqual({
				a: [1],
				b: [1],
				cy: [1],
			});
		});

		test('tied to a room goes only to the audience in it now: not a non-member, and nothing once the room is archived', async () => {
			const { hq, a, b, cy, room, got } = await world();
			const everyone = [a.person.id, b.person.id, cy.person.id];
			const emit = (n: number, audience?: string[]) =>
				hq.hub.bus.emit({ type: 'frame', ...(audience && { audience }), frame: { type: 'seam', n }, conversationId: room.id });
			// Cy is in the audience but not in the room.
			expect(await got(() => emit(1, everyone))).toEqual({ a: [1], b: [1], cy: [] });
			// With no audience it is the room’s members.
			expect(await got(() => emit(2))).toEqual({ a: [1, 2], b: [1, 2], cy: [] });
			// Bo leaves; the event was built with him in it.
			expect((await b.as('DELETE', `/v1/conversations/${room.id}/members/me`)).status).toBe(200);
			expect(await got(() => emit(3, everyone))).toEqual({ a: [1, 2, 3], b: [1, 2], cy: [] });
			expect(await got(() => emit(4))).toEqual({ a: [1, 2, 3, 4], b: [1, 2], cy: [] });
			// Archived: it delivers nothing, even to someone the event names.
			hq.hub.conversations.archive(room.id);
			expect(await got(() => emit(5, everyone))).toEqual({ a: [1, 2, 3, 4], b: [1, 2], cy: [] });
			expect(await got(() => emit(6))).toEqual({ a: [1, 2, 3, 4], b: [1, 2], cy: [] });
			// The same frame with no room is not held back.
			expect(await got(() => hq.hub.bus.emit({ type: 'frame', audience: everyone, frame: { type: 'seam', n: 7 } }))).toEqual({
				a: [1, 2, 3, 4, 7],
				b: [1, 2, 7],
				cy: [7],
			});
		});

		test('fails closed: no one named and no room is an error at the emit, and nothing is sent', async () => {
			const { hq, room, got } = await world();
			const frame = { type: 'seam', n: 1 };
			const bad = [
				{ type: 'frame', frame },
				{ type: 'frame', audience: null, frame },
				{ type: 'frame', audience: 'all', frame },
				{ type: 'frame', audience: [1], frame },
				{ type: 'frame', audience: 'everyone', frame, conversationId: room.id },
			];
			for (const event of bad) expect(() => hq.hub.bus.emit(event as never)).toThrow(/frame/);
			expect(await got(() => {})).toEqual({ a: [], b: [], cy: [] });
		});

		test('does not reach a socket whose key was revoked', async () => {
			const { hq, a, b, sockets, got } = await world();
			hq.hub.devices.revoke(b.deviceId);
			await sockets.b.closed;
			expect(
				await got(() => hq.hub.bus.emit({ type: 'frame', audience: [a.person.id, b.person.id], frame: { type: 'seam', n: 1 } })),
			).toMatchObject({
				a: [1],
				b: [],
			});
		});
	});

	describe('onlineDevices', () => {
		const settled = async (hq: { socket: { onlineDevices(): Set<string> } }, want: string[]) => {
			for (let i = 0; i < 100 && hq.socket.onlineDevices().size !== want.length; i++) await Bun.sleep(10);
			return [...hq.socket.onlineDevices()].sort();
		};

		test('lists the devices with a socket open: none, then one per connect, then fewer as they close', async () => {
			const { hq, a, b } = await pair();
			server = serve(hq);
			expect([...hq.socket.onlineDevices()]).toEqual([]);
			const first = await track(connect(server, a.bearer));
			expect([...hq.socket.onlineDevices()]).toEqual([a.deviceId]);
			// A second socket of the same device, and a second device, are each one entry.
			await track(connect(server, a.bearer));
			const second = await track(connect(server, b.bearer));
			expect([...hq.socket.onlineDevices()].sort()).toEqual([a.deviceId, b.deviceId].sort());
			second.ws.close();
			expect(await settled(hq, [a.deviceId])).toEqual([a.deviceId]);
			first.ws.close();
			expect(await settled(hq, [a.deviceId])).toEqual([a.deviceId]);
			for (const connection of open) connection.ws.close();
			expect(await settled(hq, [])).toEqual([]);
		});

		test('drops a device whose key was revoked', async () => {
			const { hq, a, b } = await pair();
			server = serve(hq);
			await track(connect(server, a.bearer));
			const gone = await track(connect(server, b.bearer));
			await b.as('POST', `/v1/devices/${b.deviceId}/revoke`);
			await gone.closed;
			expect(await settled(hq, [a.deviceId])).toEqual([a.deviceId]);
		});
	});
});

describe('the calls snapshot', () => {
	const meeting = { id: 'm1', title: 'Standup' };
	const meetings = app('meet', { calls: (_, person) => ({ meetings: [{ ...meeting, for: person.handle }] }) });
	const ringer = app('ring', { calls: () => ({ ringing: [{ id: 'r1' }], calls: [{ id: 'c1' }] }) });

	test('is three empty lists when no app adds to it', async () => {
		const { a } = await pair({ apps: [app('plain')] });
		expect(await a.as('GET', '/v1/calls')).toEqual({ status: 200, body: { calls: [], meetings: [], ringing: [] } });
	});

	test('has what apps add, for the person asking, joined across apps', async () => {
		const { a, b } = await pair({ apps: [meetings, ringer] });
		expect((await a.as('GET', '/v1/calls')).body).toEqual({
			calls: [{ id: 'c1' }],
			meetings: [{ ...meeting, for: 'ada' }],
			ringing: [{ id: 'r1' }],
		});
		expect((await b.as('GET', '/v1/calls')).body.meetings).toEqual([{ ...meeting, for: 'bo' }]);
	});

	test('still answers when an app’s hook fails, without that app’s part', async () => {
		const broken = app('broken', {
			calls: () => {
				throw new Error('boom');
			},
		});
		const quiet = spyOn(console, 'error').mockImplementation(() => {});
		try {
			const { a } = await pair({ apps: [broken, meetings] });
			expect((await a.as('GET', '/v1/calls')).body).toEqual({ calls: [], meetings: [{ ...meeting, for: 'ada' }], ringing: [] });
			expect(quiet).toHaveBeenCalled();
		} finally {
			quiet.mockRestore();
		}
	});

	test('takes nothing from a hook that fails part way, or answers a list that is not one', async () => {
		const part = app('part', { calls: () => ({ calls: [{ id: 'leaked' }], meetings: 5 as never }) });
		const nothing = app('nothing', { calls: () => null as never });
		const quiet = spyOn(console, 'error').mockImplementation(() => {});
		try {
			const { a } = await pair({ apps: [part, nothing, meetings] });
			expect((await a.as('GET', '/v1/calls')).body).toEqual({ calls: [], meetings: [{ ...meeting, for: 'ada' }], ringing: [] });
			expect(quiet).toHaveBeenCalledTimes(2);
		} finally {
			quiet.mockRestore();
		}
	});

	test('needs a sign-in', async () => {
		const hq = createHq({ apps: [meetings] });
		admin(hq);
		expect((await client(hq)('GET', '/v1/calls')).status).toBe(401);
	});
});
