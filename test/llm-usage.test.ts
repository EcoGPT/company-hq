import { describe, expect, test } from 'bun:test';
import { defineAssistant } from '../src/assistant/define';
import { createHq } from '../src/hq';
import { scripted } from '../src/llm';
import { ProviderError, type Provider } from '../src/llm/types';

describe('usage accounting', () => {
	test('turns carry their token totals and the hub keeps a daily tally', async () => {
		const provider = scripted([
			{ toolCalls: [{ id: 'c1', name: 'list_people', arguments: {} }], usage: { inputTokens: 100, outputTokens: 10 } },
			{ content: 'Done.', usage: { inputTokens: 150, outputTokens: 5 } },
		]);
		const hq = createHq({ provider, assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', model: 'm' }) });
		const ada = hq.hub.people.create({ name: 'Ada', handle: 'ada' });
		const dm = hq.hub.conversations.dm(ada.id, hq.assistant.self.id);
		const asked = hq.hub.messages.send({ conversationId: dm.id, authorId: ada.id, body: 'who is here?' });
		await hq.assistant.runner.idle();

		expect(hq.hub.messages.list(dm.id).at(-1)?.metadata).toEqual({
			turn: { hops: 2, model: 'm', seen: asked.id, usage: { inputTokens: 250, outputTokens: 15 } },
		});
		expect(hq.usage.totals()).toEqual([
			{ capability: 'chat', provider: 'mock', model: 'm', calls: 2, failures: 0, input_tokens: 250, output_tokens: 15 },
		]);
	});

	test('failures are counted too', async () => {
		const broken: Provider = {
			id: 'broken',
			async complete() {
				throw new ProviderError('broken', 500, 'down');
			},
		};
		const hq = createHq({ provider: broken });
		await hq.provider.complete({ model: 'x', messages: [] }).catch(() => {});
		expect(hq.usage.totals()).toEqual([
			{ capability: 'chat', provider: 'broken', model: 'x', calls: 1, failures: 1, input_tokens: 0, output_tokens: 0 },
		]);
	});

	test('retries and fallbacks count each failed attempt', async () => {
		const failures = [new ProviderError('flaky', 503, 'busy'), new ProviderError('flaky', 503, 'busy')];
		const flaky: Provider = {
			id: 'flaky',
			async complete(request) {
				if (request.model === 'main') throw failures.shift() ?? new ProviderError('flaky', 404, 'gone');
				return { content: 'ok', toolCalls: [], finishReason: 'stop', usage: { inputTokens: 7, outputTokens: 3 } };
			},
		};
		const hq = createHq({
			provider: flaky,
			resilience: { retries: 1, sleep: async () => {}, fallback: [{ model: 'backup' }] },
		});
		await hq.provider.complete({ model: 'main', messages: [] });
		expect(hq.usage.totals()).toEqual([
			{ capability: 'chat', provider: 'flaky', model: 'main', calls: 2, failures: 2, input_tokens: 0, output_tokens: 0 },
			{ capability: 'chat', provider: 'flaky', model: 'backup', calls: 1, failures: 0, input_tokens: 7, output_tokens: 3 },
		]);
	});
});
