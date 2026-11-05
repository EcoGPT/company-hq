import { afterEach, describe, expect, spyOn, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { boot } from '../src/boot';
import { Bus } from '../src/core/events';
import { createHq } from '../src/hq';
import { ApnsProvider, pushFromEnv } from '../src/push';
import type { PushMessage, PushProvider, PushResult, PushTarget } from '../src/push/provider';
import { PushSender } from '../src/push/sender';
import { PushTokens } from '../src/push/store';
import { client, connect, enrolled, pair, say, serve } from './helpers';

type Sent = { target: PushTarget & { deviceId: string }; message: PushMessage };
type Answer = (sent: Sent) => Promise<PushResult> | PushResult;

/** A provider that writes down what it was asked to send. `answer` can fail a push on purpose. */
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

const token = (n: number) => n.toString(16).padStart(2, '0').repeat(32);
const ENV = 'production';

const cleanups: (() => void)[] = [];
afterEach(() => {
	for (const cleanup of cleanups.splice(0)) cleanup();
});

/** Ada, Bo and Cy; Ada and Bo in the "Launch" group. Every push goes through a recorder. */
async function world(options: { preview?: 'full' | 'hidden'; concurrency?: number; maxQueued?: number } = {}, answer?: Answer) {
	const made = await pair();
	const { hq } = made;
	const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
	hq.hub.conversations.addMember(hq.hub.general().id, cy.id);
	const c = await enrolled(hq, hq.hub.keys.mint(cy.id, 'setup').secret, 'Cy Mac');
	const lines: string[] = [];
	const { provider, sent } = recorder(answer);
	const sender = new PushSender(hq.hub, new PushTokens(hq.hub.db), provider, {
		...options,
		log: (line) => lines.push(line),
	}).start();
	cleanups.push(() => {
		sender.stop();
		hq.stop();
	});
	const register = (who: { as: ReturnType<typeof client> }, value: string, environment = ENV) =>
		who.as('POST', '/v1/devices/apns-token', { environment, status: 'authorized', token: value });
	const stored = (deviceId: string) =>
		hq.hub.db
			.query<{ token: string | null; environment: string | null; status: string }, { d: string }>(
				'SELECT token, environment, status FROM push_tokens WHERE device_id = $d',
			)
			.get({ d: deviceId });
	/** Another device for the same person, as a phone beside a Mac. */
	const another = (person: { id: string }, name: string) => enrolled(hq, hq.hub.keys.mint(person.id, 'setup').secret, name);
	const tokensSentTo = () => sent.map((s) => s.target.token).sort();
	const post = (authorId: string, conversationId: string, body: string, extra: Record<string, unknown> = {}) =>
		hq.hub.messages.send({ conversationId, authorId, body, ...extra });
	return { ...made, c, cy, sender, sent, lines, register, stored, another, tokensSentTo, post };
}

describe('the device token routes', () => {
	test('POST stores the token and what the app reported, and answers ok', async () => {
		const { b, register, stored } = await world();
		expect(await register(b, token(1), 'development')).toEqual({ status: 200, body: { ok: true } });
		expect(stored(b.deviceId)).toMatchObject({ token: token(1), environment: 'development', status: 'authorized' });
	});

	test('a status with no token is kept, and the device then holds no token', async () => {
		const { b, register, stored } = await world();
		await register(b, token(1));
		expect((await b.as('POST', '/v1/devices/apns-token', { status: 'denied' })).body).toEqual({ ok: true });
		expect(stored(b.deviceId)).toMatchObject({ token: null, environment: null, status: 'denied' });
		await b.as('POST', '/v1/devices/apns-token', { environment: ENV, token: token(2) });
		expect(stored(b.deviceId)).toMatchObject({ token: token(2), status: 'authorized' });
	});

	test('a new token replaces the old one on the same device', async () => {
		const { b, register, stored, hq } = await world();
		await register(b, token(1));
		await register(b, token(2));
		expect(stored(b.deviceId)?.token).toBe(token(2));
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM push_tokens').get()).toEqual({ n: 1 });
	});

	test('a token another device holds moves to this one, and back again', async () => {
		const { a, b, register, stored } = await world();
		await register(b, token(1));
		await register(a, token(1));
		expect([stored(a.deviceId)?.token, stored(b.deviceId)?.token]).toEqual([token(1), null]);
		await register(b, token(1));
		expect([stored(a.deviceId)?.token, stored(b.deviceId)?.token]).toEqual([null, token(1)]);
	});

	test('a phone that changed hands pushes to its new person only', async () => {
		const { a, b, register, sender, sent, room, post } = await world();
		await register(b, token(1));
		// Bo signed out offline; Ada signs in on the same phone and reports the same token.
		await register(a, token(1));
		post(b.person.id, room.id, 'hi Ada');
		await sender.idle();
		expect(sent.map((s) => s.target)).toEqual([{ token: token(1), environment: ENV, deviceId: a.deviceId }]);
	});

	test('DELETE clears this device’s token and leaves the others', async () => {
		const { a, b, register, stored } = await world();
		await register(a, token(1));
		await register(b, token(2));
		expect(await b.as('DELETE', '/v1/devices/apns-token')).toEqual({ status: 200, body: { ok: true } });
		expect(stored(b.deviceId)).toBeNull();
		expect(stored(a.deviceId)?.token).toBe(token(1));
		// Signing out twice is not an error.
		expect((await b.as('DELETE', '/v1/devices/apns-token')).body).toEqual({ ok: true });
	});

	test.each([
		['an upper-case token', { environment: ENV, status: 'authorized', token: 'AB'.repeat(32) }],
		['a token that is not hex', { environment: ENV, status: 'authorized', token: 'zz'.repeat(32) }],
		['a token that is too short', { environment: ENV, status: 'authorized', token: 'ab' }],
		['a token that is too long', { environment: ENV, status: 'authorized', token: 'ab'.repeat(101) }],
		['a token with no environment', { status: 'authorized', token: token(1) }],
		['an environment with no token', { environment: ENV, status: 'authorized' }],
		['an unknown environment', { environment: 'staging', status: 'authorized', token: token(1) }],
		['an empty status', { status: '' }],
		['a status of 121 characters', { status: 'x'.repeat(121) }],
		['a bad voip token', { status: 'authorized', voip_token: 'nope' }],
		['an array', []],
		['null', null],
	])('400 invalid_body for %s', async (_, body) => {
		const { b, stored } = await world();
		expect(await b.as('POST', '/v1/devices/apns-token', body)).toEqual({ status: 400, body: { error: 'invalid_body' } });
		expect(stored(b.deviceId)).toBeNull();
	});

	test('accepts what the app sends: a 107-character error status, and a voip token with no alert token', async () => {
		const { b, stored } = await world();
		const status = `error: ${'r'.repeat(100)}`;
		const body = { status, environment: ENV, voip_token: token(9) };
		expect((await b.as('POST', '/v1/devices/apns-token', body)).status).toBe(200);
		expect(stored(b.deviceId)?.status).toBe(status);
	});

	test('a body that is not JSON is a 400', async () => {
		const { b, hq } = await world();
		const response = await hq.fetch(
			new Request('http://hq.test/v1/devices/apns-token', {
				method: 'POST',
				headers: { authorization: `Bearer ${b.bearer}` },
				body: 'not json',
			}),
		);
		expect(response?.status).toBe(400);
	});

	test('needs a signed-in device: no key is 401, and a script’s key is refused', async () => {
		const { hq, ada } = await world();
		const anonymous = client(hq);
		const script = client(hq, ada.key);
		expect((await anonymous('POST', '/v1/devices/apns-token', { status: 'authorized' })).status).toBe(401);
		expect(await script('POST', '/v1/devices/apns-token', { status: 'authorized' })).toEqual({
			status: 403,
			body: { error: 'device_only' },
		});
		expect((await script('DELETE', '/v1/devices/apns-token')).status).toBe(403);
	});

	test('a revoked device’s bearer can no longer report', async () => {
		const { b, hq } = await world();
		hq.hub.devices.revoke(b.deviceId);
		expect((await b.as('POST', '/v1/devices/apns-token', { status: 'authorized' })).status).toBe(401);
	});

	test('tokens live in the push table: devices gets no columns', async () => {
		const { hq } = await world();
		const columns = hq.hub.db.query<{ name: string }, []>("SELECT name FROM pragma_table_info('devices')").all();
		expect(columns.map((column) => column.name)).toEqual(['id', 'person_id', 'key_id', 'name', 'created_at']);
	});
});

describe('who a new message is pushed to', () => {
	test('every device with a token that belongs to the room’s other members', async () => {
		const { a, b, c, room, sender, register, tokensSentTo, another } = await world();
		const bosPhone = await another(b.person, 'Bo iPhone');
		await register(b, token(1));
		await register(bosPhone, token(2));
		await register(a, token(3)); // the author
		await register(c, token(4)); // not in the room
		await say(a.as, room.id, 'hello');
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(1), token(2)]);
	});

	test('a member with no token is simply skipped', async () => {
		const { a, room, sender, sent, post } = await world();
		post(a.person.id, room.id, 'anyone there?');
		await sender.idle();
		expect(sent).toEqual([]);
	});

	test('not the author, on any of their devices', async () => {
		const { a, b, room, sender, register, tokensSentTo, another, post } = await world();
		const adasPhone = await another(a.person, 'Ada iPhone');
		await register(a, token(1));
		await register(adasPhone, token(2));
		await register(b, token(3));
		post(a.person.id, room.id, 'mine');
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(3)]);
	});

	test('not a person outside the room, and not one who left it', async () => {
		const { a, b, c, room, sender, register, tokensSentTo, hq, post } = await world();
		await register(b, token(1));
		await register(c, token(2));
		post(a.person.id, room.id, 'one');
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(1)]);
		hq.hub.conversations.removeMember(room.id, b.person.id);
		post(a.person.id, room.id, 'two');
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(1)]);
	});

	test('not an assistant or a service, even with a token in the room', async () => {
		const { a, hq, room, sender, tokensSentTo, post } = await world();
		const tokens = new PushTokens(hq.hub.db);
		for (const [n, kind] of (['assistant', 'service'] as const).entries()) {
			const person = hq.hub.people.create({ name: kind, handle: `${kind}-bot`, kind });
			hq.hub.conversations.addMember(room.id, person.id);
			const { device } = hq.hub.devices.enroll(person.id, 'bot phone');
			tokens.report(device.id, { status: 'authorized', token: token(10 + n), environment: ENV });
		}
		post(a.person.id, room.id, 'hello bots');
		await sender.idle();
		expect(tokensSentTo()).toEqual([]);
	});

	test('a message the assistant writes is pushed to people', async () => {
		const { b, hq, room, sender, register, tokensSentTo, post } = await world();
		await register(b, token(1));
		post(hq.assistant.self.id, room.id, 'Done.');
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(1)]);
	});

	test('not a removed person, though their keys still work; restored, they are again', async () => {
		const { a, b, hq, room, sender, register, tokensSentTo, post } = await world();
		await register(b, token(1));
		hq.hub.people.setRemoved(b.person.id, Date.now());
		post(a.person.id, room.id, 'hello');
		await sender.idle();
		expect(tokensSentTo()).toEqual([]);
		hq.hub.people.setRemoved(b.person.id, null);
		post(a.person.id, room.id, 'welcome back');
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(1)]);
	});

	test('not a revoked device, though its person is still here', async () => {
		const { a, b, hq, room, sender, register, tokensSentTo, another, post } = await world();
		const bosPhone = await another(b.person, 'Bo iPhone');
		await register(b, token(1));
		await register(bosPhone, token(2));
		expect(hq.hub.devices.revoke(b.deviceId)).toBe(true);
		post(a.person.id, room.id, 'hello');
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(2)]);
	});

	test('not an archived room, including one archived after the message was sent', async () => {
		const { a, b, hq, room, sender, register, tokensSentTo, post } = await world();
		await register(b, token(1));
		post(a.person.id, room.id, 'last words');
		hq.hub.conversations.archive(room.id);
		await sender.idle();
		expect(tokensSentTo()).toEqual([]);
		post(a.person.id, room.id, 'into the void');
		await sender.idle();
		expect(tokensSentTo()).toEqual([]);
	});

	test('not a system row, which names a kind', async () => {
		const { a, b, room, sender, register, tokensSentTo, post } = await world();
		await register(b, token(1));
		post(a.person.id, room.id, 'Ada added Cy', { metadata: { kind: 'member_added' } });
		await sender.idle();
		expect(tokensSentTo()).toEqual([]);
		// Other metadata is just metadata.
		post(a.person.id, room.id, 'a note', { metadata: { source: 'app' } });
		await sender.idle();
		expect(tokensSentTo()).toEqual([token(1)]);
	});

	test('not a message unsent before its turn came', async () => {
		const { a, b, hq, room, sender, register, tokensSentTo, post } = await world();
		await register(b, token(1));
		const message = post(a.person.id, room.id, 'oops');
		hq.hub.messages.unsend(message.id);
		await sender.idle();
		expect(tokensSentTo()).toEqual([]);
	});

	test('a device with an open socket is pushed to as well: the app drops the second copy by message id', async () => {
		const { a, b, hq, room, sender, register, sent } = await world();
		await register(b, token(1));
		const server = serve(hq);
		cleanups.push(() => void server.stop(true));
		const socket = await connect(server, b.bearer);
		cleanups.push(() => socket.ws.close());
		expect(hq.socket.onlineDevices().has(b.deviceId)).toBe(true);
		const posted = await say(a.as, room.id, 'both ways');
		const id = posted.body.message.id;
		await socket.take('message', (frame) => frame.message.id === id);
		await sender.idle();
		expect(sent.map((s) => s.message)).toMatchObject([{ type: 'message', messageId: id }]);
	});
});

describe('what a push says', () => {
	test('a titled group: the room is the title and the body starts with the sender', async () => {
		const { a, b, room, sender, register, sent } = await world();
		await register(b, token(1));
		const posted = await say(a.as, room.id, 'Lunch at noon?');
		await sender.idle();
		expect(sent[0]!.message).toEqual({
			type: 'message',
			title: 'Launch',
			body: 'Ada: Lunch at noon?',
			conversationId: room.id,
			messageId: posted.body.message.id,
		});
	});

	test('a direct message: the sender is the title and the body is the text', async () => {
		const { a, b, sender, register, sent } = await world();
		await register(b, token(1));
		const dm = await a.as('POST', '/v1/conversations', { kind: 'dm', person_id: b.person.id });
		await say(a.as, dm.body.conversation.id, 'psst');
		await sender.idle();
		expect(sent[0]!.message).toMatchObject({ title: 'Ada', body: 'psst' });
	});

	test('a group with no title: the sender is the title, and the body is not prefixed twice', async () => {
		const { a, b, hq, sender, register, sent, post } = await world();
		await register(b, token(1));
		const room = hq.hub.conversations.createRoom({ title: '', createdBy: a.person.id, memberIds: [b.person.id] });
		post(a.person.id, room.id, 'anyone?');
		await sender.idle();
		expect(sent[0]!.message).toMatchObject({ title: 'Ada', body: 'anyone?' });
	});

	test('the body is one line, cut at 240 characters with an ellipsis, without splitting a character', async () => {
		const { a, b, room, sender, register, sent, post } = await world();
		await register(b, token(1));
		post(a.person.id, room.id, '😀'.repeat(300));
		post(a.person.id, room.id, 'line one\n\n   line   two\t!');
		post(a.person.id, room.id, 'x'.repeat(200));
		await sender.idle();
		const bodies = sent.map((s) => (s.message as { body: string }).body);
		const long = bodies.find((body) => body.includes('😀'))!;
		expect([...long].length).toBe(240);
		expect(long.endsWith('…')).toBe(true);
		expect(long.startsWith('Ada: 😀')).toBe(true);
		expect(bodies).toContain('Ada: line one line two !');
		expect(bodies).toContain(`Ada: ${'x'.repeat(200)}`);
	});

	test('a long room title is cut, so the payload stays small', async () => {
		const { a, b, hq, sender, register, sent, post } = await world();
		await register(b, token(1));
		const room = hq.hub.conversations.createRoom({ title: '😀'.repeat(300), createdBy: a.person.id, memberIds: [b.person.id] });
		post(a.person.id, room.id, 'x'.repeat(1000));
		await sender.idle();
		const { title, body } = sent[0]!.message as { title: string; body: string };
		expect([[...title].length, title.endsWith('…'), [...body].length]).toEqual([120, true, 240]);
	});

	test('a message that is only a file says so', async () => {
		const { a, b, hq, room, sender, register, sent, post } = await world();
		await register(b, token(1));
		const file = hq.hub.attachments.create({
			conversation_id: room.id,
			uploader_id: a.person.id,
			file_name: 'plan.pdf',
			content_type: 'application/pdf',
			byte_size: 10,
			width: null,
			height: null,
		});
		post(a.person.id, room.id, '', { attachmentIds: [file.id] });
		await sender.idle();
		expect(sent[0]!.message).toMatchObject({ body: 'Ada: Sent an attachment' });
	});

	test('hidden: the sender and "New message", with no text and no room name', async () => {
		const { a, b, room, sender, register, sent } = await world({ preview: 'hidden' });
		await register(b, token(1));
		const posted = await say(a.as, room.id, 'the launch date is a secret');
		await sender.idle();
		expect(sent[0]!.message).toEqual({
			type: 'message',
			title: 'Ada',
			body: 'New message',
			conversationId: room.id,
			messageId: posted.body.message.id,
		});
		expect(JSON.stringify(sent)).not.toContain('secret');
		expect(JSON.stringify(sent)).not.toContain('Launch');
	});
});

describe('read sync', () => {
	const readThrough = (who: { as: ReturnType<typeof client> }, roomId: string, messageId: string) =>
		who.as('POST', `/v1/conversations/${roomId}/read`, { message_id: messageId });

	test('a read is sent, silently, to the reader’s own devices and nobody else’s', async () => {
		const { a, b, room, sender, register, sent, another, post } = await world();
		const bosPhone = await another(b.person, 'Bo iPhone');
		await register(a, token(1));
		await register(b, token(2));
		await register(bosPhone, token(3));
		const posted = post(a.person.id, room.id, 'ping');
		await sender.idle();
		sent.length = 0;
		expect((await readThrough(b, room.id, posted.id)).status).toBe(200);
		await sender.idle();
		expect(sent.map((s) => s.target.token).sort()).toEqual([token(2), token(3)]);
		for (const { message } of sent) {
			expect(message).toEqual({ type: 'read', conversationId: room.id, readThroughMessageId: posted.id });
		}
	});

	test('a read that moves nothing sends nothing', async () => {
		const { a, b, room, sender, register, sent, post } = await world();
		await register(b, token(2));
		const posted = post(a.person.id, room.id, 'ping');
		await readThrough(b, room.id, posted.id);
		await sender.idle();
		sent.length = 0;
		await readThrough(b, room.id, posted.id);
		await sender.idle();
		expect(sent).toEqual([]);
	});

	test('not for a removed reader, a revoked device, a reader who left, or an archived room', async () => {
		const { a, b, hq, room, sender, register, sent, another, post } = await world();
		const bosPhone = await another(b.person, 'Bo iPhone');
		await register(b, token(2));
		await register(bosPhone, token(3));
		const posted = post(a.person.id, room.id, 'ping');
		await sender.idle();
		const read = () => hq.hub.bus.emit({ type: 'read', conversationId: room.id, personId: b.person.id, messageId: posted.id });
		const tokensAfterRead = async () => {
			sent.length = 0;
			read();
			await sender.idle();
			return sent.map((s) => s.target.token).sort();
		};

		expect(await tokensAfterRead()).toEqual([token(2), token(3)]);
		hq.hub.devices.revoke(b.deviceId);
		expect(await tokensAfterRead()).toEqual([token(3)]);
		hq.hub.people.setRemoved(b.person.id, Date.now());
		expect(await tokensAfterRead()).toEqual([]);
		hq.hub.people.setRemoved(b.person.id, null);
		expect(await tokensAfterRead()).toEqual([token(3)]);
		hq.hub.conversations.removeMember(room.id, b.person.id);
		expect(await tokensAfterRead()).toEqual([]);
		hq.hub.conversations.addMember(room.id, b.person.id);
		expect(await tokensAfterRead()).toEqual([token(3)]);
		hq.hub.conversations.archive(room.id);
		expect(await tokensAfterRead()).toEqual([]);
	});
});

type World = Awaited<ReturnType<typeof world>>;
type Waiting = { w: World; victim: { deviceId: string; token: string; as: ReturnType<typeof client> }; messageId: string };

/**
 * A push can wait in the queue a long time (Apple down, 15 s a try). Bo has two devices; the first push is held open while
 * the other waits its turn. Then `change` happens, the held push is released, and the answer is how many pushes were sent:
 * 1 if the waiting one was stopped, 2 if it went out.
 */
async function pushesSentWhenOneWaits(kind: 'message' | 'read', change: (waiting: Waiting) => void | Promise<void>) {
	let release: () => void = () => {};
	const gate = new Promise<void>((resolve) => (release = resolve));
	const w = await world({ concurrency: 1 }, async () => {
		await gate;
		return { outcome: 'sent' };
	});
	const bosPhone = await w.another(w.b.person, 'Bo iPhone');
	await w.register(w.b, token(1));
	await w.register(bosPhone, token(2));
	// A message from Ada is pushed to Bo; for a read, Bo wrote it himself so only the read is pushed.
	const posted = w.post(kind === 'message' ? w.a.person.id : w.b.person.id, w.room.id, 'the launch date');
	if (kind === 'read')
		w.hq.hub.bus.emit({ type: 'read', conversationId: w.room.id, personId: w.b.person.id, messageId: posted.id });
	await until(() => w.sent.length === 1);
	const first = w.sent[0]!.target.token;
	const victim =
		first === token(1)
			? { deviceId: bosPhone.deviceId, token: token(2), as: bosPhone.as }
			: { deviceId: w.b.deviceId, token: token(1), as: w.b.as };
	await change({ w, victim, messageId: posted.id });
	release();
	await w.sender.idle();
	return w.sent.length;
}

describe('a push that waited in the queue is checked again before it is sent', () => {
	const changes: [string, (waiting: Waiting) => void | Promise<void>][] = [
		// A phone changes hands: the token is now another person’s device, and the old message text must not follow it.
		['its token moved to a device of someone outside the room', ({ w, victim }) => w.register(w.c, victim.token).then(() => {})],
		['its token moved to the author’s own device', ({ w, victim }) => w.register(w.a, victim.token).then(() => {})],
		[
			'the device reported a different token',
			({ victim }) => victim.as('POST', '/v1/devices/apns-token', { environment: ENV, token: token(77) }).then(() => {}),
		],
		['the device signed out', ({ victim }) => victim.as('DELETE', '/v1/devices/apns-token').then(() => {})],
		['its device was revoked', ({ w, victim }) => void w.hq.hub.devices.revoke(victim.deviceId)],
		['its person was removed', ({ w }) => w.hq.hub.people.setRemoved(w.b.person.id, Date.now())],
		['its person left the room', ({ w }) => w.hq.hub.conversations.removeMember(w.room.id, w.b.person.id)],
		['the room was archived', ({ w }) => w.hq.hub.conversations.archive(w.room.id)],
	];

	test.each(['message', 'read'] as const)('a %s push still goes out when nothing changed', async (kind) => {
		expect(await pushesSentWhenOneWaits(kind, () => {})).toBe(2);
	});

	test.each(changes)('a message push does not go out if %s', async (_, change) => {
		expect(await pushesSentWhenOneWaits('message', change)).toBe(1);
	});

	test.each(changes)('a read sync does not go out if %s', async (_, change) => {
		expect(await pushesSentWhenOneWaits('read', change)).toBe(1);
	});

	test('a message push does not go out if the message was unsent while it waited', async () => {
		expect(await pushesSentWhenOneWaits('message', ({ w, messageId }) => void w.hq.hub.messages.unsend(messageId))).toBe(1);
	});
});

describe('the queue', () => {
	test('sending never waits for a push: the provider has not been called when send returns', async () => {
		const { a, b, room, sender, register, sent, post } = await world();
		await register(b, token(1));
		post(a.person.id, room.id, 'now');
		expect(sent).toEqual([]);
		await sender.idle();
		expect(sent.length).toBe(1);
	});

	test('a push service that never answers does not hold up sending', async () => {
		const { a, b, room, register, post, hq } = await world({}, () => new Promise<PushResult>(() => {}));
		await register(b, token(1));
		const started = Date.now();
		const response = await say(a.as, room.id, 'still fast');
		post(a.person.id, room.id, 'and again');
		expect(response.status).toBe(201);
		expect(Date.now() - started).toBeLessThan(1000);
		expect(hq.hub.messages.latest(room.id)?.body).toBe('and again');
	});

	test('no more pushes are in flight than the limit', async () => {
		let inFlight = 0;
		let peak = 0;
		const release: (() => void)[] = [];
		const { a, room, register, sender, post, sent, hq, another } = await world({ concurrency: 2 }, () => {
			inFlight += 1;
			peak = Math.max(peak, inFlight);
			return new Promise<PushResult>((resolve) =>
				release.push(() => {
					inFlight -= 1;
					resolve({ outcome: 'sent' });
				}),
			);
		});
		for (let n = 0; n < 5; n++) {
			const person = hq.hub.people.create({ name: `P${n}`, handle: `p${n}` });
			hq.hub.conversations.addMember(room.id, person.id);
			await register(await another(person, `P${n} Mac`), token(20 + n));
		}
		post(a.person.id, room.id, 'to all');
		await until(() => sent.length === 2);
		await Bun.sleep(20);
		expect([sent.length, peak]).toEqual([2, 2]);
		while (sent.length < 5 || release.length > 0) {
			release.shift()?.();
			await Bun.sleep(5);
		}
		await sender.idle();
		expect([sent.length, peak]).toEqual([5, 2]);
	});

	test('events that find the queue full are dropped with a line in the log, and no content', async () => {
		let release: () => void = () => {};
		const gate = new Promise<void>((resolve) => (release = resolve));
		const { a, b, room, sender, register, sent, lines, post } = await world({ concurrency: 1, maxQueued: 1 }, async () => {
			await gate;
			return { outcome: 'sent' };
		});
		await register(b, token(1));
		post(a.person.id, room.id, 'first');
		await until(() => sent.length === 1);
		post(a.person.id, room.id, 'second: waits in the queue');
		post(a.person.id, room.id, 'third: dropped');
		post(a.person.id, room.id, 'fourth: dropped');
		expect(lines).toEqual(['[push] too many pushes waiting; dropping new ones']);
		release();
		await sender.idle();
		expect(sent.length).toBe(2);
	});

	test('past the queue limit the newest pushes are dropped, with one line in the log', async () => {
		const { a, room, register, sender, post, sent, lines, hq, another } = await world({ concurrency: 1, maxQueued: 2 }, () => ({
			outcome: 'sent',
		}));
		for (let n = 0; n < 6; n++) {
			const person = hq.hub.people.create({ name: `P${n}`, handle: `p${n}` });
			hq.hub.conversations.addMember(room.id, person.id);
			await register(await another(person, `P${n} Mac`), token(20 + n));
		}
		post(a.person.id, room.id, 'to all');
		await sender.idle();
		expect(sent.length).toBe(2);
		expect(lines).toEqual(['[push] too many pushes waiting; dropping new ones']);
	});
});

describe('what an answer does to a stored token', () => {
	test('invalid_token clears it, and the next message sends nothing to it', async () => {
		const { a, b, room, sender, register, stored, sent, post } = await world({}, () => ({
			outcome: 'invalid_token',
			reason: 'Unregistered',
		}));
		await register(b, token(1));
		post(a.person.id, room.id, 'one');
		await sender.idle();
		expect(stored(b.deviceId)).toMatchObject({ token: null, environment: null, status: 'unregistered' });
		post(a.person.id, room.id, 'two');
		await sender.idle();
		expect(sent.length).toBe(1);
	});

	test.each(['config', 'transient', 'fatal'] as const)('%s keeps the token and says so once', async (outcome) => {
		const { a, b, room, sender, register, stored, lines, post } = await world({}, () => ({ outcome, reason: 'Why' }));
		await register(b, token(1));
		post(a.person.id, room.id, 'one');
		post(a.person.id, room.id, 'two');
		await sender.idle();
		expect(stored(b.deviceId)?.token).toBe(token(1));
		expect(lines).toEqual([`[push] Fake ${outcome}: Why`]);
		expect(lines.join()).not.toContain(token(1));
	});

	test('a token the device registered while the push was in flight is not cleared with the old one', async () => {
		let register: (value: string) => Promise<unknown> = async () => {};
		const w = await world({}, async () => {
			await register(token(2));
			return { outcome: 'invalid_token' };
		});
		register = (value) => w.register(w.b, value);
		await w.register(w.b, token(1));
		w.post(w.a.person.id, w.room.id, 'one');
		await w.sender.idle();
		expect(w.stored(w.b.deviceId)?.token).toBe(token(2));
	});

	test('an adapter that throws is logged, not fatal', async () => {
		const { a, b, room, sender, register, stored, lines, post } = await world({}, () => {
			throw new Error(`boom ${token(1)}`);
		});
		await register(b, token(1));
		post(a.person.id, room.id, 'one');
		await sender.idle();
		expect(stored(b.deviceId)?.token).toBe(token(1));
		expect(lines).toEqual(['[push] Fake adapter failed']);
	});
});

describe('wired into HQ', () => {
	test('a provider in the options sends on messages, and stopping HQ ends it', async () => {
		const { provider, sent } = recorder();
		const { hq, a, b, room } = await pair({ push: { provider } });
		await b.as('POST', '/v1/devices/apns-token', { environment: ENV, status: 'authorized', token: token(1) });
		await say(a.as, room.id, 'wired');
		await until(() => sent.length === 1);
		hq.stop();
		await say(a.as, room.id, 'after stop');
		await Bun.sleep(30);
		expect(sent.length).toBe(1);
	});

	test('with no provider, tokens are stored and nothing listens on the bus', async () => {
		const listening = spyOn(Bus.prototype, 'on');
		try {
			const before = listening.mock.calls.length;
			createHq().stop();
			const plain = listening.mock.calls.length - before;
			createHq({ push: { provider: null } }).stop();
			expect(listening.mock.calls.length - before - plain).toBe(plain);
			const { provider } = recorder();
			createHq({ push: { provider } }).stop();
			expect(listening.mock.calls.length - before - 2 * plain).toBe(plain + 1);
		} finally {
			listening.mockRestore();
		}
		const { hq, b, room, a } = await pair();
		expect(
			(await b.as('POST', '/v1/devices/apns-token', { environment: ENV, status: 'authorized', token: token(1) })).body,
		).toEqual({ ok: true });
		expect((await say(a.as, room.id, 'quiet')).status).toBe(201);
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM push_tokens').get()).toEqual({ n: 1 });
	});
});

describe('configuration', () => {
	const dirs: string[] = [];
	afterEach(() => {
		for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
	});
	async function keyFile(contents?: string) {
		const dir = mkdtempSync(join(tmpdir(), 'hq-push-key-'));
		dirs.push(dir);
		const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
		const der = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64');
		const pem = `-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----\n`;
		const path = join(dir, 'AuthKey_TEST.p8');
		writeFileSync(path, contents ?? pem);
		return { path, pem, der };
	}
	const all = (path: string) => ({
		HQ_APNS_KEY_FILE: path,
		HQ_APNS_KEY_ID: 'ABC1234567',
		HQ_APNS_TEAM_ID: 'TEAM123456',
		HQ_APNS_TOPIC: 'org.example.hq',
	});

	test('nothing set: push is off and says nothing', () => {
		const lines: string[] = [];
		expect(pushFromEnv({}, (line) => lines.push(line))).toEqual({ provider: null, preview: 'full' });
		expect(lines).toEqual([]);
	});

	test('some set: push is off, with one line naming what is missing', async () => {
		const { path } = await keyFile();
		const lines: string[] = [];
		const { HQ_APNS_TEAM_ID: _team, HQ_APNS_TOPIC: _topic, ...partial } = all(path);
		expect(pushFromEnv(partial, (line) => lines.push(line)).provider).toBeNull();
		expect(lines).toEqual(['[push] off: HQ_APNS_TEAM_ID, HQ_APNS_TOPIC not set']);
		expect(lines.join()).not.toContain(path);
	});

	test('a key file that is missing or is not a .p8 turns push off, and the line never quotes the file', async () => {
		const lines: string[] = [];
		const missing = pushFromEnv(all('/nonexistent/AuthKey.p8'), (line) => lines.push(line));
		const { path } = await keyFile('this is a secret that is not a key');
		const wrong = pushFromEnv(all(path), (line) => lines.push(line));
		expect([missing.provider, wrong.provider]).toEqual([null, null]);
		expect(lines).toEqual([
			'[push] off: HQ_APNS_KEY_FILE cannot be read',
			'[push] off: HQ_APNS_KEY_FILE is not a .p8 key (a PEM that starts BEGIN PRIVATE KEY)',
		]);
		expect(lines.join()).not.toContain('secret');
	});

	test('all four set: push is on, and the one line names the key id and never the key', async () => {
		const { path, der } = await keyFile();
		const lines: string[] = [];
		const options = pushFromEnv(all(path), (line) => lines.push(line));
		expect(options.provider).toBeInstanceOf(ApnsProvider);
		expect(options.preview).toBe('full');
		expect(lines).toEqual(['[push] on: APNs, key id ABC1234567, full previews']);
		expect(lines.join()).not.toContain(der.slice(0, 20));
		options.provider?.close();
	});

	test.each([
		[undefined, 'full', 0],
		['full', 'full', 0],
		['hidden', 'hidden', 0],
		['HIDDEN', 'hidden', 0],
		// A typo must not send text the host meant to keep back.
		['hiden', 'hidden', 1],
	] as const)('HQ_PUSH_PREVIEW=%s is %s', (value, preview, warned) => {
		const lines: string[] = [];
		expect(pushFromEnv({ HQ_PUSH_PREVIEW: value }, (line) => lines.push(line)).preview).toBe(preview);
		expect(lines.length).toBe(warned);
	});

	test('boot reads it: with the four set HQ starts with a sender, with none it does not', async () => {
		const { path } = await keyFile();
		const log = spyOn(console, 'warn').mockImplementation(() => {});
		try {
			const quiet = boot({ HQ_DB: ':memory:' });
			quiet.hq.stop();
			expect(log).not.toHaveBeenCalled();
			const configured = boot({ HQ_DB: ':memory:', ...all(path) });
			configured.hq.stop();
			expect(log).toHaveBeenCalledWith('[push] on: APNs, key id ABC1234567, full previews');
		} finally {
			log.mockRestore();
		}
	});
});

function until(check: () => boolean): Promise<void> {
	return (async () => {
		for (let i = 0; i < 400; i++) {
			if (check()) return;
			await Bun.sleep(5);
		}
		throw new Error('timed out');
	})();
}
