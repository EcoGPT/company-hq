import { describe, expect, setSystemTime, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { defineAssistant } from '../src/assistant/define';
import { CONVERSATION_MIGRATIONS, Conversations } from '../src/core/conversations';
import { KEY_MIGRATIONS, Keys } from '../src/core/keys';
import { MESSAGE_MIGRATIONS } from '../src/core/messages';
import { People, PEOPLE_MIGRATIONS } from '../src/core/people';
import { migrate, openDatabase } from '../src/db/database';
import { newId } from '../src/core/ids';
import { createHq, normalizePublicUrl } from '../src/hq';
import { scripted } from '../src/llm';
import { admin, client, enrolled, pair, say } from './helpers';

const gone = { status: 404, body: { error: 'not_found' } };

describe('people', () => {
	test('the roster marks the assistant as a bot, and carries who is an admin', async () => {
		const { hq, a, bo } = await pair();
		hq.hub.people.create({ name: 'CI', handle: 'ci', kind: 'service' });
		const { people } = (await a.as('GET', '/v1/people')).body;
		const byName = Object.fromEntries(people.map((p: { name: string }) => [p.name, p]));
		expect(byName.Assistant).toMatchObject({ kind: 'bot', is_admin: false });
		expect(byName.Ada).toMatchObject({ kind: 'person', is_admin: true });
		expect(byName.Bo).toMatchObject({ id: bo.id, kind: 'person', is_admin: false, avatar_id: null, removed_at: null });
		expect(byName.CI.kind).toBe('service');
		expect(JSON.stringify(people)).not.toContain('handle');
	});

	test('an admin adds a person, who lands in General', async () => {
		const hq = createHq();
		const asAda = (await enrolled(hq, admin(hq).key)).as;
		const added = await asAda('POST', '/v1/people', { name: 'Cy', handle: 'cy' });
		expect(added.status).toBe(200);
		const cy = await enrolled(hq, added.body.key);
		const listed = (await cy.as('GET', '/v1/conversations')).body.conversations;
		expect(listed.map((c: { room_slug: string }) => c.room_slug)).toEqual(['general']);
		expect((await cy.as('POST', '/v1/people', { name: 'X', handle: 'x' })).status).toBe(403);
		expect((await asAda('POST', '/v1/people', { name: 'Space', handle: 'has space' })).status).toBe(400);
	});
});

describe('conversations', () => {
	test('General is a standing group; a made group and a DM have the app’s shapes', async () => {
		const { a, b, bo, ada, room } = await pair();
		const listed = (await a.as('GET', '/v1/conversations')).body.conversations;
		expect(listed.find((c: { room_slug: string | null }) => c.room_slug === 'general')).toMatchObject({
			kind: 'group',
			title: 'General',
			unread_count: 0,
			read_marks: [],
			avatar_id: null,
		});
		expect(room).toMatchObject({ kind: 'group', title: 'Launch', room_slug: null, last_message: null });
		expect(room.member_ids).toEqual(expect.arrayContaining([ada.person.id, bo.id]));

		const dm = await a.as('POST', '/v1/conversations', { kind: 'dm', person_id: b.person.id });
		expect(dm.status).toBe(201);
		expect(dm.body.conversation).toMatchObject({ kind: 'dm', title: null, room_slug: null });
		expect(dm.body.conversation.member_ids.sort()).toEqual([ada.person.id, bo.id].sort());
		const again = await b.as('POST', '/v1/conversations', { kind: 'dm', person_id: a.person.id });
		expect(again.status).toBe(200);
		expect(again.body.conversation.id).toBe(dm.body.conversation.id);
		expect((await a.as('GET', `/v1/conversations/${room.id}`)).body).toEqual({ conversation: room });
	});

	test('the list runs by last activity, newest first', async () => {
		const { a, b, room } = await pair();
		const later = (await a.as('POST', '/v1/conversations', { kind: 'group', title: 'Later', person_ids: [b.person.id] })).body
			.conversation;
		const order = async () => (await a.as('GET', '/v1/conversations')).body.conversations.map((c: { id: string }) => c.id);
		expect((await order()).slice(0, 2)).toEqual([later.id, room.id]);
		await say(b.as, room.id, 'bump');
		expect((await order())[0]).toBe(room.id);
	});

	test('a message in the same millisecond as a newer chat still puts its chat first', async () => {
		setSystemTime(new Date('2026-01-01T00:00:00Z'));
		try {
			const { a, b, room } = await pair();
			const later = (await a.as('POST', '/v1/conversations', { kind: 'group', title: 'Later', person_ids: [b.person.id] })).body
				.conversation;
			const order = async () => (await a.as('GET', '/v1/conversations')).body.conversations.map((c: { id: string }) => c.id);
			expect((await order()).slice(0, 2)).toEqual([later.id, room.id]);
			await say(b.as, room.id, 'bump');
			expect((await order()).slice(0, 2)).toEqual([room.id, later.id]);
		} finally {
			setSystemTime();
		}
	});

	test('the list and the single read agree for each person', async () => {
		const { a, b, room } = await pair();
		await say(a.as, room.id, 'hi');
		for (const person of [a, b]) {
			const listed = (await person.as('GET', '/v1/conversations')).body.conversations;
			for (const conversation of listed) {
				expect((await person.as('GET', `/v1/conversations/${conversation.id}`)).body.conversation).toEqual(conversation);
			}
		}
	});

	test('a group needs people that exist, and a title is optional', async () => {
		const { a, b } = await pair();
		const unnamed = await a.as('POST', '/v1/conversations', { kind: 'group', person_ids: [b.person.id] });
		expect(unnamed.status).toBe(201);
		expect(unnamed.body.conversation.title).toBeNull();
		for (const body of [
			{ kind: 'group', person_ids: ['nobody'] },
			{ kind: 'dm', person_id: 'nobody' },
		]) {
			expect(await a.as('POST', '/v1/conversations', body)).toEqual({ status: 404, body: { error: 'person_not_found' } });
		}
		for (const body of [
			{},
			{ kind: 'group' },
			{ kind: 'group', person_ids: [] },
			{ kind: 'group', person_ids: [b.person.id], title: 'x'.repeat(121) },
		]) {
			expect(await a.as('POST', '/v1/conversations', body)).toEqual({ status: 400, body: { error: 'invalid_body' } });
		}
	});

	test('rename, clear the name, add people', async () => {
		const { hq, a, b, room } = await pair();
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const renamed = await a.as('PATCH', `/v1/conversations/${room.id}`, { title: '  Launch v2  ' });
		expect(renamed.body.conversation.title).toBe('Launch v2');
		expect((await b.as('PATCH', `/v1/conversations/${room.id}`, { title: null })).body.conversation.title).toBeNull();
		const added = await a.as('POST', `/v1/conversations/${room.id}/members`, { person_ids: [cy.id] });
		expect(added.body.conversation.member_ids).toContain(cy.id);
		expect((await a.as('POST', `/v1/conversations/${room.id}/members`, { person_ids: ['nobody'] })).status).toBe(404);
		expect((await a.as('PATCH', `/v1/conversations/${room.id}`, { title: 5 })).status).toBe(400);
	});

	test('a DM is not a group, and General is standing: neither can be renamed, left or deleted', async () => {
		const { hq, a, b } = await pair();
		const dm = (await a.as('POST', '/v1/conversations', { kind: 'dm', person_id: b.person.id })).body.conversation;
		for (const route of [
			['PATCH', `/v1/conversations/${dm.id}`, { title: 'x' }],
			['DELETE', `/v1/conversations/${dm.id}`],
			['DELETE', `/v1/conversations/${dm.id}/members/me`],
			['POST', `/v1/conversations/${dm.id}/members`, { person_ids: [b.person.id] }],
		] as const) {
			expect(await a.as(route[0], route[1], route[2])).toEqual({ status: 409, body: { error: 'not_a_group' } });
		}
		const general = hq.hub.general().id;
		for (const route of [
			['PATCH', `/v1/conversations/${general}`, { title: 'x' }],
			['DELETE', `/v1/conversations/${general}`],
			['DELETE', `/v1/conversations/${general}/members/me`],
		] as const) {
			expect(await a.as(route[0], route[1], route[2])).toEqual({ status: 409, body: { error: 'standing_room' } });
		}
		expect(hq.hub.conversations.get(general)?.title).toBe('General');
	});

	test('leaving takes you out; deleting closes the room for everyone', async () => {
		const { hq, a, b, room } = await pair();
		expect(await b.as('DELETE', `/v1/conversations/${room.id}/members/me`)).toEqual({ status: 200, body: { ok: true } });
		expect(await b.as('GET', `/v1/conversations/${room.id}`)).toEqual(gone);
		expect((await b.as('GET', '/v1/conversations')).body.conversations.map((c: { id: string }) => c.id)).not.toContain(room.id);
		expect((await a.as('GET', `/v1/conversations/${room.id}`)).body.conversation.member_ids).not.toContain(b.person.id);

		expect(await a.as('DELETE', `/v1/conversations/${room.id}`)).toEqual({ status: 200, body: { ok: true } });
		expect(await a.as('GET', `/v1/conversations/${room.id}`)).toEqual(gone);
		expect(hq.hub.conversations.get(room.id)?.archived_at).not.toBeNull();
		expect(hq.hub.messages.list(room.id)).toEqual([]);
	});
});

describe('messages', () => {
	test('send answers 201 with the message the app decodes, newest page oldest-first', async () => {
		const { a, b, room } = await pair();
		const sent = await say(a.as, room.id, 'ship it');
		expect(sent.status).toBe(201);
		expect(sent.body.message).toMatchObject({
			conversation_id: room.id,
			sender_person_id: a.person.id,
			sender_name: 'Ada',
			content: 'ship it',
			edited_at: null,
			deleted_at: null,
			reactions: [],
			attachments: [],
			edit_history: [],
			reply_to: null,
		});
		expect(sent.body.message.created_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
		const second = await say(b.as, room.id, 'on it');
		const page = (await a.as('GET', `/v1/conversations/${room.id}/messages?limit=50`)).body.messages;
		expect(page.map((m: { id: string }) => m.id)).toEqual([sent.body.message.id, second.body.message.id]);
	});

	test('a retry with the same client id is the same message; reusing it elsewhere is refused', async () => {
		const { hq, a, b, room } = await pair();
		const clientMsgId = crypto.randomUUID();
		const first = await a.as('POST', `/v1/conversations/${room.id}/messages`, { client_msg_id: clientMsgId, content: 'once' });
		const retry = await a.as('POST', `/v1/conversations/${room.id}/messages`, { client_msg_id: clientMsgId, content: 'once' });
		expect([first.status, retry.status]).toEqual([201, 200]);
		expect(retry.body.message.id).toBe(first.body.message.id);
		expect(hq.hub.messages.list(room.id)).toHaveLength(1);
		const other = hq.hub.general().id;
		const reused = await a.as('POST', `/v1/conversations/${other}/messages`, { client_msg_id: clientMsgId, content: 'once' });
		expect(reused).toEqual({ status: 409, body: { error: 'client_msg_id_reused' } });
		// Another person using the same id is a different send.
		expect(
			(await b.as('POST', `/v1/conversations/${room.id}/messages`, { client_msg_id: clientMsgId, content: 'mine' })).status,
		).toBe(201);
	});

	test('bad sends: empty, too long, no client id', async () => {
		const { a, room } = await pair();
		const post = (body: unknown) => a.as('POST', `/v1/conversations/${room.id}/messages`, body);
		const id = crypto.randomUUID();
		expect(await post({ client_msg_id: id, content: '   ' })).toEqual({ status: 400, body: { error: 'empty_message' } });
		expect((await post({ client_msg_id: id, content: 'x'.repeat(16_385) })).body).toEqual({ error: 'invalid_body' });
		expect((await post({ client_msg_id: id, content: 'é'.repeat(8_193) })).body).toEqual({ error: 'invalid_body' });
		expect((await post({ client_msg_id: 'not-a-uuid', content: 'hi' })).body).toEqual({ error: 'invalid_body' });
		expect((await post({ content: 'hi' })).body).toEqual({ error: 'invalid_body' });
		expect((await post({ client_msg_id: id, content: 'x'.repeat(16_384) })).status).toBe(201);
	});

	test('a reply carries a quote of its target, and only from the same conversation', async () => {
		const { hq, a, b, room } = await pair();
		const target = (await say(a.as, room.id, 'the plan')).body.message;
		const reply = (await say(b.as, room.id, 'agreed', { reply_to_message_id: target.id })).body.message;
		expect(reply.reply_to).toEqual({ id: target.id, content: 'the plan', sender_name: 'Ada' });
		const elsewhere = (await say(b.as, hq.hub.general().id, 'hm', { reply_to_message_id: target.id })).body.message;
		expect(elsewhere.reply_to).toBeNull();
	});

	test('pages: newest, before a message, after a message, limits', async () => {
		const { hq, a, room } = await pair();
		const ids: string[] = [];
		for (let i = 1; i <= 7; i++) ids.push((await say(a.as, room.id, `m${i}`)).body.message.id);
		const get = async (query: string) =>
			(await a.as('GET', `/v1/conversations/${room.id}/messages?${query}`)).body.messages.map(
				(m: { content: string }) => m.content,
			);
		expect(await get('limit=3')).toEqual(['m5', 'm6', 'm7']);
		expect(await get(`limit=3&before=${ids[4]}`)).toEqual(['m2', 'm3', 'm4']);
		expect(await get(`limit=50&before=${ids[1]}`)).toEqual(['m1']);
		expect(await get(`limit=50&before=${ids[0]}`)).toEqual([]);
		expect(await get(`limit=2&after=${ids[2]}`)).toEqual(['m4', 'm5']);
		expect(await get('')).toHaveLength(7);
		for (const limit of ['1.5', 'x', '0', '-4']) expect((await get(`limit=${limit}`)).length).toBeGreaterThan(0);
		for (let i = 8; i <= 130; i++) hq.hub.messages.send({ conversationId: room.id, authorId: a.person.id, body: `m${i}` });
		expect(await get('limit=1000')).toHaveLength(100);
	});

	test('search needs two characters and finds only what you can read', async () => {
		const { hq, a, b, room } = await pair();
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const secret = hq.hub.conversations.createRoom({ title: 'Secret', createdBy: cy.id });
		hq.hub.messages.send({ conversationId: secret.id, authorId: cy.id, body: 'ship the secret' });
		await say(a.as, room.id, 'ship it');
		expect((await b.as('GET', '/v1/search?q=ship')).body.messages.map((m: { content: string }) => m.content)).toEqual([
			'ship it',
		]);
		expect((await b.as('GET', '/v1/search?q=s')).body).toEqual({ messages: [] });
		expect((await b.as('GET', '/v1/search?q=sh')).body.messages).toHaveLength(1);
	});
});

describe('edit, unsend and tapbacks', () => {
	test('the author edits; the old text stays in the history', async () => {
		const { a, b, room } = await pair();
		const sent = (await say(a.as, room.id, 'teh plan')).body.message;
		const edited = await a.as('PATCH', `/v1/messages/${sent.id}`, { content: 'the plan' });
		expect(edited.status).toBe(200);
		expect(edited.body.message).toMatchObject({ id: sent.id, content: 'the plan' });
		expect(edited.body.message.edited_at).not.toBeNull();
		expect(edited.body.message.edit_history).toEqual([{ content: 'teh plan', edited_at: edited.body.message.edited_at }]);
		expect(await b.as('PATCH', `/v1/messages/${sent.id}`, { content: 'mine now' })).toEqual({
			status: 403,
			body: { error: 'forbidden' },
		});
		expect((await a.as('PATCH', `/v1/messages/${sent.id}`, { content: '' })).status).toBe(400);
	});

	test('unsend blanks the message for everyone and takes its tapbacks and files along', async () => {
		const { hq, a, b, room } = await pair();
		const sent = (await say(a.as, room.id, 'oops')).body.message;
		await b.as('POST', `/v1/messages/${sent.id}/reactions`, { emoji: '👍' });
		const unsent = await a.as('DELETE', `/v1/messages/${sent.id}`);
		expect(unsent.body.message).toMatchObject({ id: sent.id, content: '', reactions: [], attachments: [], edit_history: [] });
		expect(unsent.body.message.deleted_at).not.toBeNull();
		expect(await b.as('DELETE', `/v1/messages/${sent.id}`)).toEqual({ status: 403, body: { error: 'forbidden' } });
		expect(await a.as('PATCH', `/v1/messages/${sent.id}`, { content: 'back' })).toEqual({
			status: 409,
			body: { error: 'message_deleted' },
		});
		expect(await b.as('POST', `/v1/messages/${sent.id}/reactions`, { emoji: '👍' })).toEqual({
			status: 409,
			body: { error: 'message_deleted' },
		});
		const page = (await b.as('GET', `/v1/conversations/${room.id}/messages`)).body.messages;
		expect(page[0]).toMatchObject({ content: '', reactions: [] });
		expect(hq.hub.messages.get(sent.id)?.body).toBe('');
		expect((await b.as('GET', '/v1/search?q=oops')).body).toEqual({ messages: [] });
		// The text is kept, not destroyed, but nothing hands it out.
		expect(hq.hub.db.query<{ body: string }, []>('SELECT body FROM messages').get()?.body).toBe('oops');
	});

	test('a tapback toggles, groups by emoji, and is open to any member', async () => {
		const { a, b, room } = await pair();
		const sent = (await say(a.as, room.id, 'nice')).body.message;
		const tap = (who: typeof a, emoji: string) => who.as('POST', `/v1/messages/${sent.id}/reactions`, { emoji });
		await tap(b, '👍');
		const both = await tap(a, '👍');
		expect(both.body.message.reactions).toEqual([{ emoji: '👍', person_ids: [b.person.id, a.person.id] }]);
		await tap(a, '❤️');
		expect((await tap(b, '👍')).body.message.reactions).toEqual([
			{ emoji: '👍', person_ids: [a.person.id] },
			{ emoji: '❤️', person_ids: [a.person.id] },
		]);
		expect((await tap(a, '')).status).toBe(400);
		expect((await tap(a, '123456789')).status).toBe(400);
	});
});

describe('read state', () => {
	test('reading moves forward only and answers where it stands', async () => {
		const { a, b, room } = await pair();
		const first = (await say(a.as, room.id, 'one')).body.message.id;
		const second = (await say(a.as, room.id, 'two')).body.message.id;
		const unread = async () => (await b.as('GET', `/v1/conversations/${room.id}`)).body.conversation;
		expect((await unread()).unread_count).toBe(2);
		expect(await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: first })).toEqual({
			status: 200,
			body: { last_read_message_id: first },
		});
		expect((await unread()).unread_count).toBe(1);
		await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: second });
		expect((await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: first })).body).toEqual({
			last_read_message_id: second,
		});
		expect(await unread()).toMatchObject({
			unread_count: 0,
			read_marks: [{ person_id: b.person.id, last_read_message_id: second }],
		});
		// Your own messages are never unread to you.
		expect((await a.as('GET', `/v1/conversations/${room.id}`)).body.conversation.unread_count).toBe(0);
	});

	test('a message from another conversation cannot be the read position', async () => {
		const { hq, a, b, room } = await pair();
		const elsewhere = (await say(a.as, hq.hub.general().id, 'general')).body.message.id;
		expect(await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: elsewhere })).toEqual(gone);
		expect(await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: 'nope' })).toEqual(gone);
		expect((await b.as('POST', `/v1/conversations/${room.id}/read`, {})).status).toBe(400);
	});

	test('mark unread is private to you and shows as one unread', async () => {
		const { a, b, room } = await pair();
		const only = (await say(a.as, room.id, 'one')).body.message.id;
		await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: only });
		const marked = await b.as('POST', `/v1/conversations/${room.id}/unread`);
		expect(marked.body.conversation.unread_count).toBe(1);
		expect(marked.body.conversation.read_marks).toEqual([{ person_id: b.person.id, last_read_message_id: only }]);
		await b.as('POST', `/v1/conversations/${room.id}/read`, { message_id: only });
		expect((await b.as('GET', `/v1/conversations/${room.id}`)).body.conversation.unread_count).toBe(0);
	});

	test('an unsent message stops counting as unread', async () => {
		const { a, b, room } = await pair();
		const sent = (await say(a.as, room.id, 'oops')).body.message.id;
		expect((await b.as('GET', `/v1/conversations/${room.id}`)).body.conversation.unread_count).toBe(1);
		await a.as('DELETE', `/v1/messages/${sent}`);
		expect((await b.as('GET', `/v1/conversations/${room.id}`)).body.conversation.unread_count).toBe(0);
	});
});

describe('who may touch what', () => {
	test('someone outside a room gets 404 from every route that names it or its messages', async () => {
		const { hq, a, room } = await pair();
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const outsider = await enrolled(hq, hq.hub.keys.mint(cy.id).secret);
		const sent = (await say(a.as, room.id, 'private')).body.message;
		const routes = [
			['GET', `/v1/conversations/${room.id}`],
			['PATCH', `/v1/conversations/${room.id}`, { title: 'mine' }],
			['DELETE', `/v1/conversations/${room.id}`],
			['POST', `/v1/conversations/${room.id}/members`, { person_ids: [cy.id] }],
			['DELETE', `/v1/conversations/${room.id}/members/me`],
			['GET', `/v1/conversations/${room.id}/messages`],
			['POST', `/v1/conversations/${room.id}/messages`, { client_msg_id: crypto.randomUUID(), content: 'hi' }],
			['POST', `/v1/conversations/${room.id}/read`, { message_id: sent.id }],
			['POST', `/v1/conversations/${room.id}/unread`],
			['PUT', `/v1/conversations/${room.id}/image`],
			['DELETE', `/v1/conversations/${room.id}/image`],
			['POST', `/v1/conversations/${room.id}/attachments`],
			['PATCH', `/v1/messages/${sent.id}`, { content: 'mine' }],
			['DELETE', `/v1/messages/${sent.id}`],
			['POST', `/v1/messages/${sent.id}/reactions`, { emoji: '👍' }],
		] as const;
		for (const [method, path, body] of routes)
			expect([method, path, await outsider.as(method, path, body)]).toEqual([method, path, gone]);
		expect(hq.hub.conversations.memberIds(room.id)).not.toContain(cy.id);
		expect(hq.hub.messages.list(room.id).map((m) => m.body)).toEqual(['private']);
		expect(hq.hub.messages.get(sent.id)).toMatchObject({ body: 'private', edited_at: null, deleted_at: null });
	});

	test('every route wants a bearer; the key in the query string does not count', async () => {
		const { hq, ada, a, room } = await pair();
		const anon = client(hq);
		const sent = (await say(a.as, room.id, 'hi')).body.message;
		const routes = [
			['GET', '/v1/me'],
			['GET', '/v1/people'],
			['GET', '/v1/conversations'],
			['POST', '/v1/conversations', {}],
			['GET', `/v1/conversations/${room.id}/messages`],
			['PATCH', `/v1/messages/${sent.id}`, {}],
			['GET', '/v1/search?q=hi'],
			['GET', '/v1/avatars/people/x/y'],
			['GET', '/v1/attachments/x'],
			['PUT', '/v1/me/avatar'],
			['POST', '/v1/devices/x/revoke'],
		] as const;
		for (const [method, path, body] of routes) {
			expect([path, (await anon(method, path, body)).status]).toEqual([path, 401]);
		}
		expect((await anon('GET', `/v1/me?token=${ada.key}`)).status).toBe(401);
		const mcp = await hq.fetch(new Request(`http://hq.test/mcp?token=${ada.key}`, { method: 'POST', body: '{}' }));
		expect(mcp?.status).toBe(401);
		expect((await hq.fetch(new Request('http://hq.test/v1/ws')))?.status).toBe(426);
	});

	test('the browser’s old routes are gone', async () => {
		const { a, room } = await pair();
		for (const [method, path] of [
			['GET', '/'],
			['GET', '/web/app.js'],
			['GET', '/v1/stream'],
			['POST', '/v1/dms'],
			['GET', `/apps/tasks/page`],
			['GET', `/v1/conversations/${room.id}/stream`],
		] as const) {
			expect([path, (await a.as(method, path, {})).status]).toEqual([path, 404]);
		}
	});
});

describe('the assistant over the wire', () => {
	test('a DM with it is answered, and a room answers to its display name as well as its handle', async () => {
		const hq = createHq({
			provider: scripted([{ content: 'Hello Ada.' }, { content: 'On it.' }]),
			assistant: defineAssistant({ name: 'Atlas Prime', handle: 'atlas', persona: 'Test.', model: 'm' }),
		});
		const ada = await enrolled(hq, admin(hq).key);
		const bot = (await ada.as('GET', '/v1/people')).body.people.find((p: { kind: string }) => p.kind === 'bot');
		const dm = (await ada.as('POST', '/v1/conversations', { kind: 'dm', person_id: bot.id })).body.conversation;
		await say(ada.as, dm.id, 'hi');
		await hq.assistant.runner.idle();
		expect(
			(await ada.as('GET', `/v1/conversations/${dm.id}/messages`)).body.messages.map((m: { content: string }) => m.content),
		).toEqual(['hi', 'Hello Ada.']);

		const room = (await ada.as('POST', '/v1/conversations', { kind: 'group', person_ids: [bot.id] })).body.conversation;
		await say(ada.as, room.id, 'no tag');
		await say(ada.as, room.id, '@Atlas Prime status?');
		await hq.assistant.runner.idle();
		const said = (await ada.as('GET', `/v1/conversations/${room.id}/messages`)).body.messages;
		expect(said.map((m: { content: string }) => m.content)).toEqual(['no tag', '@Atlas Prime status?', 'On it.']);
		expect(said[2].sender_person_id).toBe(bot.id);
	});
});

describe('upgrading an existing database', () => {
	test('old messages and rooms keep working under the new schema', async () => {
		const dir = mkdtempSync(join(tmpdir(), 'hq-upgrade-'));
		try {
			const path = join(dir, 'hq.sqlite');
			// A database from before the app protocol: the original tables only, with a room, a key and a message in them.
			const old = openDatabase(path);
			migrate(old, [...PEOPLE_MIGRATIONS, ...KEY_MIGRATIONS, ...CONVERSATION_MIGRATIONS, ...MESSAGE_MIGRATIONS]);
			const ada = new People(old).create({ name: 'Ada', handle: 'ada', role: 'admin' });
			const room = new Conversations(old).createRoom({ title: 'Old', createdBy: ada.id });
			const key = new Keys(old).mint(ada.id).secret;
			old.query('INSERT INTO messages (id, conversation_id, author_id, body, created_at) VALUES ($id, $c, $a, $body, 1)').run({
				id: newId(),
				c: room.id,
				a: ada.id,
				body: 'from before',
			});
			old.close();

			const hq = createHq({ dbPath: path });
			const signedIn = await enrolled(hq, key);
			const page = (await signedIn.as('GET', `/v1/conversations/${room.id}/messages`)).body.messages;
			expect(page).toMatchObject([{ content: 'from before', deleted_at: null, reactions: [], reply_to: null }]);
			expect((await say(signedIn.as, room.id, 'and after')).status).toBe(201);
			hq.stop();
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
});

describe('server basics', () => {
	test('healthz, not found, and a malformed path', async () => {
		const anon = client(createHq());
		expect((await anon('GET', '/healthz')).body).toEqual({ ok: true });
		expect(await anon('GET', '/nowhere')).toEqual(gone);
		expect((await anon('GET', '/v1/%E0%A4%A')).status).toBe(400);
	});

	test('key management still works for a person’s own keys', async () => {
		const hq = createHq();
		const asAda = client(hq, admin(hq).key);
		const minted = await asAda('POST', '/v1/mcp-keys', { label: 'phone', scopes: ['read', 'send'] });
		const asPhone = client(hq, minted.body.key);
		expect((await asPhone('GET', '/v1/me')).status).toBe(200);
		expect((await asAda('DELETE', `/v1/mcp-keys/${minted.body.id}`)).status).toBe(200);
		expect((await asPhone('GET', '/v1/me')).status).toBe(401);
	});

	test('public URL', () => {
		expect(normalizePublicUrl('https://hq.example.com/')).toBe('https://hq.example.com');
		expect(normalizePublicUrl('https://example.com/hq//')).toBe('https://example.com/hq');
		expect(normalizePublicUrl('  ')).toBeNull();
		expect(() => normalizePublicUrl('ftp://x')).toThrow('http');
		expect(() => normalizePublicUrl('hq.example.com')).toThrow('HQ_PUBLIC_URL must be a full http(s) URL');
		expect(createHq().hub.link('/apps/x')).toBe('/apps/x');
		expect(createHq({ publicUrl: 'https://hq.example.com/' }).hub.link('/apps/x')).toBe('https://hq.example.com/apps/x');
	});
});
