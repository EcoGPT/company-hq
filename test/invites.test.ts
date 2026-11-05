import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Server } from 'bun';
import { boot } from '../src/boot';
import { createHq, type Hq } from '../src/hq';
import type { SocketData } from '../src/realtime/socket';
import { admin, client, enrolled } from './helpers';

const DAY = 86_400_000;
const EXPIRED = 'invite_expired';

let server: Server<SocketData> | undefined;
afterEach(() => server?.stop(true));

async function invite(hq: Hq, handle = 'bo') {
	const ada = hq.hub.people.byHandle('ada') ?? admin(hq).person;
	const { body } = await (await enrolled(hq, hq.hub.keys.mint(ada.id).secret)).as('POST', '/v1/people', { name: handle, handle });
	return { key: body.key as string, person: body.person as { id: string } };
}

const age = (hq: Hq, personId: string, days: number) =>
	hq.hub.db.query('UPDATE api_keys SET created_at = created_at - $by WHERE person_id = $p').run({ by: days * DAY, p: personId });

const enroll = (hq: Hq, key: string, device_name = 'Phone') => client(hq)('POST', '/v1/enroll', { key, device_name });

describe('who can enroll', () => {
	test('an invite or a sign-in (setup) key can; a device bearer, a labelled key and an MCP key cannot', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const device = await enrolled(hq, ada.key);
		const labelled = ['default', 'cli', 'laptop'].map((label) => hq.hub.keys.mint(ada.person.id, 'key', { label }).secret);
		const mcp = hq.hub.keys.mint(ada.person.id, 'mcp', { label: 'invite' }).secret;
		for (const key of [device.bearer, ada.key, ...labelled, mcp]) {
			expect(await enroll(hq, key)).toEqual({ status: 401, body: { error: 'invalid_key' } });
		}
		for (const kind of ['setup', 'invite'] as const) {
			expect((await enroll(hq, hq.hub.keys.mint(ada.person.id, kind).secret)).status).toBe(201);
		}
	});

	test('a stolen device bearer cannot add a device that outlives its revocation', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const victim = await enrolled(hq, ada.key, 'victim phone');
		expect((await enroll(hq, victim.bearer, 'attacker')).status).toBe(401);
		expect((await victim.as('POST', `/v1/devices/${victim.deviceId}/revoke`)).status).toBe(200);
		expect((await victim.as('GET', '/v1/me')).status).toBe(401);
	});
});

describe('invite keys', () => {
	test('an invite adds as many devices as the person likes until it is 7 days old, used or not', async () => {
		const hq = createHq();
		const bo = await invite(hq);
		for (let i = 0; i < 5; i++) expect((await enroll(hq, bo.key, `d${i}`)).status).toBe(201);
		age(hq, bo.person.id, 6.9);
		expect((await enroll(hq, bo.key, 'late')).status).toBe(201);
		age(hq, bo.person.id, 0.2);
		expect(await enroll(hq, bo.key)).toEqual({ status: 401, body: { error: EXPIRED } });
	});

	test('a device it made outlives it', async () => {
		const hq = createHq();
		const bo = await invite(hq);
		const made = await enroll(hq, bo.key);
		age(hq, bo.person.id, 400);
		expect(await enroll(hq, bo.key)).toEqual({ status: 401, body: { error: EXPIRED } });
		expect((await client(hq, made.body.bearer)('GET', '/v1/me')).status).toBe(200);
	});

	test('an invite or a setup key only enrolls: it is no bearer on the routes, MCP or the socket', async () => {
		const hq = createHq();
		const bo = await invite(hq);
		server = Bun.serve({ port: 0, fetch: hq.fetch, websocket: hq.websocket });
		for (const key of [bo.key, hq.hub.keys.mint(bo.person.id, 'setup').secret]) {
			expect(await client(hq, key)('GET', '/v1/me')).toEqual({ status: 401, body: { error: 'unauthorized' } });
			const mcp = (await hq.fetch(
				new Request('http://hq.test/mcp', {
					method: 'POST',
					headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
					body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
				}),
			)) as Response;
			expect(mcp.status).toBe(401);
			const stream = await fetch(`http://localhost:${server.port}/v1/ws`, {
				headers: {
					authorization: `Bearer ${key}`,
					upgrade: 'websocket',
					connection: 'upgrade',
					'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
					'sec-websocket-version': '13',
				},
			});
			expect(stream.status).toBe(401);
			expect((await enroll(hq, key)).status).toBe(201);
		}
	});

	test('an expired invite is replaced by the operator’s `bun hq invite`, not by the app', async () => {
		const hq = createHq();
		const bo = await invite(hq);
		age(hq, bo.person.id, 8);
		expect((await enroll(hq, bo.key)).body).toEqual({ error: EXPIRED });
		const ada = await enrolled(hq, hq.hub.keys.mint(hq.hub.people.byHandle('ada')!.id).secret);
		expect(await ada.as('POST', '/v1/keys', { person_name: 'bo' })).toEqual({
			status: 409,
			body: { error: 'person_exists' },
		});
		// What `bun hq invite bo` does.
		hq.hub.keys.revokeSignIn(bo.person.id);
		const again = hq.hub.keys.mint(bo.person.id, 'invite').secret;
		expect((await enroll(hq, again)).status).toBe(201);
	});

	test('setup and other labels never expire', async () => {
		const hq = createHq();
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const setup = hq.hub.keys.mint(cy.id, 'setup').secret;
		const keys = ['cli', 'default', 'laptop'].map((label) => hq.hub.keys.mint(cy.id, 'key', { label }).secret);
		age(hq, cy.id, 400);
		expect((await enroll(hq, setup)).status).toBe(201);
		for (const key of keys) expect((await client(hq, key)('GET', '/v1/me')).status).toBe(200);
	});

	test('HQ_INVITE_TTL_DAYS sets the window', async () => {
		const short = createHq({ inviteTtlDays: 1 });
		const bo = await invite(short);
		age(short, bo.person.id, 1.5);
		expect((await enroll(short, bo.key)).status).toBe(401);

		for (const days of [0, -1]) {
			const off = createHq({ inviteTtlDays: days });
			const cy = await invite(off, 'cy');
			age(off, cy.person.id, 400);
			expect((await enroll(off, cy.key)).status).toBe(201);
		}

		const dir = mkdtempSync(join(tmpdir(), 'hq-invite-'));
		try {
			const env = { HQ_DB: join(dir, 'hq.sqlite'), HQ_VAULT_KEY: 'test' };
			expect(boot(env).hq.hub.keys.inviteTtlDays).toBe(7);
			expect(boot({ ...env, HQ_INVITE_TTL_DAYS: '30' }).hq.hub.keys.inviteTtlDays).toBe(30);
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
});
