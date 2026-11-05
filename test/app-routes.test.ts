import { describe, expect, test } from 'bun:test';
import fixture from './fixtures/swift-wire.json';
import type { Hq } from '../src/hq';
import { client, connect, pair, serve } from './helpers';

type Fields = Record<string, { required: boolean }>;
const structs = fixture.structs as Record<string, Fields>;

/** The object has every key the app requires and none it would ignore. */
function expectShape(name: string, value: unknown) {
	const spec = structs[name]!;
	const object = value as Record<string, unknown>;
	expect(Object.keys(object).filter((key) => !(key in spec))).toEqual([]);
	for (const [key, field] of Object.entries(spec)) if (field.required) expect(object[key]).toBeDefined();
}

describe('the app reads calls together with people and conversations', () => {
	test('GET /v1/calls answers the snapshot the app decodes, with nothing live yet', async () => {
		const { a } = await pair();
		const answer = await a.as('GET', '/v1/calls');
		expect(answer.status).toBe(200);
		expectShape('CallsSnapshot', answer.body);
		expect(answer.body).toEqual({ calls: [], meetings: [], ringing: [] });
		expect((await client((await pair()).hq)('GET', '/v1/calls')).status).toBe(401);
	});
});

describe('adding people from Settings', () => {
	test('POST /v1/keys adds a new person and returns the key the server made, which enrolls as many devices as they like', async () => {
		const { hq, a } = await pair();
		const minted = await a.as('POST', '/v1/keys', { person_name: 'Cy Young' });
		expect(minted.status).toBe(201);
		expect(Object.keys(minted.body).sort()).toEqual(['key', 'ok', 'person_name']);
		expect(minted.body).toMatchObject({ ok: true, person_name: 'Cy Young' });
		const key = minted.body.key as string;
		expect(key).toMatch(/^hq_[A-Za-z0-9_-]{43}$/);
		const cy = hq.hub.people.list().find((p) => p.name === 'Cy Young')!;
		expect(cy).toMatchObject({ kind: 'human', role: 'member', removed_at: null });
		expect(hq.hub.conversations.isMember(hq.hub.general().id, cy.id)).toBe(true);
		const phone = await client(hq)('POST', '/v1/enroll', { key, device_name: 'Phone' });
		const mac = await client(hq)('POST', '/v1/enroll', { key, device_name: 'Mac' });
		expect([phone.status, mac.status]).toEqual([201, 201]);
		expect(phone.body.person.id).toBe(cy.id);
		// It is only for signing in.
		expect((await client(hq, key)('GET', '/v1/me')).status).toBe(401);
		// Two people get two different keys.
		expect((await a.as('POST', '/v1/keys', { person_name: 'Dee' })).body.key).not.toBe(key);
	});

	test('a name that is already a person mints nothing: re-inviting is the operator’s `bun hq invite`', async () => {
		const { hq, a, b, ada } = await pair();
		const before = hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM api_keys').get()!.n;
		const people = hq.hub.people.list().length;
		const refused = { status: 409, body: { error: 'person_exists' } };
		for (const person_name of ['Bo', 'bo', ' BO ', 'Ada']) {
			expect(await a.as('POST', '/v1/keys', { person_name })).toEqual(refused);
		}
		// The assistant is a person too, by name and by handle: nobody may be added as it.
		expect(hq.assistant.self).toMatchObject({ name: 'Assistant', handle: 'assistant' });
		for (const person_name of ['Assistant', 'ASSISTANT', 'assistant']) {
			expect(await a.as('POST', '/v1/keys', { person_name })).toEqual(refused);
		}
		expect(hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM api_keys').get()!.n).toBe(before);
		expect(hq.hub.people.list()).toHaveLength(people);
		// The held key still works: nothing replaced Bo's invite or devices.
		expect((await b.as('GET', '/v1/me')).status).toBe(200);
		expect(ada.person.name).toBe('Ada');
	});

	test('a key in the body is refused, not ignored: the server makes every key', async () => {
		const { hq, a } = await pair();
		const refused = { status: 400, body: { error: 'key_not_allowed' } };
		const keys = hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM api_keys').get()!.n;
		for (const key of ['short', 'a-long-enough-key', '', null, 123]) {
			expect(await a.as('POST', '/v1/keys', { key, person_name: 'Eve' })).toEqual(refused);
		}
		expect(hq.hub.people.list().some((p) => p.name === 'Eve')).toBe(false);
		expect(hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM api_keys').get()!.n).toBe(keys);
		expect((await a.as('POST', '/v1/keys', { person_name: 'Eve' })).status).toBe(201);
	});

	test('a missing or empty name is invalid_body', async () => {
		const { a } = await pair();
		for (const body of [{}, { person_name: '' }, { person_name: '   ' }, { person_name: 5 }, 'Eve']) {
			expect((await a.as('POST', '/v1/keys', body)).body).toEqual({ error: 'invalid_body' });
		}
	});

	test('only an admin may: a member is refused with admin_only', async () => {
		const { hq, b, ada } = await pair();
		const refused = { status: 403, body: { error: 'admin_only' } };
		expect(await b.as('POST', '/v1/keys', { person_name: 'Eve' })).toEqual(refused);
		expect(await b.as('POST', `/v1/people/${ada.person.id}/role`, { is_admin: false })).toEqual(refused);
		expect(await b.as('POST', `/v1/people/${ada.person.id}/remove`)).toEqual(refused);
		expect(await b.as('POST', `/v1/people/${ada.person.id}/restore`)).toEqual(refused);
		expect(await b.as('POST', '/v1/people', { name: 'Eve', handle: 'eve' })).toEqual(refused);
		expect(hq.hub.people.get(ada.person.id)!.role).toBe('admin');
	});

	test('an admin’s MCP key or script key acts as them everywhere except here: admin_only, and nothing changes', async () => {
		const { hq, a, b, ada } = await pair();
		const mcp = (await a.as('POST', '/v1/mcp-keys', { label: 'agent', scopes: ['read', 'send'] })).body.key as string;
		const plain = hq.hub.keys.mint(ada.person.id, 'key', { label: 'cli' }).secret;
		const people = hq.hub.people.list().length;
		const keys = hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM api_keys').get()!.n;
		for (const key of [mcp, plain]) {
			const as = client(hq, key);
			const refused = { status: 403, body: { error: 'admin_only' } };
			expect(await as('POST', '/v1/keys', { person_name: 'Eve' })).toEqual(refused);
			expect(await as('POST', `/v1/people/${b.person.id}/role`, { is_admin: true })).toEqual(refused);
			expect(await as('POST', `/v1/people/${b.person.id}/remove`)).toEqual(refused);
			expect(await as('POST', `/v1/people/${b.person.id}/restore`)).toEqual(refused);
			expect(await as('POST', '/v1/people', { name: 'Eve', handle: 'eve' })).toEqual(refused);
			// Everything a member does still works with them.
			expect((await as('GET', '/v1/me')).body.person.id).toBe(ada.person.id);
			expect((await as('GET', '/v1/conversations')).status).toBe(200);
		}
		expect(hq.hub.people.list()).toHaveLength(people);
		expect(hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM api_keys').get()!.n).toBe(keys);
		expect(hq.hub.people.get(b.person.id)).toMatchObject({ role: 'member', removed_at: null });
		const rpc = await hq.fetch(
			new Request('http://hq.test/mcp', {
				method: 'POST',
				headers: { 'content-type': 'application/json', authorization: `Bearer ${mcp}` },
				body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }),
			}),
		);
		expect(rpc?.status).toBe(200);
		// The same admin on a signed-in device can.
		expect((await a.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: true })).status).toBe(200);
	});
});

/** A request body that arrives after a pause, so another request can run while the server waits for it. */
const slowly = (text: string, ms = 60) =>
	new ReadableStream<Uint8Array>({
		async start(controller) {
			await Bun.sleep(ms);
			controller.enqueue(new TextEncoder().encode(text));
			controller.close();
		},
	});

const asSlowly = (hq: Hq, bearer: string, path: string, text: string) =>
	hq
		.fetch(
			new Request(`http://hq.test${path}`, {
				method: 'POST',
				headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
				body: slowly(text),
				duplex: 'half',
			} as RequestInit),
		)
		.then(async (r) => ({ status: r!.status, body: await r!.json() }));

const activeAdmins = (hq: Hq) => hq.hub.people.list().filter((p) => p.role === 'admin' && p.removed_at === null);

describe('the last admin', () => {
	test('two admins demoting each other at once leave one, not none', async () => {
		const { hq, a, b, ada } = await pair();
		await a.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: true });
		const [first, second] = await Promise.all([
			asSlowly(hq, a.bearer, `/v1/people/${b.person.id}/role`, '{"is_admin":false}'),
			asSlowly(hq, b.bearer, `/v1/people/${ada.person.id}/role`, '{"is_admin":false}'),
		]);
		expect([first.status, second.status].sort()).toEqual([200, 403]);
		expect([first.body, second.body]).toContainEqual({ error: 'admin_only' });
		expect(activeAdmins(hq)).toHaveLength(1);
	});

	test('an admin demoted or removed while their request is on its way cannot finish it', async () => {
		const { hq, a, b } = await pair();
		await a.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: true });
		const late = asSlowly(hq, b.bearer, '/v1/keys', '{"person_name":"Eve"}');
		await Bun.sleep(10);
		await a.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: false });
		expect(await late).toEqual({ status: 403, body: { error: 'admin_only' } });
		expect(hq.hub.people.list().some((p) => p.name === 'Eve')).toBe(false);
	});

	test('a change that would leave no active admin is last_admin, whoever asks', async () => {
		const { hq, a, ada } = await pair();
		// A service account can be an admin; only people who sign in count toward having one.
		const robot = hq.hub.people.create({ name: 'Robot', handle: 'robot', kind: 'service', role: 'admin' });
		const robotAs = client(hq, hq.hub.devices.enroll(robot.id, 'robot').bearer);
		expect(await robotAs('POST', `/v1/people/${ada.person.id}/role`, { is_admin: false })).toEqual({
			status: 409,
			body: { error: 'last_admin' },
		});
		expect(await robotAs('POST', `/v1/people/${ada.person.id}/remove`)).toEqual({ status: 409, body: { error: 'last_admin' } });
		expect(hq.hub.people.get(ada.person.id)).toMatchObject({ role: 'admin', removed_at: null });
		expect((await a.as('GET', '/v1/me')).status).toBe(200);
	});

	test('removing an admin makes them a member: restored, they must be promoted again', async () => {
		const { hq, a, b } = await pair();
		await a.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: true });
		const removed = await a.as('POST', `/v1/people/${b.person.id}/remove`);
		expect(removed.body.person).toMatchObject({ is_admin: false });
		const restored = await a.as('POST', `/v1/people/${b.person.id}/restore`);
		expect(restored.body.person).toMatchObject({ is_admin: false, removed_at: null });
		expect(hq.hub.people.get(b.person.id)!.role).toBe('member');
		const back = await client(hq)('POST', '/v1/enroll', { key: hq.hub.keys.mint(b.person.id, 'setup').secret });
		expect((await client(hq, back.body.bearer)('POST', '/v1/keys', { person_name: 'Eve' })).body).toEqual({
			error: 'admin_only',
		});
	});
});

describe('roles, removing and restoring', () => {
	test('POST /v1/people/:id/role promotes and demotes, tells everyone, and never touches your own seat', async () => {
		const { hq, a, b, ada } = await pair();
		const server = serve(hq);
		const watcher = await connect(server, b.bearer);
		const promoted = await a.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: true });
		expect(promoted.status).toBe(200);
		expect(promoted.body.person).toMatchObject({ id: b.person.id, is_admin: true });
		expect((await watcher.take('person_updated', (f) => f.person.id === b.person.id)).person.is_admin).toBe(true);
		expect((await b.as('POST', '/v1/keys', { person_name: 'Gus' })).status).toBe(201);
		expect((await b.as('POST', `/v1/people/${ada.person.id}/role`, { is_admin: false })).body.person.is_admin).toBe(false);
		expect((await a.as('POST', `/v1/people/${ada.person.id}/role`, { is_admin: false })).status).toBe(403);
		expect((await b.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: false })).body).toEqual({ error: 'not_yourself' });
		expect((await b.as('POST', `/v1/people/${b.person.id}/role`, {})).body).toEqual({ error: 'invalid_body' });
		expect((await b.as('POST', '/v1/people/nobody/role', { is_admin: true })).body).toEqual({ error: 'person_not_found' });
		watcher.ws.close();
		void server.stop(true);
	});

	test('remove freezes: the row and its history stay, every device and key stops, sockets close, restore unfreezes', async () => {
		const { hq, a, b, room } = await pair();
		const server = serve(hq);
		const live = await connect(server, b.bearer);
		await b.as('POST', `/v1/conversations/${room.id}/messages`, { client_msg_id: crypto.randomUUID(), content: 'before' });
		const before = hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM people').get()!.n;
		const removed = await a.as('POST', `/v1/people/${b.person.id}/remove`);
		expect(removed.status).toBe(200);
		expect(removed.body.person.removed_at).toMatch(/^\d{4}-\d\d-\d\dT.*Z$/);
		expect(await live.closed).toBe(4001);
		expect((await b.as('GET', '/v1/me')).status).toBe(401);
		expect(hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM people').get()!.n).toBe(before);
		const roster = (await a.as('GET', '/v1/people')).body.people;
		expect(roster.find((p: { id: string }) => p.id === b.person.id).removed_at).not.toBeNull();
		const history = (await a.as('GET', `/v1/conversations/${room.id}/messages`)).body.messages;
		expect(history.map((m: { content: string }) => m.content)).toContain('before');
		expect(await a.as('POST', `/v1/people/${b.person.id}/remove`)).toEqual({ status: 409, body: { error: 'already_removed' } });
		expect((await a.as('POST', `/v1/people/${b.person.id}/role`, { is_admin: true })).body).toEqual({ error: 'person_removed' });
		expect((await a.as('POST', '/v1/conversations', { kind: 'dm', person_id: b.person.id })).body).toEqual({
			error: 'person_not_found',
		});

		// Access does not come back by itself: a fresh key is needed.
		const restored = await a.as('POST', `/v1/people/${b.person.id}/restore`);
		expect(restored.body.person).toMatchObject({ id: b.person.id, removed_at: null });
		expect((await b.as('GET', '/v1/me')).status).toBe(401);
		expect(await a.as('POST', `/v1/people/${b.person.id}/restore`)).toEqual({ status: 409, body: { error: 'not_removed' } });
		// The app cannot mint it for an existing person (person_exists); the operator's `bun hq invite bo` does.
		expect((await a.as('POST', '/v1/keys', { person_name: 'Bo' })).body).toEqual({
			error: 'person_exists',
		});
		expect((await client(hq)('POST', '/v1/enroll', { key: hq.hub.keys.mint(b.person.id, 'invite').secret })).status).toBe(201);
		void server.stop(true);
	});

	test('you cannot remove yourself, the assistant or an unknown id; a removed person cannot be handed a key', async () => {
		const { hq, a, b, ada } = await pair();
		expect((await a.as('POST', `/v1/people/${ada.person.id}/remove`)).body).toEqual({ error: 'not_yourself' });
		expect((await a.as('POST', `/v1/people/${hq.assistant.self.id}/remove`)).body).toEqual({ error: 'person_not_found' });
		expect((await a.as('POST', '/v1/people/nobody/remove')).body).toEqual({ error: 'person_not_found' });
		await a.as('POST', `/v1/people/${b.person.id}/remove`);
		// Restoring comes first; a key for a frozen name is refused, and a key made before the removal is dead.
		const asked = await a.as('POST', '/v1/keys', { person_name: 'Bo' });
		expect(asked).toEqual({ status: 409, body: { error: 'person_removed' } });
		const stale = hq.hub.keys.mint(b.person.id, 'invite').secret;
		expect((await client(hq)('POST', '/v1/enroll', { key: stale })).status).toBe(401);
	});
});

describe('the MCP keys card', () => {
	test('create, list and revoke with the shapes the app decodes', async () => {
		const { hq, a, b } = await pair();
		const made = await a.as('POST', '/v1/mcp-keys', { label: 'Claude Code', scopes: ['read', 'send'] });
		expect(made.status).toBe(201);
		expectShape('MintedMcpKey', made.body);
		expect(made.body.label).toBe('Claude Code');
		// It is a working bearer, here on MCP.
		const mcp = await hq.fetch(
			new Request('http://hq.test/mcp', {
				method: 'POST',
				headers: { 'content-type': 'application/json', authorization: `Bearer ${made.body.key}` },
				body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
			}),
		);
		expect(mcp?.status).toBe(200);

		const listed = await a.as('GET', '/v1/mcp-keys');
		expect(listed.body.keys).toHaveLength(1);
		expectShape('McpKeySummary', listed.body.keys[0]);
		expect(listed.body.keys[0]).toMatchObject({ id: made.body.id, label: 'Claude Code', scopes: 'read,send', revoked_at: null });
		expect(Number.isInteger(listed.body.keys[0].created_at)).toBe(true);
		// Devices are not MCP keys, and nobody sees another person's.
		expect((await b.as('GET', '/v1/mcp-keys')).body).toEqual({ keys: [] });
		expect((await b.as('DELETE', `/v1/mcp-keys/${made.body.id}`)).status).toBe(404);

		expect(await a.as('DELETE', `/v1/mcp-keys/${made.body.id}`)).toEqual({ status: 200, body: { ok: true } });
		expect((await client(hq, made.body.key)('GET', '/v1/me')).status).toBe(401);
		const after = (await a.as('GET', '/v1/mcp-keys')).body.keys[0];
		expect(after.revoked_at).not.toBeNull();
		expect((await a.as('DELETE', `/v1/mcp-keys/${made.body.id}`)).status).toBe(404);
	});

	test('an admin may revoke anyone’s key; bad bodies and scopes this server cannot enforce are refused', async () => {
		const { a, b } = await pair();
		const theirs = await b.as('POST', '/v1/mcp-keys', { label: 'Bo’s', scopes: ['read', 'send'] });
		expect((await a.as('DELETE', `/v1/mcp-keys/${theirs.body.id}`)).status).toBe(200);
		expect((await a.as('POST', '/v1/mcp-keys', { scopes: ['read', 'send'] })).body).toEqual({ error: 'invalid_body' });
		for (const scopes of [['read'], ['admin', 'read', 'send'], []]) {
			expect(await a.as('POST', '/v1/mcp-keys', { label: 'x', scopes })).toEqual({
				status: 400,
				body: { error: scopes.length === 0 ? 'invalid_body' : 'scope_unsupported' },
			});
		}
	});

	test('a label cannot make an MCP key into something else: it never enrolls and is not a sign-in key', async () => {
		const { hq, a } = await pair();
		for (const label of ['setup', 'invite', 'device']) {
			const made = await a.as('POST', '/v1/mcp-keys', { label, scopes: ['read', 'send'] });
			expect((await client(hq)('POST', '/v1/enroll', { key: made.body.key })).status).toBe(401);
			expect((await client(hq, made.body.key)('GET', '/v1/me')).status).toBe(200);
		}
		expect((await a.as('GET', '/v1/mcp-keys')).body.keys).toHaveLength(3);
	});
});
