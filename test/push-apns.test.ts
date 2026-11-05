import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import http2 from 'node:http2';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ApnsProvider, type ApnsOptions } from '../src/push/apns';
import type { PushMessage, PushTarget } from '../src/push/provider';
import type { client } from '../src/testing';
import { pair, say } from './helpers';

// The Apple adapter against a server this test starts itself, speaking HTTP/2 on 127.0.0.1. Nothing here contacts Apple:
// the adapter is pointed at the local origin, and the key pair is made fresh for every run.

type Seen = { path: string; headers: http2.IncomingHttpHeaders; body: any };
type Reply = { status: number; reason?: string; delayMs?: number } | 'hang';

const until = async (check: () => boolean, what: string) => {
	const end = Date.now() + 5000;
	while (!check()) {
		if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
		await Bun.sleep(5);
	}
};

async function makeKey() {
	const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
	const der = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64');
	const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g)!.join('\n')}\n-----END PRIVATE KEY-----\n`;
	return { pem, publicKey: pair.publicKey };
}

const decode = (part: string) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));

/** Whether a provider token is what Apple expects of one: ES256, our key id and team, signed by our key. */
async function validJwt(authorization: string | undefined, publicKey: CryptoKey) {
	const [scheme, jwt] = (authorization ?? '').split(' ');
	const [header, claims, signature] = (jwt ?? '').split('.');
	if (scheme !== 'bearer' || !header || !claims || !signature) return false;
	const signed = await crypto.subtle.verify(
		{ name: 'ECDSA', hash: 'SHA-256' },
		publicKey,
		Buffer.from(signature, 'base64url'),
		new TextEncoder().encode(`${header}.${claims}`),
	);
	return signed && decode(header).alg === 'ES256' && decode(header).kid === 'KEY1234567' && decode(claims).iss === 'TEAM123456';
}

const servers: { close(): void }[] = [];
afterEach(() => {
	for (const server of servers.splice(0)) server.close();
});

/** A stand-in for Apple's endpoint. `reply` decides each answer from the request and its number. */
async function fakeApns(reply: (seen: Seen, n: number) => Reply = () => ({ status: 200 }), tls?: { key: string; cert: string }) {
	const seen: Seen[] = [];
	const sessions = new Set<http2.ServerHttp2Session>();
	const server = tls ? http2.createSecureServer(tls) : http2.createServer();
	let connections = 0;
	server.on('session', (session) => {
		connections += 1;
		sessions.add(session);
		session.on('close', () => sessions.delete(session));
	});
	server.on('stream', (stream: http2.ServerHttp2Stream, headers: http2.IncomingHttpHeaders) => {
		const chunks: Buffer[] = [];
		stream.on('data', (chunk: Buffer) => chunks.push(chunk));
		stream.on('end', () => {
			const record: Seen = { path: String(headers[':path']), headers, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) };
			seen.push(record);
			const answer = reply(record, seen.length);
			if (answer === 'hang') return;
			setTimeout(() => {
				if (stream.destroyed || stream.closed) return;
				stream.respond({ ':status': answer.status, 'content-type': 'application/json' });
				stream.end(answer.reason === undefined ? '' : JSON.stringify({ reason: answer.reason }));
			}, answer.delayMs ?? 0);
		});
	});
	await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
	const { port } = server.address() as { port: number };
	const handle = {
		url: `${tls ? 'https' : 'http'}://127.0.0.1:${port}`,
		seen,
		connections: () => connections,
		dropConnections: () => sessions.forEach((session) => session.destroy()),
		goaway: () => sessions.forEach((session) => session.goaway()),
		close: () => {
			for (const session of sessions) session.destroy();
			server.close();
		},
	};
	servers.push(handle);
	return handle;
}

const TARGET: PushTarget = { token: 'ab'.repeat(32), environment: 'production' };
const ALERT: PushMessage = {
	type: 'message',
	title: 'Launch',
	body: 'Ada: Lunch at noon?',
	conversationId: 'c-1',
	messageId: 'm-1',
};
const READ: PushMessage = { type: 'read', conversationId: 'c-1', readThroughMessageId: 'm-9' };

async function provider(baseUrl: ApnsOptions['baseUrl'], extra: Partial<ApnsOptions> = {}) {
	const { pem, publicKey } = await makeKey();
	const apns = new ApnsProvider({
		key: pem,
		keyId: 'KEY1234567',
		teamId: 'TEAM123456',
		topic: 'org.example.hq',
		baseUrl,
		...extra,
	});
	servers.push(apns);
	return { apns, publicKey, pem };
}

describe('the request Apple gets', () => {
	test('a message is an alert push to the device, with the keys the app reads at the top level', async () => {
		const apple = await fakeApns();
		const { apns, publicKey } = await provider(apple.url);
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'sent' });
		const [request] = apple.seen;
		expect(request!.path).toBe(`/3/device/${TARGET.token}`);
		expect(request!.headers[':method']).toBe('POST');
		expect(request!.headers['apns-push-type']).toBe('alert');
		expect(request!.headers['apns-topic']).toBe('org.example.hq');
		expect(request!.headers['apns-priority']).toBe('10');
		expect(request!.headers['apns-collapse-id']).toBe('m-1');
		expect(await validJwt(request!.headers.authorization, publicKey)).toBe(true);
		expect(request!.body).toEqual({
			aps: { alert: { title: 'Launch', body: 'Ada: Lunch at noon?' }, sound: 'default', 'thread-id': 'c-1' },
			conversation_id: 'c-1',
			message_id: 'm-1',
		});
		// `call_id` would make the app treat a message as a ring.
		expect(JSON.stringify(request!.body)).not.toContain('call_id');
	});

	test('a read is a silent background push that collapses per conversation', async () => {
		const apple = await fakeApns();
		const { apns } = await provider(apple.url);
		expect(await apns.send(TARGET, READ)).toEqual({ outcome: 'sent' });
		const [request] = apple.seen;
		expect(request!.headers['apns-push-type']).toBe('background');
		expect(request!.headers['apns-priority']).toBe('5');
		expect(request!.headers['apns-topic']).toBe('org.example.hq');
		expect(request!.headers['apns-collapse-id']).toBe('read:c-1');
		expect(request!.body).toEqual({
			aps: { 'content-available': 1 },
			conversation_id: 'c-1',
			read_through_message_id: 'm-9',
		});
	});

	test('a development token goes to the sandbox host and a production token to the production one', async () => {
		const sandbox = await fakeApns();
		const live = await fakeApns();
		const { apns } = await provider({ development: sandbox.url, production: live.url });
		await apns.send({ ...TARGET, environment: 'development' }, ALERT);
		await apns.send({ ...TARGET, environment: 'production' }, ALERT);
		expect([sandbox.seen.length, live.seen.length]).toEqual([1, 1]);
	});

	test('rides one connection for many pushes', async () => {
		const apple = await fakeApns();
		const { apns } = await provider(apple.url);
		await Promise.all([apns.send(TARGET, ALERT), apns.send(TARGET, READ), apns.send(TARGET, ALERT)]);
		await apns.send(TARGET, READ);
		expect(apple.seen.length).toBe(4);
		expect(apple.connections()).toBe(1);
	});

	test('connects again when the server dropped the connection between pushes', async () => {
		const apple = await fakeApns();
		const { apns } = await provider(apple.url);
		await apns.send(TARGET, ALERT);
		apple.dropConnections();
		await Bun.sleep(20);
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'sent' });
		expect(apple.seen.length).toBe(2);
	});
});

describe('the provider token', () => {
	test('is signed once and reused, then replaced after about 45 minutes', async () => {
		const apple = await fakeApns();
		let clock = Date.parse('2026-01-01T00:00:00Z');
		const { apns, publicKey } = await provider(apple.url, { clock: () => clock });
		await apns.send(TARGET, ALERT);
		clock += 44 * 60_000;
		await apns.send(TARGET, ALERT);
		clock += 2 * 60_000;
		await apns.send(TARGET, ALERT);
		const [first, second, third] = apple.seen.map((s) => s.headers.authorization);
		expect(second).toBe(first);
		expect(third).not.toBe(first);
		expect(await validJwt(third, publicKey)).toBe(true);
		const claims = decode(String(third).split('.')[1]!);
		expect(claims.iat).toBe(Math.floor(clock / 1000));
	});

	test('is minted once when many pushes start together', async () => {
		const apple = await fakeApns();
		const { apns } = await provider(apple.url);
		await Promise.all(Array.from({ length: 10 }, () => apns.send(TARGET, ALERT)));
		expect(new Set(apple.seen.map((s) => s.headers.authorization)).size).toBe(1);
	});

	test.each(['ExpiredProviderToken', 'InvalidProviderToken'])('is replaced and the push retried once on %s', async (reason) => {
		const apple = await fakeApns((_, n) => (n === 1 ? { status: 403, reason } : { status: 200 }));
		const { apns, publicKey } = await provider(apple.url);
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'sent' });
		expect(apple.seen.length).toBe(2);
		const [first, second] = apple.seen.map((s) => s.headers.authorization);
		expect(second).not.toBe(first);
		expect(await validJwt(second, publicKey)).toBe(true);
		// The replacement is the one kept.
		await apns.send(TARGET, ALERT);
		expect(apple.seen[2]!.headers.authorization).toBe(second);
	});

	test('is retried only once: a second refusal is a configuration problem', async () => {
		const apple = await fakeApns(() => ({ status: 403, reason: 'ExpiredProviderToken' }));
		const { apns } = await provider(apple.url);
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'config', reason: 'ExpiredProviderToken' });
		expect(apple.seen.length).toBe(2);
	});

	test('a key that cannot sign is a configuration problem and nothing is sent', async () => {
		const apple = await fakeApns();
		const { apns } = await provider(apple.url, { key: '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----' });
		expect((await apns.send(TARGET, ALERT)).outcome).toBe('config');
		expect(apple.seen.length).toBe(0);
	});
});

describe('what each answer means', () => {
	test.each([
		[200, undefined, 'sent'],
		[410, 'Unregistered', 'invalid_token'],
		// An environment or topic mismatch is ours to fix and says nothing about the device.
		[400, 'BadDeviceToken', 'config'],
		[400, 'DeviceTokenNotForTopic', 'config'],
		[403, 'DeviceTokenNotForTopic', 'config'],
		[403, 'BadCertificate', 'config'],
		[429, 'TooManyRequests', 'transient'],
		[500, 'InternalServerError', 'transient'],
		[503, 'ServiceUnavailable', 'transient'],
		[400, 'PayloadEmpty', 'fatal'],
		[410, 'ExpiredToken', 'fatal'],
		[404, undefined, 'fatal'],
	] as const)('%d %s is %s', async (status, reason, outcome) => {
		const apple = await fakeApns(() => ({ status, reason }));
		const { apns } = await provider(apple.url);
		expect((await apns.send(TARGET, ALERT)).outcome).toBe(outcome);
	});

	test('a connection that cannot be made is transient', async () => {
		const apple = await fakeApns();
		const { url } = apple;
		apple.close();
		const { apns } = await provider(url);
		const result = await apns.send(TARGET, ALERT);
		expect(result.outcome).toBe('transient');
	});

	test('an answer that never comes is transient after the timeout', async () => {
		const apple = await fakeApns(() => 'hang');
		const { apns } = await provider(apple.url, { requestTimeoutMs: 50 });
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'transient', reason: 'network ETIMEDOUT' });
	});
});

describe('the connection', () => {
	test('is dropped after a timeout, so one silent connection does not time out every push after it', async () => {
		const apple = await fakeApns((_, n) => (n === 1 ? 'hang' : { status: 200 }));
		const { apns } = await provider(apple.url, { requestTimeoutMs: 50 });
		expect((await apns.send(TARGET, ALERT)).outcome).toBe('transient');
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'sent' });
		expect(apple.connections()).toBe(2);
	});

	test('is replaced after the server says goaway, even while a push is still in flight on it', async () => {
		// With a push open the connection is not closed by the goaway, so only the handler keeps new pushes off it.
		const apple = await fakeApns((_, n) => (n === 1 ? { status: 200, delayMs: 400 } : { status: 200 }));
		const { apns } = await provider(apple.url);
		const first = apns.send(TARGET, ALERT);
		await until(() => apple.seen.length === 1, 'the first push');
		apple.goaway();
		await Bun.sleep(30);
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'sent' });
		expect(apple.connections()).toBe(2);
		// What was in flight when the goaway came still finishes.
		expect(await first).toEqual({ outcome: 'sent' });
	});

	test('a timeout loses only the push that timed out: others on the connection finish', async () => {
		const apple = await fakeApns((_, n) => (n === 1 ? 'hang' : { status: 200, delayMs: 100 }));
		const { apns } = await provider(apple.url, { requestTimeoutMs: 150 });
		const hung = apns.send(TARGET, ALERT);
		await until(() => apple.seen.length === 1, 'the hung push');
		await Bun.sleep(80);
		const others = [apns.send(TARGET, ALERT), apns.send(TARGET, READ), apns.send(TARGET, ALERT)];
		expect((await hung).outcome).toBe('transient');
		expect(await Promise.all(others)).toEqual([{ outcome: 'sent' }, { outcome: 'sent' }, { outcome: 'sent' }]);
		expect(apple.connections()).toBe(1);
		// The connection that timed out is not used again.
		expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'sent' });
		expect(apple.connections()).toBe(2);
	});

	test('once closed, a push that is still being made opens no new connection', async () => {
		const apple = await fakeApns();
		const { apns } = await provider(apple.url);
		await apns.send(TARGET, ALERT);
		apns.close();
		expect((await apns.send(TARGET, ALERT)).outcome).toBe('transient');
		expect([apple.seen.length, apple.connections()]).toEqual([1, 1]);
	});
});

describe('a provider token that is always refused (a wrong key id or team id)', () => {
	test('is not made again for every push: once per twenty minutes', async () => {
		const apple = await fakeApns(() => ({ status: 403, reason: 'InvalidProviderToken' }));
		let clock = Date.parse('2026-01-01T00:00:00Z');
		const { apns } = await provider(apple.url, { clock: () => clock });
		const tokensUsed = () => new Set(apple.seen.map((s) => s.headers.authorization)).size;
		for (let i = 0; i < 4; i++)
			expect(await apns.send(TARGET, ALERT)).toEqual({ outcome: 'config', reason: 'InvalidProviderToken' });
		// The first push tried twice (the retry), the other three once each, all with the retried token.
		expect([apple.seen.length, tokensUsed()]).toEqual([5, 2]);
		clock += 19 * 60_000;
		await apns.send(TARGET, ALERT);
		expect([apple.seen.length, tokensUsed()]).toEqual([6, 2]);
		clock += 2 * 60_000;
		await apns.send(TARGET, ALERT);
		expect([apple.seen.length, tokensUsed()]).toEqual([8, 3]);
	});
});

describe('over TLS', () => {
	// What Apple speaks. A throwaway certificate is made with openssl for this run; the test is skipped where there is none.
	const openssl = Bun.which('openssl');
	test.skipIf(openssl === null)(
		'the adapter connects with HTTP/2 over TLS and trusts only the certificate it was given',
		async () => {
			const dir = mkdtempSync(join(tmpdir(), 'hq-push-tls-'));
			try {
				const run = Bun.spawnSync([
					openssl!,
					'req',
					'-x509',
					'-newkey',
					'ec',
					'-pkeyopt',
					'ec_paramgen_curve:prime256v1',
					'-nodes',
					'-keyout',
					join(dir, 'key.pem'),
					'-out',
					join(dir, 'cert.pem'),
					'-days',
					'1',
					'-subj',
					'/CN=localhost',
					'-addext',
					'subjectAltName=DNS:localhost,IP:127.0.0.1',
				]);
				expect(run.exitCode).toBe(0);
				const tls = { key: readFileSync(join(dir, 'key.pem'), 'utf8'), cert: readFileSync(join(dir, 'cert.pem'), 'utf8') };
				const apple = await fakeApns(() => ({ status: 410, reason: 'Unregistered' }), tls);
				const trusting = await provider(apple.url, { connect: { ca: tls.cert } });
				expect(await trusting.apns.send(TARGET, ALERT)).toEqual({ outcome: 'invalid_token', reason: 'Unregistered' });
				const strict = await provider(apple.url);
				expect((await strict.apns.send(TARGET, ALERT)).outcome).toBe('transient');
				expect(apple.seen.length).toBe(1);
			} finally {
				rmSync(dir, { recursive: true, force: true });
			}
		},
	);
});

describe('a whole HQ pushing through the adapter', () => {
	async function world(reply?: Parameters<typeof fakeApns>[0]) {
		const apple = await fakeApns(reply);
		const { apns } = await provider(apple.url);
		const made = await pair({ push: { provider: apns } });
		return { apple, ...made };
	}
	const register = (who: { as: ReturnType<typeof client> }, token: string) =>
		who.as('POST', '/v1/devices/apns-token', { environment: 'production', status: 'authorized', token });
	const stored = (hq: Awaited<ReturnType<typeof world>>['hq'], deviceId: string) =>
		hq.hub.db
			.query<{ token: string | null }, { d: string }>('SELECT token FROM push_tokens WHERE device_id = $d')
			.get({ d: deviceId })?.token;

	test('a message reaches the other member’s phone, signed and addressed as Apple expects', async () => {
		const { apple, hq, a, b, room } = await world();
		const token = 'c0'.repeat(32);
		expect((await register(b, token)).body).toEqual({ ok: true });
		expect((await say(a.as, room.id, 'Lunch at noon?')).status).toBe(201);
		await until(() => apple.seen.length === 1, 'the push');
		expect(apple.seen[0]!.path).toBe(`/3/device/${token}`);
		expect(apple.seen[0]!.body.aps.alert).toEqual({ title: 'Launch', body: 'Ada: Lunch at noon?' });
		expect(apple.seen[0]!.body.conversation_id).toBe(room.id);
		hq.stop();
	});

	test('a 410 Unregistered clears the token, so the next message sends nothing', async () => {
		const { apple, hq, a, b, room } = await world(() => ({ status: 410, reason: 'Unregistered' }));
		await register(b, 'c1'.repeat(32));
		await say(a.as, room.id, 'one');
		await until(() => stored(hq, b.deviceId) === null, 'the token to be cleared');
		await say(a.as, room.id, 'two');
		await Bun.sleep(50);
		expect(apple.seen.length).toBe(1);
		hq.stop();
	});

	test.each(['BadDeviceToken', 'DeviceTokenNotForTopic'])('a %s does not clear the token', async (reason) => {
		const lines: string[] = [];
		const apple = await fakeApns(() => ({ status: 400, reason }));
		const { apns } = await provider(apple.url);
		const { hq, a, b, room } = await pair({ push: { provider: apns, log: (line) => lines.push(line) } });
		const token = 'c2'.repeat(32);
		await register(b, token);
		await say(a.as, room.id, 'one');
		await until(() => apple.seen.length === 1 && lines.length === 1, 'the push and the warning');
		await Bun.sleep(30);
		expect(stored(hq, b.deviceId)).toBe(token);
		await say(a.as, room.id, 'two');
		await until(() => apple.seen.length === 2, 'the second push');
		expect(lines).toEqual([`[push] APNs config: ${reason}`]);
		expect(lines.join('\n')).not.toContain(token);
		hq.stop();
	});

	test('stopping HQ stops the sender', async () => {
		const { apple, hq, a, b, room } = await world();
		await register(b, 'c3'.repeat(32));
		hq.stop();
		await say(a.as, room.id, 'after stop');
		await Bun.sleep(50);
		expect(apple.seen.length).toBe(0);
	});
});
