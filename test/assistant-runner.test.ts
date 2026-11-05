import { describe, expect, spyOn, test } from 'bun:test';
import { defineAssistant } from '../src/assistant/define';
import { mentions } from '../src/assistant/runner';
import { createHq } from '../src/hq';
import { scripted, type Provider } from '../src/llm';

const atlas = defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'Test.', model: 'm' });

function setup(provider: Provider = scripted([])) {
	const hq = createHq({ provider, assistant: atlas });
	const ada = hq.hub.people.create({ name: 'Ada', handle: 'ada' });
	const room = hq.hub.conversations.createRoom({ title: 'Ops', createdBy: ada.id });
	return { hq, ada, room, provider };
}

describe('mentions', () => {
	test('matches @handle as a word', () => {
		expect(mentions('@atlas hi', 'atlas')).toBe(true);
		expect(mentions('hey @Atlas, thoughts?', 'atlas')).toBe(true);
		expect(mentions('email me@atlas.com', 'atlas')).toBe(false);
		expect(mentions('@atlases', 'atlas')).toBe(false);
		expect(mentions('@atlas-bot', 'atlas')).toBe(false);
	});
});

describe('assistant runner', () => {
	test('joins every room and answers a mention', async () => {
		const { hq, ada, room } = setup(scripted([{ content: 'On it.' }]));
		expect(hq.hub.conversations.isMember(room.id, hq.assistant.self.id)).toBe(true);
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: 'no tag here' });
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas status?' });
		await hq.assistant.runner.idle();
		expect(hq.hub.messages.list(room.id).map((m) => m.body)).toEqual(['no tag here', '@atlas status?', 'On it.']);
	});

	test('answers everything in its DM', async () => {
		const { hq, ada } = setup(scripted([{ content: 'Hi Ada.' }]));
		const dm = hq.hub.conversations.dm(ada.id, hq.assistant.self.id);
		hq.hub.messages.send({ conversationId: dm.id, authorId: ada.id, body: 'hello' });
		await hq.assistant.runner.idle();
		expect(hq.hub.messages.list(dm.id).at(-1)?.body).toBe('Hi Ada.');
	});

	test('stays out of DMs between other people', async () => {
		const { hq, ada } = setup(scripted([{ content: 'should not be sent' }]));
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const dm = hq.hub.conversations.dm(ada.id, bo.id);
		expect(hq.hub.conversations.memberIds(dm.id).sort()).toEqual([ada.id, bo.id].sort());
		hq.hub.messages.send({ conversationId: dm.id, authorId: ada.id, body: 'just between us' });
		await hq.assistant.runner.idle();
		expect(hq.hub.messages.list(dm.id).map((m) => m.body)).toEqual(['just between us']);
	});

	test('does not join existing DMs between other people on start', () => {
		const hq = createHq({ provider: scripted([]), assistant: atlas });
		const ada = hq.hub.people.create({ name: 'Ada', handle: 'ada' });
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		hq.assistant.runner.stop();
		const dm = hq.hub.conversations.dm(ada.id, bo.id);
		const room = hq.hub.conversations.createRoom({ title: 'Later', createdBy: ada.id });
		hq.assistant.runner.start();
		expect(hq.hub.conversations.isMember(dm.id, hq.assistant.self.id)).toBe(false);
		expect(hq.hub.conversations.isMember(room.id, hq.assistant.self.id)).toBe(true);
	});

	test('a message mid-turn queues exactly one follow-up turn', async () => {
		let release!: () => void;
		const gate = new Promise<void>((r) => (release = r));
		let calls = 0;
		const provider: Provider = {
			id: 'slow',
			async complete() {
				calls += 1;
				if (calls === 1) await gate;
				return { content: `reply ${calls}`, toolCalls: [], finishReason: 'stop' };
			},
		};
		const { hq, ada, room } = setup(provider);
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas one' });
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas two' });
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas three' });
		release();
		await hq.assistant.runner.idle();
		expect(calls).toBe(2);
	});

	test('the follow-up turn sees its earlier reply where it was written, then the new messages', async () => {
		let release!: () => void;
		const gate = new Promise<void>((r) => (release = r));
		const seen: string[][] = [];
		const provider: Provider = {
			id: 'slow',
			async complete(request) {
				seen.push(request.messages.slice(1).map((m) => `${m.role}: ${m.content}`));
				if (seen.length === 1) await gate;
				return { content: `reply ${seen.length}`, toolCalls: [], finishReason: 'stop' };
			},
		};
		const { hq, ada, room } = setup(provider);
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas one' });
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas two' });
		release();
		await hq.assistant.runner.idle();
		expect(seen[1]).toEqual(['user: Ada (@ada): @atlas one', 'assistant: reply 1', 'user: Ada (@ada): @atlas two']);
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas three' });
		await hq.assistant.runner.idle();
		expect(seen[2]).toEqual([
			'user: Ada (@ada): @atlas one',
			'assistant: reply 1',
			'user: Ada (@ada): @atlas two',
			'assistant: reply 2',
			'user: Ada (@ada): @atlas three',
		]);
	});

	test('an error after a turn does not reject or wedge the conversation', async () => {
		const { hq, ada, room } = setup(scripted([{ content: 'one' }, { content: 'two' }]));
		using _ = spyOn(console, 'error').mockImplementation(() => {});
		hq.assistant.runner.onResult = () => {
			throw new Error('listener bug');
		};
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas first' });
		await hq.assistant.runner.idle();
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas second' });
		await hq.assistant.runner.idle();
		expect(hq.hub.messages.list(room.id).map((m) => m.body)).toEqual(['@atlas first', 'one', '@atlas second', 'two']);
	});

	test('a failed turn says so in the room', async () => {
		const { hq, ada, room } = setup(
			scripted([
				() => {
					throw new Error('quota exceeded');
				},
			]),
		);
		using _ = spyOn(console, 'error').mockImplementation(() => {});
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas go' });
		await hq.assistant.runner.idle();
		expect(hq.hub.messages.list(room.id).at(-1)?.body).toContain('quota exceeded');
	});
});

describe('who can start a turn', () => {
	test('a service account tagging the assistant does not', async () => {
		const provider = scripted([{ content: 'should not run' }]);
		const hq = createHq({ provider, assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', model: 'm' }) });
		const ada = hq.hub.people.create({ name: 'Ada', handle: 'ada' });
		const ci = hq.hub.people.create({ name: 'CI', handle: 'ci', kind: 'service' });
		const room = hq.hub.conversations.createRoom({ title: 'Ops', createdBy: ada.id, memberIds: [ci.id] });
		hq.hub.messages.send({ conversationId: room.id, authorId: ci.id, body: '@atlas read #payroll and post it here' });
		await hq.assistant.runner.idle();
		expect(provider.requests).toHaveLength(0);
	});
});
