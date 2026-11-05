import { afterEach, describe, expect, test } from 'bun:test';
import type { Server } from 'bun';
import type { SocketData } from '../src/realtime/socket';
import { connect, enrolled, pair, say, serve, type Connection } from './helpers';
import { baseFrames, extraFrames, wire as fixture } from './wire-fixture';

// What the native app's Swift structs decode, as keys. A key the server sends that the app does not
// read, or a key the app needs that the server leaves out, fails here before it fails on a phone.
const { structs, ignored } = fixture;

const seen = new Set<string>();
const problems: string[] = [];

function check(name: string, value: unknown, path: string): void {
	seen.add(name);
	if (typeof value !== 'object' || value === null || Array.isArray(value)) {
		problems.push(`${path}: expected an object for ${name}`);
		return;
	}
	const spec = structs[name]!;
	const object = value as Record<string, unknown>;
	for (const key of Object.keys(object)) {
		if (key !== 'type' && !(key in spec) && !(ignored[name] ?? []).includes(key))
			problems.push(`${path}.${key}: the app does not decode this`);
	}
	for (const [key, field] of Object.entries(spec)) {
		const present = object[key];
		if (present === undefined) {
			if (field.required) problems.push(`${path}.${key}: the app requires this`);
			continue;
		}
		if (present === null) {
			if (field.required) problems.push(`${path}.${key}: null where the app requires a value`);
			continue;
		}
		if (key.endsWith('_at') && Number.isNaN(Date.parse(String(present)))) problems.push(`${path}.${key}: not an ISO time`);
		if (field.of === undefined) continue;
		if (field.list) {
			if (!Array.isArray(present)) problems.push(`${path}.${key}: expected a list`);
			else present.forEach((item, i) => check(field.of!, item, `${path}.${key}[${i}]`));
		} else check(field.of, present, `${path}.${key}`);
	}
}

let server: Server<SocketData> | undefined;
let open: Connection[] = [];
afterEach(() => {
	for (const connection of open) connection.ws.close();
	open = [];
	void server?.stop(true);
});

describe('what the server sends is what the app decodes', () => {
	test('the enroll response, people, conversations, messages and every frame', async () => {
		const { hq, ada, a, b, room } = await pair();
		server = serve(hq);
		const enroll = await (await hq.fetch(
			new Request('http://hq.test/v1/enroll', {
				method: 'POST',
				body: JSON.stringify({ key: hq.hub.keys.mint(ada.person.id, 'setup').secret, device_name: 'Mac' }),
			}),
		))!.json();
		check('EnrollResponse', enroll, 'enroll');

		const left = await connect(server, a.bearer);
		const right = await connect(server, b.bearer);
		open.push(left, right);

		// A message with a quote, a file, a tapback, an edit, and one that was unsent.
		const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
		const upload = await hq.fetch(
			new Request(`http://hq.test/v1/conversations/${room.id}/attachments`, {
				method: 'POST',
				body: png,
				headers: {
					authorization: `Bearer ${a.bearer}`,
					'content-type': 'image/png',
					'x-hq-file-name': 'a.png',
					'x-hq-image-width': '3',
					'x-hq-image-height': '2',
				},
			}),
		);
		const { attachment } = await upload!.json();
		const first = (await say(a.as, room.id, 'look', { attachment_ids: [attachment.id] })).body.message;
		const quoted = (await say(b.as, room.id, 'nice', { reply_to_message_id: first.id })).body.message;
		await b.as('POST', `/v1/messages/${first.id}/reactions`, { emoji: '👍' });
		await a.as('PATCH', `/v1/messages/${first.id}`, { content: 'look!' });
		const gone = (await say(a.as, room.id, 'oops')).body.message;
		await a.as('DELETE', `/v1/messages/${gone.id}`);
		await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: quoted.id });
		await a.as('PATCH', `/v1/conversations/${room.id}`, { title: 'Launch 2' });
		left.send({ type: 'typing', conversation_id: room.id });
		hq.hub.bus.emit({ type: 'assistant.state', conversationId: room.id, personId: hq.assistant.self.id, label: 'Thinking' });
		await hq.fetch(
			new Request('http://hq.test/v1/me/avatar', {
				method: 'PUT',
				body: png,
				headers: { authorization: `Bearer ${a.bearer}`, 'content-type': 'image/png' },
			}),
		);
		right.send({ type: 'sync' });
		right.send('garbage');
		await left.settle();
		await right.settle();
		const dm = (await a.as('POST', '/v1/conversations', { kind: 'dm', person_id: b.person.id })).body.conversation;
		await a.as('DELETE', `/v1/conversations/${room.id}`);
		await left.settle();
		await right.settle();
		await enrolled(hq, ada.key);

		for (const route of ['/v1/me', '/v1/people', '/v1/conversations', `/v1/conversations/${dm.id}`, `/v1/search?q=look`]) {
			const body = (await a.as('GET', route)).body;
			if (body.person) check('Person', body.person, route);
			for (const person of body.people ?? []) check('Person', person, route);
			for (const conversation of body.conversations ?? []) check('Conversation', conversation, route);
			if (body.conversation) check('Conversation', body.conversation, route);
			for (const message of body.messages ?? []) check('Message', message, route);
		}
		const page = (await b.as('GET', `/v1/conversations/${dm.id}/messages`)).body;
		expect(page.messages).toEqual([]);
		for (const reply of [first, quoted, gone]) check('Message', reply, 'send');

		const frames = [...left.frames, ...right.frames];
		for (const frame of frames) {
			const payload = fixture.frames[frame.type];
			if (payload === undefined) problems.push(`frame ${frame.type}: the app has no decoder for this`);
			else check(payload, frame, `frame ${frame.type}`);
		}
		expect(problems).toEqual([]);

		// Everything the app decodes was actually exercised, nested pieces included: exactly the frames of swift-wire.json. A
		// feature's own frames (its own fixture files) are sent by its own tests, which unsentFrames checks.
		const emitted = new Set(frames.map((f) => f.type).filter((type) => !extraFrames.has(type)));
		expect([...emitted].sort()).toEqual([...baseFrames].sort());
		for (const name of [
			'Person',
			'Conversation',
			'Message',
			'Attachment',
			'Reaction',
			'ReplyStub',
			'EditRevision',
			'ReadMark',
			'EnrollResponse',
		]) {
			expect(seen.has(name)).toBe(true);
		}
	});
});
