import { afterEach, describe, expect, test } from 'bun:test';
import type { Server } from 'bun';
import { defineAssistant } from '../src/assistant/define';
import { runTurn } from '../src/assistant/turn';
import { createHq } from '../src/hq';
import { scripted } from '../src/llm';
import type { SocketData } from '../src/realtime/socket';
import { roomFor } from '../src/tools/lookup';
import { admin, client, connect, enrolled, say, serve } from './helpers';

const atlas = defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'Test.', model: 'm' });

function setup(provider = scripted([])) {
	const hq = createHq({ provider, assistant: atlas });
	const ada = admin(hq);
	const room = hq.hub.conversations.createRoom({ title: 'Old launch', createdBy: ada.person.id });
	hq.hub.messages.send({ conversationId: room.id, authorId: ada.person.id, body: 'the old roadmap' });
	hq.hub.conversations.archive(room.id);
	return { hq, ada, room, asAda: client(hq, ada.key) };
}

let server: Server<SocketData> | undefined;
afterEach(() => server?.stop(true));

describe('an archived room is a room you are not in', () => {
	test('membership and members are empty once archived', () => {
		const { hq, ada, room } = setup();
		expect(hq.hub.conversations.isMember(room.id, ada.person.id)).toBe(false);
		expect(hq.hub.conversations.memberIds(room.id)).toEqual([]);
		expect(hq.hub.conversations.get(room.id)?.archived_at).not.toBeNull();
	});

	test('HTTP reads answer 404 and writes are refused', async () => {
		const { hq, room, asAda } = setup();
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const gone = { status: 404, body: { error: 'not_found' } };
		expect(await asAda('GET', `/v1/conversations/${room.id}`)).toEqual(gone);
		expect(await asAda('GET', `/v1/conversations/${room.id}/messages`)).toEqual(gone);
		expect(await say(asAda, room.id, 'hello?')).toEqual(gone);
		expect(await asAda('PATCH', `/v1/conversations/${room.id}`, { title: 'Revived' })).toEqual(gone);
		expect(await asAda('POST', `/v1/conversations/${room.id}/members`, { person_ids: [bo.id] })).toEqual(gone);
		expect(await asAda('DELETE', `/v1/conversations/${room.id}/members/me`)).toEqual(gone);
		expect(await asAda('POST', `/v1/conversations/${room.id}/read`, { message_id: hq.hub.messages.latest(room.id)!.id })).toEqual(
			gone,
		);
		expect(await asAda('POST', `/v1/conversations/${room.id}/unread`)).toEqual(gone);
		expect(await asAda('POST', `/v1/conversations/${room.id}/attachments`)).toEqual(gone);
		expect(hq.hub.conversations.get(room.id)?.title).toBe('Old launch');
		expect(hq.hub.messages.list(room.id).map((m) => m.body)).toEqual(['the old roadmap']);
	});

	test('a message in it cannot be edited, unsent or tapped back', async () => {
		const { hq, room, asAda } = setup();
		const id = hq.hub.messages.latest(room.id)!.id;
		expect((await asAda('PATCH', `/v1/messages/${id}`, { content: 'rewritten' })).status).toBe(404);
		expect((await asAda('DELETE', `/v1/messages/${id}`)).status).toBe(404);
		expect((await asAda('POST', `/v1/messages/${id}/reactions`, { emoji: '👍' })).status).toBe(404);
		expect(hq.hub.messages.get(id)).toMatchObject({ body: 'the old roadmap', edited_at: null, deleted_at: null });
	});

	test('HTTP search skips it', async () => {
		const { asAda } = setup();
		expect((await asAda('GET', '/v1/search?q=roadmap')).body).toEqual({ messages: [] });
		expect((await asAda('GET', '/v1/search?q=ro')).body).toEqual({ messages: [] });
	});

	test('an archived DM cannot be reopened', async () => {
		const { hq, ada, asAda } = setup();
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const dm = hq.hub.conversations.dm(ada.person.id, bo.id);
		hq.hub.conversations.archive(dm.id);
		expect((await asAda('POST', '/v1/conversations', { kind: 'dm', person_id: bo.id })).status).toBe(404);
	});

	test('its upload and its files are out of reach', async () => {
		const { hq, ada, room } = setup();
		const live = hq.hub.conversations.createRoom({ title: 'Live', createdBy: ada.person.id });
		const upload = await hq.fetch(
			new Request(`http://hq.test/v1/conversations/${live.id}/attachments`, {
				method: 'POST',
				headers: { authorization: `Bearer ${ada.key}`, 'content-type': 'text/plain', 'x-hq-file-name': 'plan.txt' },
				body: 'the plan',
			}),
		);
		const { attachment } = await upload!.json();
		const message = hq.hub.messages.send({
			conversationId: live.id,
			authorId: ada.person.id,
			body: 'plan',
			attachmentIds: [attachment.id],
		});
		const fetchFile = () =>
			hq.fetch(
				new Request(`http://hq.test/v1/attachments/${attachment.id}`, { headers: { authorization: `Bearer ${ada.key}` } }),
			);
		expect((await fetchFile())?.status).toBe(200);
		hq.hub.conversations.archive(live.id);
		expect((await fetchFile())?.status).toBe(404);
		expect(message.conversation_id).not.toBe(room.id);
	});

	test('core tools refuse it', async () => {
		const { hq, ada, room } = setup();
		const ctx = { hub: hq.hub, caller: ada.person };
		const read = await hq.registry.call('read_conversation', { conversation_id: room.id }, ctx);
		expect(read).toEqual({ ok: false, error: `no conversation ${room.id} that you are in` });
		const sent = await hq.registry.call('send_message', { conversation_id: room.id, body: 'hello?' }, ctx);
		expect(sent.ok).toBe(false);
		const found = await hq.registry.call('search_messages', { query: 'roadmap' }, ctx);
		expect(found).toEqual({ ok: true, value: [] });
		expect(() => roomFor(ctx, room.id)).toThrow('that you are in');
		expect(hq.hub.messages.list(room.id)).toHaveLength(1);
	});

	test('send_message by handle refuses an archived DM', async () => {
		const { hq, ada } = setup();
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const dm = hq.hub.conversations.dm(ada.person.id, bo.id);
		hq.hub.conversations.archive(dm.id);
		const sent = await hq.registry.call('send_message', { to_handle: 'bo', body: 'hello?' }, { hub: hq.hub, caller: ada.person });
		expect(sent.ok).toBe(false);
		expect(hq.hub.messages.list(dm.id)).toEqual([]);
	});

	test('MCP tools refuse it', async () => {
		const { hq, ada, room } = setup();
		const call = async (name: string, args: unknown) => {
			const response = (await hq.fetch(
				new Request('http://hq.test/mcp', {
					method: 'POST',
					headers: { 'content-type': 'application/json', authorization: `Bearer ${ada.key}` },
					body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
				}),
			)) as Response;
			return (await response.json()).result as { isError: boolean; content: { text: string }[] };
		};
		expect((await call('read_conversation', { conversation_id: room.id })).isError).toBe(true);
		expect((await call('send_message', { conversation_id: room.id, body: 'hi' })).isError).toBe(true);
		expect((await call('search_messages', { query: 'roadmap' })).content[0]?.text).toBe('[]');
	});

	test('the socket does not deliver its events, even to someone it names', async () => {
		const { hq, ada, room } = setup();
		server = serve(hq);
		const signedIn = await enrolled(hq, ada.key);
		const ws = await connect(server, signedIn.bearer);
		hq.hub.messages.send({ conversationId: room.id, authorId: hq.assistant.self.id, body: 'posted by an app' });
		hq.hub.bus.emit({ type: 'conversation.changed', conversationId: room.id, audience: [ada.person.id] });
		hq.hub.bus.emit({ type: 'conversation.created', conversation: room });
		hq.hub.bus.emit({ type: 'assistant.state', conversationId: room.id, personId: hq.assistant.self.id, label: 'Thinking' });
		hq.hub.bus.emit({ type: 'read', conversationId: room.id, personId: ada.person.id, messageId: 'x' });
		ws.send({ type: 'typing', conversation_id: room.id });
		ws.send({ type: 'sync' });
		await ws.settle();
		expect(ws.types()).toEqual(['hello', 'sync_complete']);
		ws.ws.close();
	});

	test('the assistant does not answer in it', async () => {
		const { hq, ada, room } = setup(scripted([{ content: 'On it.' }]));
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.person.id, body: '@atlas status?' });
		await hq.assistant.runner.idle();
		expect(hq.hub.messages.list(room.id).map((m) => m.body)).toEqual(['the old roadmap', '@atlas status?']);
	});

	test('a turn started on it fails as not found', async () => {
		const { hq, room } = setup(scripted([{ content: 'On it.' }]));
		const { definition, self, memory } = hq.assistant;
		const result = await runTurn(
			{ hub: hq.hub, provider: hq.provider, registry: hq.registry, assistant: definition, self, memory },
			room.id,
		);
		expect(result).toEqual({ kind: 'failed', error: 'conversation not found', hops: 0 });
	});

	test('memories saved in it stop reaching prompts', () => {
		const { hq, ada, room } = setup();
		hq.assistant.memory.add('launch codename is Kestrel', ada.person.id, room.id);
		hq.assistant.memory.add('Ada prefers mornings', ada.person.id, null);
		expect(hq.assistant.memory.visibleTo([ada.person.id]).map((m) => m.content)).toEqual(['Ada prefers mornings']);
	});

	test('listings still hide it and the archive action still works', async () => {
		const { hq, ada, room, asAda } = setup();
		expect(hq.hub.conversations.listFor(ada.person.id).map((c) => c.id)).not.toContain(room.id);
		expect((await asAda('GET', '/v1/conversations')).body.conversations.map((c: { id: string }) => c.id)).not.toContain(room.id);
		const other = hq.hub.conversations.createRoom({ title: 'Live', createdBy: ada.person.id });
		expect(hq.hub.conversations.isMember(other.id, ada.person.id)).toBe(true);
		hq.hub.conversations.archive(other.id);
		expect(hq.hub.conversations.isMember(other.id, ada.person.id)).toBe(false);
	});
});
