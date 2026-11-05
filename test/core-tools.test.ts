import { describe, expect, test } from 'bun:test';
import { Hub } from '../src/core/hub';
import { coreTools } from '../src/tools/core-tools';
import { ToolRegistry } from '../src/tools/registry';

function setup() {
	const hub = Hub.open();
	const registry = new ToolRegistry().register(coreTools);
	const ada = hub.people.create({ name: 'Ada', handle: 'ada' });
	const bo = hub.people.create({ name: 'Bo', handle: 'bo' });
	return { hub, registry, ada, bo, as: (caller: typeof ada) => ({ hub, caller }) };
}

describe('core tools', () => {
	test('DM by handle, then read it back', async () => {
		const { hub, registry, ada, bo, as } = setup();
		const sent = await registry.call('send_message', { to_handle: '@bo', body: 'standup in 5' }, as(ada));
		expect(sent.ok).toBe(true);
		const dm = hub.conversations.dm(ada.id, bo.id);
		const read = await registry.call('read_conversation', { conversation_id: dm.id }, as(bo));
		expect(read.ok && (read.value as { from: string; body: string }[])[0]).toMatchObject({
			from: 'Ada (@ada)',
			body: 'standup in 5',
		});
	});

	test('read_conversation and search_messages name each author', async () => {
		const { hub, registry, ada, bo, as } = setup();
		const room = hub.conversations.createRoom({ title: 'Both', createdBy: ada.id, memberIds: [bo.id] });
		for (const [author, body] of [
			[ada, 'plan the launch'],
			[bo, 'launch is friday'],
			[ada, 'ok'],
		] as const) {
			hub.messages.send({ conversationId: room.id, authorId: author.id, body });
		}
		const read = await registry.call('read_conversation', { conversation_id: room.id }, as(bo));
		expect(read.ok && (read.value as { from: string }[]).map((m) => m.from)).toEqual(['Ada (@ada)', 'Bo (@bo)', 'Ada (@ada)']);
		const found = await registry.call('search_messages', { query: 'launch' }, as(bo));
		expect(found.ok && (found.value as { from: string; body: string }[]).map((m) => `${m.from}: ${m.body}`)).toEqual([
			'Bo (@bo): launch is friday',
			'Ada (@ada): plan the launch',
		]);
	});

	test('cannot read or post into rooms you are not in', async () => {
		const { hub, registry, ada, bo, as } = setup();
		const room = hub.conversations.createRoom({ title: 'Ada only', createdBy: ada.id });
		expect((await registry.call('read_conversation', { conversation_id: room.id }, as(bo))).ok).toBe(false);
		expect((await registry.call('send_message', { conversation_id: room.id, body: 'hi' }, as(bo))).ok).toBe(false);
	});

	test('viewers limit what a tool can reach to what all of them can see', async () => {
		const { hub, registry, ada, bo } = setup();
		const bot = hub.people.create({ name: 'Bot', handle: 'bot', kind: 'assistant' });
		const secret = hub.conversations.createRoom({ title: 'Ada only', createdBy: ada.id, memberIds: [bot.id] });
		const shared = hub.conversations.createRoom({ title: 'Shared', createdBy: ada.id, memberIds: [bo.id, bot.id] });
		hub.messages.send({ conversationId: secret.id, authorId: ada.id, body: 'launch code 42' });
		hub.messages.send({ conversationId: shared.id, authorId: ada.id, body: 'launch is friday' });
		const forBo = { hub, caller: bot, viewers: [bo.id] };

		expect((await registry.call('read_conversation', { conversation_id: secret.id }, forBo)).ok).toBe(false);
		expect((await registry.call('send_message', { conversation_id: secret.id, body: 'hi' }, forBo)).ok).toBe(false);
		const listed = await registry.call('list_conversations', {}, forBo);
		expect(listed.ok && (listed.value as { title: string }[]).map((c) => c.title)).toEqual(['Shared']);
		const found = await registry.call('search_messages', { query: 'launch' }, forBo);
		expect(found.ok && (found.value as { body: string }[]).map((m) => m.body)).toEqual(['launch is friday']);

		const forAda = { hub, caller: bot, viewers: [ada.id] };
		expect((await registry.call('read_conversation', { conversation_id: secret.id }, forAda)).ok).toBe(true);
		expect((await registry.call('send_message', { to_handle: 'bo', body: 'ping' }, forAda)).ok).toBe(true);
	});

	test('send_message wants exactly one target', async () => {
		const { registry, ada, as } = setup();
		const result = await registry.call('send_message', { body: 'to whom?' }, as(ada));
		expect(result.ok).toBe(false);
	});

	test('create_room and list_conversations', async () => {
		const { registry, ada, bo, as } = setup();
		await registry.call('create_room', { title: 'Launch', member_handles: ['bo'] }, as(ada));
		const listed = await registry.call('list_conversations', {}, as(bo));
		expect(listed.ok && (listed.value as { title: string }[]).map((c) => c.title)).toEqual(['Launch']);
	});

	test('list_conversations titles DMs by the other person', async () => {
		const { hub, registry, ada, bo, as } = setup();
		const cy = hub.people.create({ name: 'Cy', handle: 'cy' });
		hub.conversations.dm(ada.id, bo.id);
		hub.conversations.dm(cy.id, ada.id);
		hub.conversations.createRoom({ title: 'Room', createdBy: ada.id });
		const listed = await registry.call('list_conversations', {}, as(ada));
		expect(listed.ok && (listed.value as { kind: string; title: string }[]).map((c) => `${c.kind}:${c.title}`)).toEqual([
			'dm:Bo',
			'dm:Cy',
			'room:Room',
		]);
	});
});
