import { describe, expect, test } from 'bun:test';
import type { Server } from 'bun';
import { createHq } from '../src/hq';
import { admin, client, enrolled } from './helpers';

const from = (address: string) => ({ requestIP: () => ({ address }) }) as unknown as Server<never>;

async function enrollFrom(
	hq: ReturnType<typeof createHq>,
	address: string,
	body: unknown = { key: 'hq_wrong', device_name: 'Mac' },
) {
	const response = await hq.fetch(
		new Request('http://hq.test/v1/enroll', { method: 'POST', body: JSON.stringify(body) }),
		from(address) as never,
	);
	return response!;
}

describe('enroll', () => {
	test('a key becomes a device with its own bearer', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const key = hq.hub.keys.mint(ada.person.id, 'setup').secret;
		const response = await client(hq)('POST', '/v1/enroll', { key, device_name: 'Ada MacBook', person_name: 'Ada L' });
		expect(response.status).toBe(201);
		expect(Object.keys(response.body).sort()).toEqual(['bearer', 'device_id', 'person', 'wire_version']);
		expect(response.body.wire_version).toBe(1);
		expect(response.body.person).toEqual({
			id: ada.person.id,
			name: 'Ada',
			kind: 'person',
			is_admin: true,
			avatar_id: null,
			removed_at: null,
		});
		expect(response.body.bearer).toMatch(/^hq_/);
		expect(response.body.bearer).not.toBe(key);
		expect((await client(hq, response.body.bearer)('GET', '/v1/me')).body.person.id).toBe(ada.person.id);
	});

	test('every enroll adds a device; the bearer is stored only as a hash', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const phone = await enrolled(hq, ada.key, 'Phone');
		const laptop = await enrolled(hq, ada.key, 'Laptop');
		expect(phone.bearer).not.toBe(laptop.bearer);
		expect(phone.deviceId).not.toBe(laptop.deviceId);
		expect(hq.hub.devices.get(phone.deviceId)).toMatchObject({ person_id: ada.person.id, name: 'Phone' });
		const hashes = hq.hub.db
			.query<{ hash: string }, []>('SELECT hash FROM api_keys')
			.all()
			.map((row) => row.hash);
		expect(hashes).not.toContain(phone.bearer);
		expect(hashes).toContain(new Bun.CryptoHasher('sha256').update(phone.bearer).digest('hex'));
		expect(
			hq.hub.db
				.query<{ name: string }, []>('SELECT name FROM devices ORDER BY created_at, rowid')
				.all()
				.map((d) => d.name),
		).toEqual(['Phone', 'Laptop']);
	});

	test('a key that is not one gets invalid_key; a server with nobody on it gets not_configured', async () => {
		const empty = createHq();
		expect(await client(empty)('POST', '/v1/enroll', { key: 'hq_nope' })).toEqual({
			status: 503,
			body: { error: 'not_configured' },
		});
		const hq = createHq();
		admin(hq);
		for (const key of ['hq_nope', 'plain', admin(createHq()).key]) {
			expect(await client(hq)('POST', '/v1/enroll', { key })).toEqual({ status: 401, body: { error: 'invalid_key' } });
		}
	});

	test('a malformed body is invalid_body', async () => {
		const hq = createHq();
		const as = client(hq);
		for (const body of [
			{},
			{ key: '' },
			{ key: 'hq_x', device_name: '' },
			{ key: 'hq_x', person_name: 'x'.repeat(81) },
			'nope',
		]) {
			expect(await as('POST', '/v1/enroll', body)).toEqual({ status: 400, body: { error: 'invalid_body' } });
		}
		expect((await as('GET', '/v1/enroll')).status).toBe(405);
	});

	test('a revoked key cannot enroll', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const spare = hq.hub.keys.mint(ada.person.id, 'key', { label: 'spare' });
		hq.hub.keys.revoke(spare.key.id);
		expect((await client(hq)('POST', '/v1/enroll', { key: spare.secret })).body).toEqual({ error: 'invalid_key' });
	});
});

describe('revoking a device', () => {
	test('its bearer is refused everywhere; the same person on another device carries on', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const phone = await enrolled(hq, ada.key, 'Phone');
		const laptop = await enrolled(hq, ada.key, 'Laptop');
		expect(await laptop.as('POST', `/v1/devices/${phone.deviceId}/revoke`)).toEqual({ status: 200, body: { ok: true } });
		for (const route of ['/v1/me', '/v1/people', '/v1/conversations']) {
			expect(await phone.as('GET', route)).toEqual({ status: 401, body: { error: 'unauthorized' } });
		}
		const mcp = await hq.fetch(
			new Request('http://hq.test/mcp', { method: 'POST', headers: { authorization: `Bearer ${phone.bearer}` }, body: '{}' }),
		);
		expect(mcp?.status).toBe(401);
		expect((await laptop.as('GET', '/v1/me')).status).toBe(200);
		expect((await laptop.as('POST', `/v1/devices/${phone.deviceId}/revoke`)).status).toBe(404);
	});

	test('a member revokes their own devices; an admin revokes anyone’s; nobody else’s', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const adaMac = await enrolled(hq, ada.key);
		const boMac = await enrolled(hq, hq.hub.keys.mint(bo.id).secret);
		const boPhone = await enrolled(hq, hq.hub.keys.mint(bo.id).secret);
		const cyMac = await enrolled(hq, hq.hub.keys.mint(cy.id).secret);
		expect((await cyMac.as('POST', `/v1/devices/${boMac.deviceId}/revoke`)).status).toBe(404);
		expect((await boMac.as('GET', '/v1/me')).status).toBe(200);
		expect((await boMac.as('POST', `/v1/devices/${boPhone.deviceId}/revoke`)).status).toBe(200);
		expect((await adaMac.as('POST', `/v1/devices/${boMac.deviceId}/revoke`)).status).toBe(200);
		expect((await boMac.as('GET', '/v1/me')).status).toBe(401);
		expect((await client(hq)('POST', `/v1/devices/${cyMac.deviceId}/revoke`)).status).toBe(401);
	});
});

describe('enroll rate limit', () => {
	test('the 21st attempt in five minutes from one address is refused with when to retry', async () => {
		const hq = createHq();
		admin(hq);
		for (let i = 0; i < 20; i++) expect((await enrollFrom(hq, '203.0.113.9')).status).toBe(401);
		const refused = await enrollFrom(hq, '203.0.113.9');
		expect(refused.status).toBe(429);
		const body = await refused.json();
		expect(body.error).toBe('rate_limited');
		expect(body.retry_after).toBeGreaterThan(0);
		expect(body.retry_after).toBeLessThanOrEqual(300);
		expect(refused.headers.get('retry-after')).toBe(String(body.retry_after));
	});

	test('it never stops a correct key, and other addresses are untouched', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const key = hq.hub.keys.mint(ada.person.id, 'setup').secret;
		for (let i = 0; i < 20; i++) await enrollFrom(hq, '203.0.113.9');
		expect((await enrollFrom(hq, '203.0.113.9')).status).toBe(429);
		expect((await enrollFrom(hq, '203.0.113.9', { key })).status).toBe(201);
		expect((await enrollFrom(hq, '198.51.100.4', { key })).status).toBe(201);
	});

	test('behind a trusted proxy callers are told apart by the last forwarded address', async () => {
		const hq = createHq({ trustProxy: true });
		admin(hq);
		const via = (forwarded: string) =>
			hq.fetch(
				new Request('http://hq.test/v1/enroll', {
					method: 'POST',
					headers: { 'x-forwarded-for': forwarded },
					body: JSON.stringify({ key: 'hq_wrong' }),
				}),
				from('10.0.0.1') as never,
			);
		for (let i = 0; i < 20; i++) await via(`spoofed-${i}, 192.0.2.7`);
		expect((await via('anything, 192.0.2.7'))?.status).toBe(429);
		expect((await via('anything, 192.0.2.8'))?.status).toBe(401);
	});
});

describe('enroll rate limit, as a real server sees callers', () => {
	test('junk from one address never rate-limits another address’s typo', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const key = hq.hub.keys.mint(ada.person.id, 'setup').secret;
		// Dual-stack, so 127.0.0.1 and ::1 are two real callers.
		const server = Bun.serve({ port: 0, hostname: '::', fetch: hq.fetch, websocket: hq.websocket });
		try {
			const enroll = (host: string, body: unknown) =>
				fetch(`http://${host}:${server.port}/v1/enroll`, { method: 'POST', body: JSON.stringify(body) });
			for (let i = 0; i < 20; i++) expect((await enroll('127.0.0.1', { key: 'hq_junk' })).status).toBe(401);
			expect((await enroll('127.0.0.1', { key: 'hq_junk' })).status).toBe(429);
			expect((await enroll('[::1]', { key: 'hq_typo' })).status).toBe(401);
			expect((await enroll('127.0.0.1', { key })).status).toBe(201);
		} finally {
			void server.stop(true);
		}
	});

	test('IPv6 callers are counted by their /64, and an IPv4-mapped address is the IPv4 one', async () => {
		const hq = createHq();
		admin(hq);
		for (let i = 0; i < 20; i++) expect((await enrollFrom(hq, `2001:db8:1:2:${i}::${i + 1}`)).status).toBe(401);
		expect((await enrollFrom(hq, '2001:db8:1:2:ffff::9')).status).toBe(429);
		expect((await enrollFrom(hq, '2001:DB8:1:2::')).status).toBe(429);
		expect((await enrollFrom(hq, '2001:db8:1:3::1')).status).toBe(401);
		for (let i = 0; i < 20; i++) await enrollFrom(hq, '192.0.2.50');
		expect((await enrollFrom(hq, '::ffff:192.0.2.50')).status).toBe(429);
	});

	test('wrong keys also share a budget across every address, which never stops a correct key', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const key = hq.hub.keys.mint(ada.person.id, 'setup').secret;
		// Ten addresses at their own limit of 20 use up the 200 wrong keys the whole server allows.
		for (let a = 0; a < 10; a++) {
			for (let i = 0; i < 20; i++) expect((await enrollFrom(hq, `203.0.113.${a}`)).status).toBe(401);
		}
		const refused = await enrollFrom(hq, '198.51.100.77');
		expect(refused.status).toBe(429);
		expect((await refused.json()).error).toBe('rate_limited');
		expect((await enrollFrom(hq, '198.51.100.77', { key })).status).toBe(201);
		expect((await enrollFrom(hq, '203.0.113.3', { key })).status).toBe(201);
	});
});
