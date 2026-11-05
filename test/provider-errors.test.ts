import { describe, expect, spyOn, test } from 'bun:test';
import { z } from 'zod';
import { defineAssistant } from '../src/assistant/define';
import { createHq } from '../src/hq';
import { scripted } from '../src/llm';
import { ProviderError } from '../src/llm/types';
import { defineTool } from '../src/tools/define';
import { asToolError } from '../src/tools/lookup';
import { admin } from './helpers';

const LEAK = 'Incorrect API key provided: sk-proj-...wxyz';
const leaky = () => new ProviderError('openai-compatible', 401, LEAK);
const logged = (calls: unknown[][]) =>
	calls
		.flat()
		.map((arg) => (arg instanceof Error ? arg.message : String(arg)))
		.join('\n');

describe('provider errors reaching members', () => {
	test('a failed turn posts the provider and status, and logs the detail', async () => {
		const hq = createHq({
			provider: scripted([
				() => {
					throw leaky();
				},
			]),
			assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'Test.', model: 'm' }),
		});
		const ada = hq.hub.people.create({ name: 'Ada', handle: 'ada' });
		const room = hq.hub.conversations.createRoom({ title: 'Ops', createdBy: ada.id });
		using log = spyOn(console, 'error').mockImplementation(() => {});
		hq.hub.messages.send({ conversationId: room.id, authorId: ada.id, body: '@atlas go' });
		await hq.assistant.runner.idle();
		expect(hq.hub.messages.list(room.id).at(-1)?.body).toBe(
			"I couldn't finish that: model provider error: openai-compatible (401)",
		);
		expect(logged(log.mock.calls)).toContain(LEAK);
	});

	test('a tool that hits a provider error returns only the provider and status', async () => {
		const hq = createHq({
			apps: [
				{
					slug: 'summary',
					name: 'Summary',
					description: 'Test',
					tools: [
						defineTool({
							name: 'summarize',
							description: 'Summarize',
							input: z.object({}),
							run: () => {
								throw leaky();
							},
						}),
						defineTool({
							name: 'summarize_wrapped',
							description: 'Summarize, wrapped',
							input: z.object({}),
							run: () =>
								asToolError(async () => {
									throw leaky();
								}),
						}),
					],
				},
			],
		});
		const ada = admin(hq);
		using log = spyOn(console, 'error').mockImplementation(() => {});
		const ctx = { hub: hq.hub, caller: ada.person };
		expect(await hq.registry.call('summarize', {}, ctx)).toEqual({
			ok: false,
			error: 'summarize failed: model provider error: openai-compatible (401)',
		});
		expect(await hq.registry.call('summarize_wrapped', {}, ctx)).toEqual({
			ok: false,
			error: 'model provider error: openai-compatible (401)',
		});
		const mcp = (await hq.fetch(
			new Request('http://hq.test/mcp', {
				method: 'POST',
				headers: { 'content-type': 'application/json', authorization: `Bearer ${ada.key}` },
				body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'summarize', arguments: {} } }),
			}),
		)) as Response;
		expect(await mcp.text()).not.toContain('sk-proj');
		expect(logged(log.mock.calls)).toContain(LEAK);
	});
});
