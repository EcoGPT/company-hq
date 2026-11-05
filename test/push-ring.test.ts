import { afterEach, describe, expect, setSystemTime, test } from 'bun:test';
import http2 from 'node:http2';
import type { HubEvent } from '../src/core/events';
import { migrate, openDatabase } from '../src/db/database';
import { ApnsProvider } from '../src/push/apns';
import type { PushMessage, PushProvider, PushResult, PushTarget } from '../src/push/provider';
import { PushSender } from '../src/push/sender';
import { PUSH_MIGRATIONS, PushTokens } from '../src/push/store';
import { client, enrolled, pair } from './helpers';

// Rings by push: a `call.ringing` event on the bus becomes a VoIP push for a phone that reported a ring token, and an
// alert push for any other device with a token. The calls feature emits the event; here the tests emit it themselves.
// Nothing contacts Apple: the adapter tests point at a local HTTP/2 server, with a key pair made for each run.

const CALL = '0192f7a0-1b2c-7d3e-8f40-5a6b7c8d9e0f';
const token = (n: number) => n.toString(16).padStart(2, '0').repeat(32);
const ENV = 'production';
const inSeconds = (seconds: number) => new Date(Date.now() + seconds * 1000).toISOString();

const cleanups: (() => void)[] = [];
afterEach(() => {
	for (const cleanup of cleanups.splice(0)) cleanup();
});

async function until(check: () => boolean, what = 'the condition') {
	const end = Date.now() + 5000;
	while (!check()) {
		if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
		await Bun.sleep(5);
	}
}

type Ringing = Extract<HubEvent, { type: 'call.ringing' }>;

// ---------------------------------------------------------------------------------------------------------------------
// The request Apple gets

type Seen = { path: string; headers: http2.IncomingHttpHeaders; body: any };

async function fakeApns(reply: (seen: Seen) => { status: number; reason?: string } = () => ({ status: 200 })) {
	const seen: Seen[] = [];
	const sessions = new Set<http2.ServerHttp2Session>();
	const server = http2.createServer();
	server.on('session', (session) => {
		sessions.add(session);
		session.on('close', () => sessions.delete(session));
	});
	server.on('stream', (stream: http2.ServerHttp2Stream, headers: http2.IncomingHttpHeaders) => {
		const chunks: Buffer[] = [];
		stream.on('data', (chunk: Buffer) => chunks.push(chunk));
		stream.on('end', () => {
			const record = { path: String(headers[':path']), headers, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) };
			seen.push(record);
			const answer = reply(record);
			stream.respond({ ':status': answer.status, 'content-type': 'application/json' });
			stream.end(answer.reason === undefined ? '' : JSON.stringify({ reason: answer.reason }));
		});
	});
	await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
	const { port } = server.address() as { port: number };
	cleanups.push(() => {
		for (const session of sessions) session.destroy();
		server.close();
	});
	return { url: `http://127.0.0.1:${port}`, seen };
}

async function apnsAt(url: string) {
	const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
	const der = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64');
	const key = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g)!.join('\n')}\n-----END PRIVATE KEY-----\n`;
	const apns = new ApnsProvider({ key, keyId: 'KEY1234567', teamId: 'TEAM123456', topic: 'org.example.hq', baseUrl: url });
	cleanups.push(() => apns.close());
	return apns;
}

const TARGET: PushTarget = { token: 'ab'.repeat(32), environment: 'production' };
const EXPIRES = '2030-01-02T03:04:05.678Z';
const RING = {
	type: 'ring',
	callId: CALL,
	callerName: 'Ada',
	conversationId: 'c-1',
	conversationTitle: 'Launch',
	expiresAt: EXPIRES,
} as const;

describe('the request Apple gets for a ring', () => {
	test('a VoIP ring goes to the .voip topic at once, expires with the ring, and carries what CallKit shows', async () => {
		const apple = await fakeApns();
		const apns = await apnsAt(apple.url);
		expect(await apns.send(TARGET, { ...RING, channel: 'voip' })).toEqual({ outcome: 'sent' });
		const [request] = apple.seen;
		expect(request!.path).toBe(`/3/device/${TARGET.token}`);
		expect(request!.headers['apns-push-type']).toBe('voip');
		expect(request!.headers['apns-topic']).toBe('org.example.hq.voip');
		expect(request!.headers['apns-priority']).toBe('10');
		expect(request!.headers['apns-expiration']).toBe(String(Math.floor(Date.parse(EXPIRES) / 1000)));
		expect(request!.headers['apns-collapse-id']).toBeUndefined();
		expect(request!.body).toEqual({
			call_id: CALL,
			caller_name: 'Ada',
			conversation_id: 'c-1',
			conversation_title: 'Launch',
			expires_at: EXPIRES,
		});
	});

	test('a VoIP ring from a direct message has a null room title', async () => {
		const apple = await fakeApns();
		const apns = await apnsAt(apple.url);
		await apns.send(TARGET, { ...RING, channel: 'voip', conversationTitle: null });
		expect(apple.seen[0]!.body.conversation_title).toBeNull();
	});

	test('an alert ring is a banner with the call id, collapsed per call, that wakes the app and expires with the ring', async () => {
		const apple = await fakeApns();
		const apns = await apnsAt(apple.url);
		expect(await apns.send(TARGET, { ...RING, channel: 'alert' })).toEqual({ outcome: 'sent' });
		const [request] = apple.seen;
		expect(request!.headers['apns-push-type']).toBe('alert');
		expect(request!.headers['apns-topic']).toBe('org.example.hq');
		expect(request!.headers['apns-priority']).toBe('10');
		expect(request!.headers['apns-collapse-id']).toBe(`ring:${CALL}`);
		expect(request!.headers['apns-expiration']).toBe(String(Math.floor(Date.parse(EXPIRES) / 1000)));
		expect(request!.body).toEqual({
			aps: {
				alert: { title: 'Incoming call', body: 'Ada is calling in Launch' },
				sound: 'default',
				'content-available': 1,
			},
			call_id: CALL,
			conversation_id: 'c-1',
		});
		// No `message_id`: the app would dedupe a ring against a message.
		expect(request!.body.message_id).toBeUndefined();
	});

	test('an alert ring from a direct message names only the caller', async () => {
		const apple = await fakeApns();
		const apns = await apnsAt(apple.url);
		await apns.send(TARGET, { ...RING, channel: 'alert', conversationTitle: null });
		expect(apple.seen[0]!.body.aps.alert).toEqual({ title: 'Incoming call', body: 'Ada is calling' });
	});
});

// ---------------------------------------------------------------------------------------------------------------------
// Who is rung, through a recording provider

type Sent = { target: PushTarget & { deviceId: string; kind?: string }; message: PushMessage };
type Answer = (sent: Sent) => Promise<PushResult> | PushResult;

function recorder(answer: Answer = () => ({ outcome: 'sent' })) {
	const sent: Sent[] = [];
	const provider: PushProvider = {
		name: 'Fake',
		send: async (target, message) => {
			const record = { target: target as Sent['target'], message };
			sent.push(record);
			return answer(record);
		},
		close: () => {},
	};
	return { provider, sent };
}

/** Ada calls; Bo (Mac and phone) and Cy are in the "Launch" room with her, Di is not. */
async function world(options: { preview?: 'full' | 'hidden'; concurrency?: number } = {}, answer?: Answer) {
	const made = await pair();
	const { hq, room } = made;
	const person = async (name: string, inRoom: boolean) => {
		const p = hq.hub.people.create({ name, handle: name.toLowerCase() });
		hq.hub.conversations.addMember(hq.hub.general().id, p.id);
		if (inRoom) hq.hub.conversations.addMember(room.id, p.id);
		return enrolled(hq, hq.hub.keys.mint(p.id, 'setup').secret, `${name} Mac`);
	};
	const c = await person('Cy', true);
	const d = await person('Di', false);
	const bosPhone = await enrolled(hq, hq.hub.keys.mint(made.b.person.id, 'setup').secret, 'Bo iPhone');
	const lines: string[] = [];
	const { provider, sent } = recorder(answer);
	const tokens = new PushTokens(hq.hub.db);
	const sender = new PushSender(hq.hub, tokens, provider, { ...options, log: (line) => lines.push(line) }).start();
	cleanups.push(() => {
		sender.stop();
		hq.stop();
	});
	const report = (who: { as: ReturnType<typeof client> }, body: Record<string, unknown>) =>
		who.as('POST', '/v1/devices/apns-token', { status: 'authorized', ...body });
	const alertOnly = (who: { as: ReturnType<typeof client> }, value: string) => report(who, { environment: ENV, token: value });
	const both = (who: { as: ReturnType<typeof client> }, value: string, voip: string) =>
		report(who, { environment: ENV, token: value, voip_token: voip });
	const ring = (personIds: string[], extra: Partial<Ringing> = {}) =>
		hq.hub.bus.emit({
			type: 'call.ringing',
			callId: CALL,
			conversationId: room.id,
			callerName: 'Ada',
			conversationTitle: 'Launch',
			expiresAt: inSeconds(45),
			personIds,
			...extra,
		});
	const stored = (deviceId: string) =>
		hq.hub.db
			.query<
				{ token: string | null; environment: string | null; voip_token: string | null; voip_environment: string | null },
				{ d: string }
			>('SELECT token, environment, voip_token, voip_environment FROM push_tokens WHERE device_id = $d')
			.get({ d: deviceId });
	const rung = () => sent.map((s) => `${(s.message as { channel: string }).channel}:${s.target.token}`).sort();
	return { ...made, c, d, bosPhone, sender, sent, lines, report, alertOnly, both, ring, stored, rung };
}

describe('the device token routes keep a ring token', () => {
	test('POST stores voip_token beside the token, with the same environment', async () => {
		const { b, both, stored } = await world();
		expect((await both(b, token(1), token(2))).body).toEqual({ ok: true });
		expect(stored(b.deviceId)).toEqual({ token: token(1), environment: ENV, voip_token: token(2), voip_environment: ENV });
	});

	test('a report without voip_token clears it, and keeps the alert token', async () => {
		const { b, both, alertOnly, stored } = await world();
		await both(b, token(1), token(2));
		await alertOnly(b, token(1));
		expect(stored(b.deviceId)).toMatchObject({ token: token(1), voip_token: null, voip_environment: null });
	});

	test('a phone that refused notifications keeps its voip_token on its own environment', async () => {
		const { b, both, report, stored } = await world();
		await both(b, token(1), token(2));
		expect((await report(b, { status: 'denied', environment: 'development', voip_token: token(2) })).status).toBe(200);
		expect(stored(b.deviceId)).toEqual({
			token: null,
			environment: null,
			voip_token: token(2),
			voip_environment: 'development',
		});
	});

	test("a voip_token with no environment is a 400: nothing says which of Apple's hosts it belongs to", async () => {
		const { b, report, stored } = await world();
		expect(await report(b, { status: 'denied', voip_token: token(2) })).toEqual({ status: 400, body: { error: 'invalid_body' } });
		expect(stored(b.deviceId)).toBeNull();
	});

	test('DELETE clears both tokens', async () => {
		const { b, both, stored } = await world();
		await both(b, token(1), token(2));
		expect((await b.as('DELETE', '/v1/devices/apns-token')).body).toEqual({ ok: true });
		expect(stored(b.deviceId)).toBeNull();
	});

	test('a ring token another device holds moves to this one, like the alert token', async () => {
		const { b, bosPhone, a, both, stored } = await world();
		await both(bosPhone, token(1), token(2));
		// The phone changed hands: Ada signs in on it and reports the same tokens.
		await both(a, token(1), token(2));
		expect(stored(bosPhone.deviceId)).toMatchObject({ token: null, voip_token: null, voip_environment: null });
		expect(stored(a.deviceId)).toMatchObject({ token: token(1), voip_token: token(2) });
		// A different alert token but the same ring token still moves the ring token.
		await both(b, token(3), token(2));
		expect([stored(a.deviceId)?.voip_token, stored(b.deviceId)?.voip_token]).toEqual([null, token(2)]);
	});

	test('a bad voip_token is a 400 and stores nothing', async () => {
		const { b, both, stored } = await world();
		expect(await both(b, token(1), 'NOT-HEX')).toEqual({ status: 400, body: { error: 'invalid_body' } });
		expect(stored(b.deviceId)).toBeNull();
	});

	test('the database refuses a ring token without its environment, or a bad environment', async () => {
		const { hq, b, both } = await world();
		await both(b, token(1), token(2));
		const set = (sql: string) => () => hq.hub.db.query(sql).run();
		expect(set(`UPDATE push_tokens SET voip_environment = NULL`)).toThrow();
		expect(set(`UPDATE push_tokens SET voip_environment = 'staging'`)).toThrow();
		expect(set(`UPDATE push_tokens SET voip_token = NULL`)).toThrow();
	});
});

describe('push/002 on a database that already has tokens', () => {
	test('every row and token survives, and starts with no ring token', () => {
		const db = openDatabase();
		db.exec(`CREATE TABLE devices (id TEXT PRIMARY KEY)`);
		db.exec(`INSERT INTO devices (id) VALUES ('d1'), ('d2')`);
		migrate(db, PUSH_MIGRATIONS.slice(0, 1));
		db.exec(`INSERT INTO push_tokens (device_id, token, environment, status, status_at)
			VALUES ('d1', '${token(1)}', 'production', 'authorized', 1), ('d2', NULL, NULL, 'denied', 2)`);
		migrate(db, PUSH_MIGRATIONS);
		expect(db.query('SELECT * FROM push_tokens ORDER BY device_id').all()).toEqual([
			{
				device_id: 'd1',
				token: token(1),
				environment: 'production',
				status: 'authorized',
				status_at: 1,
				voip_token: null,
				voip_environment: null,
			},
			{
				device_id: 'd2',
				token: null,
				environment: null,
				status: 'denied',
				status_at: 2,
				voip_token: null,
				voip_environment: null,
			},
		]);
	});
});

describe('who a ring is pushed to', () => {
	test('a phone with a ring token gets a VoIP push; a device with only an alert token gets an alert push', async () => {
		const { b, bosPhone, c, both, alertOnly, ring, sender, rung } = await world();
		await alertOnly(b, token(1));
		await both(bosPhone, token(2), token(3));
		await alertOnly(c, token(4));
		ring([b.person.id, c.person.id]);
		await sender.idle();
		expect(rung()).toEqual([`alert:${token(1)}`, `alert:${token(4)}`, `voip:${token(3)}`]);
	});

	test('the push names the call, the caller and the room', async () => {
		const { b, alertOnly, ring, sender, sent, room } = await world();
		await alertOnly(b, token(1));
		const expiresAt = inSeconds(45);
		ring([b.person.id], { expiresAt });
		await sender.idle();
		expect(sent[0]!.message).toEqual({
			type: 'ring',
			channel: 'alert',
			callId: CALL,
			callerName: 'Ada',
			conversationId: room.id,
			conversationTitle: 'Launch',
			expiresAt,
		});
	});

	test('only the people named: not the caller, nor a room member who was not rung', async () => {
		const { a, b, c, alertOnly, ring, sender, rung } = await world();
		await alertOnly(a, token(1));
		await alertOnly(b, token(2));
		await alertOnly(c, token(3));
		ring([b.person.id]);
		await sender.idle();
		expect(rung()).toEqual([`alert:${token(2)}`]);
	});

	test('a person named twice is rung once', async () => {
		const { b, alertOnly, ring, sender, rung } = await world();
		await alertOnly(b, token(1));
		ring([b.person.id, b.person.id]);
		await sender.idle();
		expect(rung()).toEqual([`alert:${token(1)}`]);
	});

	test('not a person outside the room, even when named', async () => {
		const { d, alertOnly, ring, sender, sent } = await world();
		await alertOnly(d, token(1));
		ring([d.person.id]);
		await sender.idle();
		expect(sent).toEqual([]);
	});

	test('not a removed person, a revoked device, or anyone in an archived room', async () => {
		const { hq, b, bosPhone, c, room, alertOnly, both, ring, sender, rung, sent } = await world();
		await alertOnly(b, token(1));
		await both(bosPhone, token(2), token(3));
		await alertOnly(c, token(4));
		const after = async () => {
			sent.length = 0;
			ring([b.person.id, c.person.id]);
			await sender.idle();
			return rung();
		};
		hq.hub.devices.revoke(bosPhone.deviceId);
		expect(await after()).toEqual([`alert:${token(1)}`, `alert:${token(4)}`]);
		hq.hub.people.setRemoved(c.person.id, Date.now());
		expect(await after()).toEqual([`alert:${token(1)}`]);
		hq.hub.conversations.archive(room.id);
		expect(await after()).toEqual([]);
	});

	test('a ring that has already run out sends nothing', async () => {
		const { b, alertOnly, ring, sender, sent } = await world();
		await alertOnly(b, token(1));
		ring([b.person.id], { expiresAt: inSeconds(-1) });
		ring([b.person.id], { expiresAt: 'not a date' });
		await sender.idle();
		expect(sent).toEqual([]);
	});

	test('a hidden preview keeps the room title back and still names the caller, as for messages', async () => {
		const { b, bosPhone, alertOnly, both, ring, sender, sent } = await world({ preview: 'hidden' });
		await alertOnly(b, token(1));
		await both(bosPhone, token(2), token(3));
		ring([b.person.id]);
		await sender.idle();
		expect(sent.map((s) => s.message)).toMatchObject([
			{ callerName: 'Ada', conversationTitle: null },
			{ callerName: 'Ada', conversationTitle: null },
		]);
		expect(JSON.stringify(sent)).not.toContain('Launch');
	});

	test('a phone that refused notifications still rings, by VoIP push on its own environment', async () => {
		const { b, report, ring, sender, sent } = await world();
		await report(b, { status: 'denied', environment: 'development', voip_token: token(5) });
		ring([b.person.id]);
		await sender.idle();
		expect(sent.map((s) => [s.target.token, s.target.environment, (s.message as { channel: string }).channel])).toEqual([
			[token(5), 'development', 'voip'],
		]);
	});

	test('a long caller or room name is cut, and an empty room title is none', async () => {
		const { b, alertOnly, ring, sender, sent } = await world();
		await alertOnly(b, token(1));
		ring([b.person.id], { callerName: '😀'.repeat(300), conversationTitle: 'x'.repeat(300) });
		ring([b.person.id], { conversationTitle: '  ' });
		await sender.idle();
		const [long, untitled] = sent.map((s) => s.message as Extract<PushMessage, { type: 'ring' }>);
		expect([[...long!.callerName].length, long!.conversationTitle!.length]).toEqual([120, 120]);
		expect(untitled!.conversationTitle).toBeNull();
	});

	test('the ring never waits for Apple: nothing has been sent when the event returns', async () => {
		const { b, alertOnly, ring, sent } = await world({}, () => new Promise<PushResult>(() => {}));
		await alertOnly(b, token(1));
		const started = Date.now();
		ring([b.person.id]);
		expect(sent).toEqual([]);
		expect(Date.now() - started).toBeLessThan(100);
		await until(() => sent.length === 1, 'the push');
	});
});

type World = Awaited<ReturnType<typeof world>>;
type Change = (w: World, waiting: string) => unknown;

describe('a ring that waited in the queue is checked again before it is sent', () => {
	/**
	 * Bo's Mac and phone are both rung; the first push is held open while the other waits its turn. Then `change` happens,
	 * the first is released, and the answer is how many pushes went out: 1 if the waiting one was stopped.
	 */
	async function sentWhenOneWaits(change: Change) {
		let release: () => void = () => {};
		const gate = new Promise<void>((resolve) => (release = resolve));
		const w = await world({ concurrency: 1 }, async () => {
			await gate;
			return { outcome: 'sent' };
		});
		await w.alertOnly(w.b, token(1));
		await w.both(w.bosPhone, token(2), token(3));
		w.ring([w.b.person.id]);
		await until(() => w.sent.length === 1, 'the first push');
		const waiting = w.sent[0]!.target.deviceId === w.b.deviceId ? w.bosPhone.deviceId : w.b.deviceId;
		await change(w, waiting);
		release();
		await w.sender.idle();
		return w.sent.length;
	}
	const as = (w: World, deviceId: string) => (deviceId === w.b.deviceId ? w.b : w.bosPhone);

	test('it still goes out when nothing changed', async () => {
		expect(await sentWhenOneWaits(() => {})).toBe(2);
	});

	test.each([
		['the person left the room', (w: World) => w.hq.hub.conversations.removeMember(w.room.id, w.b.person.id)],
		['the room was archived', (w: World) => w.hq.hub.conversations.archive(w.room.id)],
		['the person was removed', (w: World) => w.hq.hub.people.setRemoved(w.b.person.id, Date.now())],
		['the device was revoked', (w: World, waiting: string) => void w.hq.hub.devices.revoke(waiting)],
		['the device signed out', (w: World, waiting: string) => as(w, waiting).as('DELETE', '/v1/devices/apns-token')],
		[
			'the device reported new tokens',
			(w: World, waiting: string) => w.both(as(w, waiting), token(70), token(71)).then(() => {}),
		],
		[
			'its tokens moved to someone outside the room',
			async (w: World, waiting: string) => {
				const row = w.stored(waiting)!;
				await w.report(w.d, { environment: ENV, token: row.token, voip_token: row.voip_token ?? undefined });
			},
		],
		[
			'the call ended',
			(w: World) =>
				w.hq.hub.bus.emit({
					type: 'call.ended',
					callId: CALL,
					conversationId: w.room.id,
					meetingId: null,
					endedAt: new Date().toISOString(),
				}),
		],
	] satisfies [string, Change][])('it does not go out if %s', async (_, change) => {
		expect(await sentWhenOneWaits(change)).toBe(1);
	});

	test('it still goes out if some other call ended', async () => {
		const other = (w: World) =>
			w.hq.hub.bus.emit({
				type: 'call.ended',
				callId: crypto.randomUUID(),
				conversationId: w.room.id,
				meetingId: null,
				endedAt: new Date().toISOString(),
			});
		expect(await sentWhenOneWaits(other)).toBe(2);
	});

	test('an ended call is remembered for ten minutes, then forgotten as others end', async () => {
		const start = Date.now();
		try {
			const w = await world();
			await w.alertOnly(w.b, token(1));
			const end = (callId: string) =>
				w.hq.hub.bus.emit({
					type: 'call.ended',
					callId,
					conversationId: w.room.id,
					meetingId: null,
					endedAt: new Date().toISOString(),
				});
			end(CALL);
			setSystemTime(new Date(start + 9 * 60_000));
			end(crypto.randomUUID());
			w.ring([w.b.person.id]);
			await w.sender.idle();
			expect(w.sent.length).toBe(0);
			setSystemTime(new Date(start + 11 * 60_000));
			end(crypto.randomUUID());
			w.ring([w.b.person.id], { expiresAt: new Date(start + 12 * 60_000).toISOString() });
			await w.sender.idle();
			expect(w.sent.length).toBe(1);
		} finally {
			setSystemTime();
		}
	});

	test('it still goes out if the device only added a ring token: the alert token it was sent to is still held', async () => {
		let release: () => void = () => {};
		const gate = new Promise<void>((resolve) => (release = resolve));
		const w = await world({ concurrency: 1 }, async () => {
			await gate;
			return { outcome: 'sent' };
		});
		await w.alertOnly(w.c, token(4));
		await w.alertOnly(w.b, token(1));
		// Cy is queued first and holds the queue; Bo's Mac waits behind.
		w.ring([w.c.person.id, w.b.person.id]);
		await until(() => w.sent.length === 1, 'the first push');
		await w.both(w.b, token(1), token(60));
		release();
		await w.sender.idle();
		expect(w.rung()).toEqual([`alert:${token(1)}`, `alert:${token(4)}`]);
	});

	test('it does not go out if the ring ran out while it waited', async () => {
		let release: () => void = () => {};
		const gate = new Promise<void>((resolve) => (release = resolve));
		const w = await world({ concurrency: 1 }, async () => {
			await gate;
			return { outcome: 'sent' };
		});
		await w.alertOnly(w.b, token(1));
		await w.alertOnly(w.bosPhone, token(2));
		w.ring([w.b.person.id], { expiresAt: inSeconds(0.3) });
		await until(() => w.sent.length === 1, 'the first push');
		await Bun.sleep(400);
		release();
		await w.sender.idle();
		expect(w.sent.length).toBe(1);
	});
});

describe('what an answer does to a stored ring token', () => {
	test('invalid_token on a VoIP ring clears only the ring token, so the next ring is an alert push', async () => {
		const { bosPhone, both, ring, sender, stored, rung, sent } = await world({}, (s) =>
			s.target.token === token(3) ? { outcome: 'invalid_token', reason: 'Unregistered' } : { outcome: 'sent' },
		);
		await both(bosPhone, token(2), token(3));
		ring([bosPhone.person.id]);
		await sender.idle();
		expect(stored(bosPhone.deviceId)).toMatchObject({ token: token(2), environment: ENV, voip_token: null });
		sent.length = 0;
		ring([bosPhone.person.id]);
		await sender.idle();
		expect(rung()).toEqual([`alert:${token(2)}`]);
	});

	test('invalid_token on an alert ring clears the alert token', async () => {
		const { b, alertOnly, ring, sender, stored } = await world({}, () => ({ outcome: 'invalid_token' }));
		await alertOnly(b, token(1));
		ring([b.person.id]);
		await sender.idle();
		expect(stored(b.deviceId)).toMatchObject({ token: null, environment: null });
	});

	test('a ring token reported again while the push was in flight is not cleared with the old one', async () => {
		let swap: () => Promise<unknown> = async () => {};
		const w = await world({}, async () => {
			await swap();
			return { outcome: 'invalid_token' };
		});
		swap = () => w.both(w.bosPhone, token(2), token(9));
		await w.both(w.bosPhone, token(2), token(3));
		w.ring([w.b.person.id]);
		await w.sender.idle();
		expect(w.stored(w.bosPhone.deviceId)?.voip_token).toBe(token(9));
	});

	test.each(['config', 'transient', 'fatal'] as const)('%s keeps both tokens and is logged once', async (outcome) => {
		const { bosPhone, both, ring, sender, stored, lines } = await world({}, () => ({ outcome, reason: 'Why' }));
		await both(bosPhone, token(2), token(3));
		ring([bosPhone.person.id]);
		ring([bosPhone.person.id]);
		await sender.idle();
		expect(stored(bosPhone.deviceId)).toMatchObject({ token: token(2), voip_token: token(3) });
		expect(lines).toEqual([`[push] Fake ${outcome}: Why`]);
	});
});

describe('a whole HQ ringing through the adapter', () => {
	test('a call.ringing event reaches the fake Apple as a VoIP push and an alert push, and a 410 clears the ring token', async () => {
		const apple = await fakeApns((seen) =>
			seen.headers['apns-push-type'] === 'voip' ? { status: 410, reason: 'Unregistered' } : { status: 200 },
		);
		const apns = await apnsAt(apple.url);
		const { hq, b, room } = await pair({ push: { provider: apns } });
		cleanups.push(() => hq.stop());
		const phone = await enrolled(hq, hq.hub.keys.mint(b.person.id, 'setup').secret, 'Bo iPhone');
		await b.as('POST', '/v1/devices/apns-token', { environment: ENV, status: 'authorized', token: token(1) });
		await phone.as('POST', '/v1/devices/apns-token', {
			environment: ENV,
			status: 'authorized',
			token: token(2),
			voip_token: token(3),
		});
		const expiresAt = inSeconds(45);
		hq.hub.bus.emit({
			type: 'call.ringing',
			callId: CALL,
			conversationId: room.id,
			callerName: 'Ada',
			conversationTitle: 'Launch',
			expiresAt,
			personIds: [b.person.id],
		});
		await until(() => apple.seen.length === 2, 'both pushes');
		const voip = apple.seen.find((s) => s.headers['apns-push-type'] === 'voip')!;
		const alert = apple.seen.find((s) => s.headers['apns-push-type'] === 'alert')!;
		expect(voip.path).toBe(`/3/device/${token(3)}`);
		expect(voip.headers['apns-topic']).toBe('org.example.hq.voip');
		expect(voip.body).toEqual({
			call_id: CALL,
			caller_name: 'Ada',
			conversation_id: room.id,
			conversation_title: 'Launch',
			expires_at: expiresAt,
		});
		expect(alert.path).toBe(`/3/device/${token(1)}`);
		expect(alert.body.call_id).toBe(CALL);
		const row = () =>
			hq.hub.db
				.query<{ token: string | null; voip_token: string | null }, { d: string }>(
					'SELECT token, voip_token FROM push_tokens WHERE device_id = $d',
				)
				.get({ d: phone.deviceId });
		await until(() => row()?.voip_token === null, 'the ring token to be cleared');
		expect(row()).toEqual({ token: token(2), voip_token: null });
	});
});
