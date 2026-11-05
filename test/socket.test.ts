import { afterEach, describe, expect, test } from 'bun:test';
import type { Server } from 'bun';
import type { HqOptions } from '../src/hq';
import type { SocketData } from '../src/realtime/socket';
import { connect, enrolled, pair, say, serve, type Connection } from './helpers';

let server: Server<SocketData> | undefined;
let open: Connection[] = [];
afterEach(() => {
	for (const connection of open) connection.ws.close();
	open = [];
	// Bun 1.3.14's stop(true) never settles after a server-initiated close, so it is not awaited.
	void server?.stop(true);
});

const track = async (connection: Promise<Connection>) => {
	const ready = await connection;
	open.push(ready);
	return ready;
};

async function world(options: HqOptions = {}) {
	const world = await pair(options);
	server = serve(world.hq);
	const cy = await enrolled(world.hq, world.hq.hub.keys.mint(world.hq.hub.people.create({ name: 'Cy', handle: 'cy' }).id).secret);
	const sockets = {
		a: await track(connect(server, world.a.bearer)),
		b: await track(connect(server, world.b.bearer)),
		cy: await track(connect(server, cy.bearer)),
	};
	const settle = () => Promise.all(Object.values(sockets).map((s) => s.settle()));
	return { ...world, cy, sockets, settle };
}

const typesOf = (connection: Connection) => connection.types().filter((type) => type !== 'hello' && type !== 'presence');

describe('connecting', () => {
	test('hello comes first, names the device, and counts who is on', async () => {
		const { a, b, sockets } = await world();
		expect(sockets.a.frames[0]).toEqual({
			type: 'hello',
			device_id: a.deviceId,
			person_id: a.person.id,
			online_person_ids: [a.person.id],
			wire_version: 1,
		});
		expect(sockets.cy.frames[0]!.online_person_ids.sort()).toEqual(
			[a.person.id, b.person.id, sockets.cy.frames[0]!.person_id].sort(),
		);
	});

	test('text ping is answered with pong, and only a bearer opens a socket', async () => {
		const { hq, ada } = await pair();
		server = serve(hq);
		const url = `http://localhost:${server.port}/v1/ws`;
		const upgrade = {
			upgrade: 'websocket',
			connection: 'upgrade',
			'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
			'sec-websocket-version': '13',
		};
		expect((await fetch(url)).status).toBe(426);
		expect(await (await fetch(url, { headers: upgrade })).json()).toEqual({ error: 'unauthorized' });
		expect((await fetch(`${url}?token=${ada.key}`, { headers: upgrade })).status).toBe(401);
		expect((await fetch(url, { headers: { ...upgrade, authorization: 'Bearer hq_wrong' } })).status).toBe(401);
		const ws = await track(connect(server, ada.key));
		await ws.settle();
	});
});

describe('frames go only to people who can see the conversation', () => {
	test('a message reaches the room, the sender included, and nobody else', async () => {
		const { a, b, room, sockets, settle } = await world();
		const sent = (await say(a.as, room.id, 'ship it')).body.message;
		await settle();
		for (const who of [sockets.a, sockets.b]) expect(await who.take('message')).toEqual({ type: 'message', message: sent });
		expect(typesOf(sockets.cy)).toEqual([]);
		expect(b.person.id).not.toBe(a.person.id);
	});

	test('edits, unsends and tapbacks restate the whole message', async () => {
		const { a, b, room, sockets, settle } = await world();
		const sent = (await say(a.as, room.id, 'teh plan')).body.message;
		await a.as('PATCH', `/v1/messages/${sent.id}`, { content: 'the plan' });
		await b.as('POST', `/v1/messages/${sent.id}/reactions`, { emoji: '👍' });
		await a.as('DELETE', `/v1/messages/${sent.id}`);
		await settle();
		const updates = sockets.b.frames.filter((f) => f.type === 'message_updated').map((f) => f.message);
		expect(updates.map((m) => [m.content, m.reactions.length, m.deleted_at === null])).toEqual([
			['the plan', 0, true],
			['the plan', 1, true],
			['', 0, false],
		]);
		expect(sockets.a.frames.filter((f) => f.type === 'message_updated')).toHaveLength(3);
		expect(typesOf(sockets.cy)).toEqual([]);
	});

	test('conversation changes arrive as each person’s own copy, to members only', async () => {
		const { a, b, room, sockets, settle } = await world();
		await say(a.as, room.id, 'one');
		await a.as('PATCH', `/v1/conversations/${room.id}`, { title: 'Launch 2' });
		await settle();
		const copy = (who: Connection) => who.frames.findLast((f) => f.type === 'conversation_updated')!.conversation;
		expect(copy(sockets.a)).toMatchObject({ id: room.id, title: 'Launch 2', unread_count: 0 });
		expect(copy(sockets.b)).toMatchObject({ id: room.id, title: 'Launch 2', unread_count: 1 });
		expect(typesOf(sockets.cy)).toEqual([]);
		expect(b.person.id).toBeDefined();
	});

	test('a new group appears for its members, and adding someone shows it to them too', async () => {
		const { a, b, cy, hq, sockets, settle } = await world();
		const made = (await a.as('POST', '/v1/conversations', { kind: 'group', title: 'Side', person_ids: [b.person.id] })).body
			.conversation;
		await settle();
		expect(sockets.a.frames.some((f) => f.type === 'conversation_updated' && f.conversation.id === made.id)).toBe(true);
		expect(sockets.b.frames.some((f) => f.type === 'conversation_updated' && f.conversation.id === made.id)).toBe(true);
		expect(typesOf(sockets.cy)).toEqual([]);
		await a.as('POST', `/v1/conversations/${made.id}/members`, { person_ids: [cy.person.id] });
		await settle();
		const joined = sockets.cy.frames.find((f) => f.type === 'conversation_updated')!.conversation;
		expect(joined.member_ids).toContain(cy.person.id);
		expect(hq.hub.conversations.isMember(made.id, cy.person.id)).toBe(true);
	});

	test('leaving removes the room for the leaver and updates the rest; deleting removes it for all', async () => {
		const { a, b, room, sockets, settle } = await world();
		await b.as('DELETE', `/v1/conversations/${room.id}/members/me`);
		await settle();
		expect(sockets.b.frames.filter((f) => f.type === 'conversation_removed')).toEqual([
			{ type: 'conversation_removed', conversation_id: room.id },
		]);
		expect(sockets.b.frames.some((f) => f.type === 'conversation_updated')).toBe(false);
		expect(sockets.a.frames.findLast((f) => f.type === 'conversation_updated')!.conversation.member_ids).not.toContain(
			b.person.id,
		);
		await say(a.as, room.id, 'after you left');
		await settle();
		expect(sockets.b.frames.some((f) => f.type === 'message')).toBe(false);
		await a.as('DELETE', `/v1/conversations/${room.id}`);
		await settle();
		expect(sockets.a.frames.filter((f) => f.type === 'conversation_removed')).toHaveLength(1);
		expect(typesOf(sockets.cy)).toEqual([]);
	});

	test('read receipts go to the room; reading what you had read says nothing', async () => {
		const { a, b, room, sockets, settle } = await world();
		const sent = (await say(a.as, room.id, 'one')).body.message;
		await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: sent.id });
		await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: sent.id });
		await settle();
		const reads = (who: Connection) => who.frames.filter((f) => f.type === 'read');
		expect(reads(sockets.a)).toEqual([
			{ type: 'read', conversation_id: room.id, person_id: b.person.id, last_read_message_id: sent.id },
		]);
		expect(reads(sockets.b)).toHaveLength(1);
		expect(reads(sockets.cy)).toEqual([]);
	});

	test('mark unread reaches only the person who did it', async () => {
		const { a, b, room, sockets, settle } = await world();
		await b.as('POST', `/v1/conversations/${room.id}/unread`);
		await say(a.as, room.id, 'one');
		await settle();
		const updated = sockets.b.frames.filter((f) => f.type === 'conversation_updated');
		expect(updated).toHaveLength(1);
		expect(sockets.a.frames.some((f) => f.type === 'conversation_updated')).toBe(false);
	});

	test('the assistant’s thinking state reaches the room as bot_state', async () => {
		const { hq, room, sockets, settle } = await world();
		hq.hub.bus.emit({ type: 'assistant.state', conversationId: room.id, personId: hq.assistant.self.id, label: 'Thinking' });
		hq.hub.bus.emit({ type: 'assistant.state', conversationId: room.id, personId: hq.assistant.self.id, label: null });
		await settle();
		const states = sockets.b.frames.filter((f) => f.type === 'bot_state');
		expect(states.map((s) => s.label)).toEqual(['Thinking', null]);
		expect(states[0]).toMatchObject({ conversation_id: room.id, person_id: hq.assistant.self.id });
		expect(Date.parse(states[0]!.expires_at)).toBeGreaterThan(Date.now());
		expect(typesOf(sockets.cy)).toEqual([]);
	});

	test('apps’ own change events are not sent to anyone', async () => {
		const { hq, sockets, settle } = await world();
		hq.hub.bus.emit({ type: 'app.event', app: 'tasks', name: 'changed', data: null });
		await settle();
		expect(typesOf(sockets.a)).toEqual([]);
	});

	test('later surfaces can send their own frames to chosen people', async () => {
		const { hq, b, sockets, settle } = await world();
		hq.socket.broadcast([b.person.id], { type: 'tasks', tasks: [] });
		await settle();
		expect(sockets.b.frames.at(-1)).toEqual({ type: 'tasks', tasks: [] });
		expect(typesOf(sockets.a)).toEqual([]);
	});
});

describe('typing', () => {
	test('is shared with the room for five seconds, the typist included, and not with outsiders', async () => {
		const { a, room, sockets, settle } = await world();
		const before = Date.now();
		sockets.a.send({ type: 'typing', conversation_id: room.id });
		sockets.cy.send({ type: 'typing', conversation_id: room.id });
		await settle();
		await sockets.a.settle();
		for (const who of [sockets.a, sockets.b]) {
			const typing = await who.take('typing');
			expect(typing).toMatchObject({ conversation_id: room.id, person_id: a.person.id });
			expect(Date.parse(typing.expires_at) - before).toBeGreaterThanOrEqual(4_900);
			expect(Date.parse(typing.expires_at) - Date.now()).toBeLessThanOrEqual(5_000);
		}
		expect(typesOf(sockets.cy)).toEqual([]);
		expect(sockets.b.frames.filter((f) => f.type === 'typing')).toHaveLength(1);
	});

	test('bad frames get an error and the socket stays up', async () => {
		const { room, sockets, settle } = await world();
		for (const bad of ['nope', '{"type":"fly"}', '{"type":"typing"}', '{"type":"sync","since_message_id":5}', 'null'])
			sockets.a.send(bad);
		sockets.a.send({ type: 'typing', conversation_id: room.id });
		await settle();
		expect(sockets.a.frames.filter((f) => f.type === 'error')).toEqual(Array(5).fill({ type: 'error', code: 'invalid_frame' }));
		expect(sockets.a.ws.readyState).toBe(WebSocket.OPEN);
		await sockets.a.take('typing');
	});
});

describe('presence', () => {
	test('a person is online with their first socket and offline after their last', async () => {
		const { a, b, hq, sockets, settle } = await world();
		await settle();
		expect(sockets.a.frames.filter((f) => f.type === 'presence' && f.person_id === b.person.id && f.is_online)).toHaveLength(1);
		const second = await track(connect(server!, b.bearer));
		await settle();
		expect(sockets.a.frames.filter((f) => f.type === 'presence' && f.person_id === b.person.id)).toHaveLength(1);
		second.ws.close();
		await second.closed;
		await settle();
		expect(sockets.a.frames.filter((f) => f.type === 'presence' && !f.is_online)).toEqual([]);
		sockets.b.ws.close();
		await sockets.b.closed;
		await sockets.a.settle();
		expect(sockets.a.frames.findLast((f) => f.type === 'presence')).toEqual({
			type: 'presence',
			person_id: b.person.id,
			is_online: false,
		});
		expect(a.person.id).not.toBe(b.person.id);
		expect(hq.hub.people.get(b.person.id)).not.toBeNull();
	});

	test('a new picture reaches everyone connected as person_updated', async () => {
		const { hq, a, sockets, settle } = await world();
		const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1]);
		await hq.fetch(
			new Request('http://hq.test/v1/me/avatar', {
				method: 'PUT',
				body: png,
				headers: { authorization: `Bearer ${a.bearer}`, 'content-type': 'image/png' },
			}),
		);
		await settle();
		for (const who of Object.values(sockets)) {
			const frame = await who.take('person_updated');
			expect(frame.person).toMatchObject({ id: a.person.id, kind: 'person' });
			expect(typeof frame.person.avatar_id).toBe('string');
		}
	});
});

describe('sync', () => {
	test('a socket that was away gets what it missed, oldest first, then sync_complete', async () => {
		const { hq, a, b, room, sockets, settle } = await world();
		const seen = (await say(a.as, room.id, 'seen')).body.message;
		await settle();
		sockets.b.ws.close();
		await sockets.b.closed;
		const missed = [await say(a.as, room.id, 'missed 1'), await say(a.as, hq.hub.general().id, 'missed 2')].map(
			(r) => r.body.message,
		);
		const back = await track(connect(server!, b.bearer));
		back.send({ type: 'sync', since_message_id: seen.id });
		await back.settle();
		expect(back.frames.filter((f) => f.type === 'sync_batch').flatMap((f) => f.messages)).toEqual(missed);
		expect(back.frames.at(-2)!.type).toBe('sync_batch');
		expect(back.frames.find((f) => f.type === 'sync_complete')).toEqual({ type: 'sync_complete', is_partial: false });
		expect(b.person.id).toBeDefined();
	});

	test('nothing missed still ends with sync_complete; no cursor replays from the start', async () => {
		let now = Date.now();
		const { a, room, sockets, settle } = await world({ socket: { clock: () => now } });
		const sent = (await say(a.as, room.id, 'one')).body.message;
		await settle();
		sockets.b.send({ type: 'sync', since_message_id: sent.id });
		await settle();
		expect(sockets.b.frames.at(-1)).toEqual({ type: 'sync_complete', is_partial: false });
		expect(sockets.b.frames.filter((f) => f.type === 'sync_batch')).toEqual([]);
		now += 2_000;
		sockets.b.send({ type: 'sync' });
		await settle();
		expect(
			sockets.b.frames.filter((f) => f.type === 'sync_batch').flatMap((f) => f.messages.map((m: { id: string }) => m.id)),
		).toContain(sent.id);
	});

	test('batches of 100, 500 at most, and is_partial says to ask again from the cursor', async () => {
		const { hq, ada, room, sockets, settle } = await world();
		const ids: string[] = [];
		for (let i = 0; i < 520; i++)
			ids.push(hq.hub.messages.send({ conversationId: room.id, authorId: ada.person.id, body: `m${i}` }).id);
		await settle();
		sockets.b.frames.length = 0;
		sockets.b.send({ type: 'sync', since_message_id: '' });
		await settle();
		const batches = sockets.b.frames.filter((f) => f.type === 'sync_batch');
		expect(batches.map((f) => f.messages.length)).toEqual([100, 100, 100, 100, 100]);
		expect(sockets.b.frames.at(-1)).toEqual({ type: 'sync_complete', is_partial: true });
		const last = batches.at(-1)!.messages.at(-1).id;
		sockets.b.frames.length = 0;
		sockets.b.send({ type: 'sync', since_message_id: last });
		await settle();
		const rest = sockets.b.frames
			.filter((f) => f.type === 'sync_batch')
			.flatMap((f) => f.messages.map((m: { id: string }) => m.id));
		expect(rest.length).toBeLessThan(500);
		expect(rest.at(-1)).toBe(ids.at(-1)!);
		expect(sockets.b.frames.at(-1)).toEqual({ type: 'sync_complete', is_partial: false });
	});

	test('one person’s replays share a budget of 2,000 messages per 10 s across all their sockets', async () => {
		let now = 1_000_000;
		const { hq, ada, a, b, room } = await pair({ socket: { clock: () => now } });
		server = serve(hq);
		for (let i = 0; i < 520; i++) hq.hub.messages.send({ conversationId: room.id, authorId: ada.person.id, body: `m${i}` });
		const replayed = (who: Connection) => who.frames.filter((f) => f.type === 'sync_batch').flatMap((f) => f.messages).length;
		const phones = await Promise.all(Array.from({ length: 6 }, () => track(connect(server!, b.bearer))));
		const mac = await track(connect(server!, a.bearer));

		// Each socket is inside its own pace, but together four full replays are all the 10 seconds allow.
		for (const phone of phones.slice(0, 4)) {
			phone.send({ type: 'sync' });
			expect(await phone.take('sync_complete')).toEqual({ type: 'sync_complete', is_partial: true });
		}
		expect(phones.slice(0, 4).map(replayed)).toEqual([500, 500, 500, 500]);
		// The next one is answered the way a throttled sync is: no data, partial, so the app does not wait or loop.
		phones[4]!.send({ type: 'sync' });
		expect(await phones[4]!.take('sync_complete')).toEqual({ type: 'sync_complete', is_partial: true });
		expect(replayed(phones[4]!)).toBe(0);
		// The next page of a replay that stopped short counts too.
		phones[0]!.send({
			type: 'sync',
			since_message_id: phones[0]!.frames
				.filter((f) => f.type === 'sync_batch')
				.at(-1)!
				.messages.at(-1).id,
		});
		expect(await phones[0]!.take('sync_complete', (f) => f.is_partial === true)).toBeDefined();
		expect(replayed(phones[0]!)).toBe(500);
		// Someone else's budget is their own, and this one is whole again after the window.
		mac.send({ type: 'sync' });
		await mac.take('sync_complete');
		expect(replayed(mac)).toBeGreaterThan(0);
		now += 10_001;
		phones[5]!.send({ type: 'sync' });
		await phones[5]!.take('sync_complete');
		expect(replayed(phones[5]!)).toBe(500);
	});

	test('replays only conversations you are in, and never an archived one', async () => {
		const { hq, ada, a, room, sockets, settle } = await world();
		const secret = hq.hub.conversations.createRoom({ title: 'Secret', createdBy: ada.person.id });
		hq.hub.messages.send({ conversationId: secret.id, authorId: ada.person.id, body: 'secret' });
		await say(a.as, room.id, 'for the room');
		const old = hq.hub.conversations.createRoom({
			title: 'Old',
			createdBy: ada.person.id,
			memberIds: [sockets.b.frames[0]!.person_id],
		});
		hq.hub.messages.send({ conversationId: old.id, authorId: ada.person.id, body: 'from the archive' });
		hq.hub.conversations.archive(old.id);
		await settle();
		sockets.b.send({ type: 'sync' });
		sockets.cy.send({ type: 'sync' });
		await settle();
		const bodies = (who: Connection) =>
			who.frames.filter((f) => f.type === 'sync_batch').flatMap((f) => f.messages.map((m: { content: string }) => m.content));
		expect(bodies(sockets.b)).toEqual(['for the room']);
		expect(bodies(sockets.cy)).toEqual([]);
	});
});

describe('keeping sockets honest', () => {
	test('a socket silent for 75 seconds is closed; anything it sends keeps it', async () => {
		let now = 1_000_000;
		const { hq, a, b } = await pair({ socket: { clock: () => now } });
		server = serve(hq);
		const quiet = await track(connect(server, a.bearer));
		const chatty = await track(connect(server, b.bearer));
		now += 74_000;
		chatty.send('ping');
		await chatty.settle();
		hq.socket.sweep();
		now += 2_000;
		hq.socket.sweep();
		expect(await quiet.closed).toBe(4002);
		expect(chatty.ws.readyState).toBe(WebSocket.OPEN);
		now += 74_000;
		hq.socket.sweep();
		expect(chatty.ws.readyState).toBe(WebSocket.OPEN);
	});

	test('a device that reconnects replaces its own silent older socket, not a live one or another device’s', async () => {
		let now = 1_000_000;
		const { hq, a } = await pair({ socket: { clock: () => now } });
		server = serve(hq);
		const laptop = await enrolled(hq, hq.hub.keys.mint(a.person.id, 'setup').secret, 'Laptop');
		const phone = await track(connect(server, a.bearer));
		const otherDevice = await track(connect(server, laptop.bearer));
		now += 40_000;
		const live = await track(connect(server, a.bearer));
		live.send('ping');
		await live.settle();
		const stale = await track(connect(server, a.bearer));
		now += 20_000;
		live.send('ping');
		await live.settle();
		const replacement = await track(connect(server, a.bearer));
		expect(await phone.closed).toBe(4000);
		expect(otherDevice.ws.readyState).toBe(WebSocket.OPEN);
		expect(live.ws.readyState).toBe(WebSocket.OPEN);
		expect(stale.ws.readyState).toBe(WebSocket.OPEN);
		expect(replacement.frames[0]).toMatchObject({ device_id: a.deviceId });
	});

	test('revoking a device closes its sockets, whoever revokes it', async () => {
		const { hq, a, b } = await pair();
		server = serve(hq);
		const phone = await enrolled(hq, hq.hub.keys.mint(a.person.id, 'setup').secret, 'Phone');
		const onPhone = await track(connect(server, phone.bearer));
		const onMac = await track(connect(server, a.bearer));
		await phone.as('POST', `/v1/devices/${phone.deviceId}/revoke`);
		expect(await onPhone.closed).toBe(4001);
		expect(onMac.ws.readyState).toBe(WebSocket.OPEN);
		expect(b.deviceId).toBeDefined();
	});

	test('a device revoked by another process is closed on its next ping, or before its next frame', async () => {
		const { hq, ada, a, b, room } = await pair();
		server = serve(hq);
		const revoke = (deviceId: string) =>
			hq.hub.db
				.query('UPDATE api_keys SET revoked_at = 1 WHERE id = (SELECT key_id FROM devices WHERE id = $id)')
				.run({ id: deviceId });
		const pinging = await track(connect(server, a.bearer));
		const listening = await track(connect(server, b.bearer));
		revoke(a.deviceId);
		pinging.send('ping');
		expect(await pinging.closed).toBe(4001);
		revoke(b.deviceId);
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.person.id, body: 'after revoke' });
		expect(await listening.closed).toBe(4001);
		expect(listening.frames.filter((f) => f.type === 'message')).toEqual([]);
	});
});
