import { describe, expect, test } from 'bun:test';
import { anthropic, toAnthropic } from '../src/llm/anthropic';

describe('toAnthropic', () => {
	test('lifts system, merges tool results into one user turn', () => {
		const { system, messages } = toAnthropic([
			{ role: 'system', content: 'a' },
			{ role: 'system', content: 'b' },
			{ role: 'user', content: 'go' },
			{
				role: 'assistant',
				content: 'checking',
				toolCalls: [
					{ id: 't1', name: 'x', arguments: { n: 1 } },
					{ id: 't2', name: 'y', arguments: {} },
				],
			},
			{ role: 'tool', toolCallId: 't1', name: 'x', content: '1' },
			{ role: 'tool', toolCallId: 't2', name: 'y', content: '2' },
		]);
		expect(system).toBe('a\n\nb');
		expect(messages.map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
		expect(messages[1]?.content).toEqual([
			{ type: 'text', text: 'checking' },
			{ type: 'tool_use', id: 't1', name: 'x', input: { n: 1 } },
			{ type: 'tool_use', id: 't2', name: 'y', input: {} },
		]);
		expect(messages[2]?.content).toHaveLength(2);
	});
});

describe('anthropic', () => {
	test('round-trips a tool call', async () => {
		let sent: { url: string; init: RequestInit } | undefined;
		const fetchImpl = (async (url: string, init: RequestInit) => {
			sent = { url, init };
			return Response.json({
				content: [
					{ type: 'text', text: 'Let me look.' },
					{ type: 'tool_use', id: 'tu_1', name: 'list_tasks', input: { open: true } },
				],
				stop_reason: 'tool_use',
				usage: { input_tokens: 5, output_tokens: 7 },
			});
		}) as unknown as typeof fetch;
		const result = await anthropic({ apiKey: 'k', fetch: fetchImpl }).complete({
			model: 'claude-model',
			messages: [{ role: 'user', content: 'open tasks?' }],
			tools: [{ name: 'list_tasks', description: 'List', parameters: { type: 'object' } }],
		});
		expect(sent?.url).toBe('https://api.anthropic.com/v1/messages');
		expect((sent?.init.headers as Record<string, string>)['x-api-key']).toBe('k');
		const body = JSON.parse(String(sent?.init.body));
		expect(body.max_tokens).toBe(4096);
		expect(body.tools[0].input_schema).toEqual({ type: 'object' });
		expect(result).toEqual({
			content: 'Let me look.',
			toolCalls: [{ id: 'tu_1', name: 'list_tasks', arguments: { open: true } }],
			finishReason: 'tool_calls',
			usage: { inputTokens: 5, outputTokens: 7 },
		});
	});

	test('maps stop reasons and errors', async () => {
		const ok = (async () =>
			Response.json({ content: [{ type: 'text', text: 'done' }], stop_reason: 'max_tokens' })) as unknown as typeof fetch;
		expect((await anthropic({ apiKey: 'k', fetch: ok }).complete({ model: 'm', messages: [] })).finishReason).toBe('length');
		const bad = (async () =>
			Response.json({ type: 'error', error: { message: 'overloaded' } }, { status: 529 })) as unknown as typeof fetch;
		await expect(anthropic({ apiKey: 'k', fetch: bad }).complete({ model: 'm', messages: [] })).rejects.toThrow('overloaded');
	});
});

describe('a tool-free final answer', () => {
	test('still defines the tools its history used, with tool_choice none', async () => {
		let body: Record<string, unknown> = {};
		const fetchImpl = (async (_: string, init: RequestInit) => {
			body = JSON.parse(String(init.body));
			return Response.json({ content: [{ type: 'text', text: 'Partial.' }], stop_reason: 'end_turn' });
		}) as unknown as typeof fetch;
		await anthropic({ apiKey: 'k', fetch: fetchImpl }).complete({
			model: 'm',
			messages: [
				{ role: 'user', content: 'Ada: who is here?' },
				{ role: 'assistant', content: '', toolCalls: [{ id: 'tu_1', name: 'list_people', arguments: {} }] },
				{ role: 'tool', toolCallId: 'tu_1', name: 'list_people', content: '[]' },
			],
			tools: [{ name: 'list_people', description: 'List', parameters: { type: 'object' } }],
			toolChoice: 'none',
		});
		expect(body.tools).toEqual([{ name: 'list_people', description: 'List', input_schema: { type: 'object' } }]);
		expect(body.tool_choice).toEqual({ type: 'none' });
	});
});

describe('history that starts with the assistant', () => {
	test('gets a user turn first, as the Messages API requires', () => {
		const { messages } = toAnthropic([
			{ role: 'system', content: 's' },
			{ role: 'assistant', content: 'an older reply cut off by the history window' },
			{ role: 'user', content: 'Ada: thanks' },
		]);
		expect(messages.map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
		expect(messages[0]?.content).toEqual([{ type: 'text', text: '(Earlier messages are not shown.)' }]);
	});
});
