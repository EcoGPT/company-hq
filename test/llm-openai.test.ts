import { describe, expect, test } from 'bun:test';
import { openAICompatible } from '../src/llm/openai-compatible';
import { ProviderError } from '../src/llm/types';
import { fakeFetch } from './helpers';

describe('openAICompatible', () => {
	test('maps messages, tools and tool calls both ways', async () => {
		const { impl, calls } = fakeFetch(() => ({
			choices: [
				{
					message: {
						content: null,
						tool_calls: [{ id: 'c1', type: 'function', function: { name: 'list_tasks', arguments: '{"open":true}' } }],
					},
					finish_reason: 'tool_calls',
				},
			],
			usage: { prompt_tokens: 10, completion_tokens: 3 },
		}));
		const provider = openAICompatible({ baseUrl: 'http://llm.test/v1/', apiKey: 'sk-test', fetch: impl });
		const result = await provider.complete({
			model: 'any-model',
			messages: [
				{ role: 'system', content: 'be brief' },
				{ role: 'user', content: 'what is open?' },
				{ role: 'assistant', content: '', toolCalls: [{ id: 'c0', name: 'ping', arguments: {} }] },
				{ role: 'tool', toolCallId: 'c0', name: 'ping', content: 'pong' },
			],
			tools: [{ name: 'list_tasks', description: 'List tasks', parameters: { type: 'object' } }],
		});

		expect(calls[0]?.url).toBe('http://llm.test/v1/chat/completions');
		expect((calls[0]?.init.headers as Record<string, string>).authorization).toBe('Bearer sk-test');
		const sent = JSON.parse(String(calls[0]?.init.body));
		expect(sent.tools[0].function.name).toBe('list_tasks');
		expect(sent.messages[2]).toEqual({
			role: 'assistant',
			content: null,
			tool_calls: [{ id: 'c0', type: 'function', function: { name: 'ping', arguments: '{}' } }],
		});
		expect(sent.messages[3]).toEqual({ role: 'tool', tool_call_id: 'c0', content: 'pong' });

		expect(result).toEqual({
			content: '',
			toolCalls: [{ id: 'c1', name: 'list_tasks', arguments: { open: true } }],
			finishReason: 'tool_calls',
			usage: { inputTokens: 10, outputTokens: 3 },
		});
	});

	test('tool_choice none sends no tools', async () => {
		const { impl, calls } = fakeFetch(() => ({ choices: [{ message: { content: 'done' }, finish_reason: 'stop' }] }));
		await openAICompatible({ baseUrl: 'http://llm.test/v1', fetch: impl }).complete({
			model: 'm',
			messages: [{ role: 'user', content: 'hi' }],
			tools: [{ name: 'list_tasks', description: 'List tasks', parameters: { type: 'object' } }],
			toolChoice: 'none',
		});
		const sent = JSON.parse(String(calls[0]?.init.body));
		expect(sent.tools).toBeUndefined();
		expect(sent.tool_choice).toBeUndefined();
	});

	test('keyless local servers send no auth header', async () => {
		const { impl, calls } = fakeFetch(() => ({ choices: [{ message: { content: 'hi' }, finish_reason: 'stop' }] }));
		const result = await openAICompatible({ baseUrl: 'http://localhost:11434/v1', fetch: impl }).complete({
			model: 'llama',
			messages: [{ role: 'user', content: 'hello' }],
		});
		expect((calls[0]?.init.headers as Record<string, string>).authorization).toBeUndefined();
		expect(result.content).toBe('hi');
		expect(result.finishReason).toBe('stop');
	});

	test('malformed tool arguments survive as _raw', async () => {
		const { impl } = fakeFetch(() => ({
			choices: [{ message: { tool_calls: [{ id: 'x', type: 'function', function: { name: 'f', arguments: '{oops' } }] } }],
		}));
		const result = await openAICompatible({ baseUrl: 'http://x', fetch: impl }).complete({ model: 'm', messages: [] });
		expect(result.toolCalls[0]?.arguments).toEqual({ _raw: '{oops' });
	});

	test('errors carry status and message', async () => {
		const { impl } = fakeFetch(() => Response.json({ error: { message: 'slow down' } }, { status: 429 }));
		const promise = openAICompatible({ baseUrl: 'http://x', fetch: impl }).complete({ model: 'm', messages: [] });
		await expect(promise).rejects.toBeInstanceOf(ProviderError);
		await expect(promise).rejects.toThrow('slow down');
	});

	test('a plain-string error body is the message', async () => {
		const { impl } = fakeFetch(() => Response.json({ error: "model 'qwen' not found" }, { status: 404 }));
		const promise = openAICompatible({ baseUrl: 'http://x', fetch: impl }).complete({ model: 'qwen', messages: [] });
		await expect(promise).rejects.toThrow("openai-compatible: model 'qwen' not found");
	});

	test('a non-JSON body is a ProviderError that keeps the status', async () => {
		const impl = (async () => new Response('<html>bad gateway</html>', { status: 502 })) as unknown as typeof fetch;
		const error = await openAICompatible({ baseUrl: 'http://x', fetch: impl })
			.complete({ model: 'm', messages: [] })
			.catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ProviderError);
		expect(error).toMatchObject({ status: 502, message: 'openai-compatible: non-JSON response: <html>bad gateway</html>' });
	});
});

describe('the output token limit parameter', () => {
	const rejectMaxTokens = () =>
		fakeFetch((_url, init) => {
			const sent = JSON.parse(String(init.body));
			if ('max_tokens' in sent)
				return Response.json(
					{
						error: {
							message:
								"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
						},
					},
					{ status: 400 },
				);
			return { choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }] };
		});

	test('falls back to max_completion_tokens once and remembers it', async () => {
		const { impl, calls } = rejectMaxTokens();
		const provider = openAICompatible({ baseUrl: 'http://x', fetch: impl });
		const request = { model: 'm', messages: [{ role: 'user' as const, content: 'hi' }], maxTokens: 64 };
		expect((await provider.complete(request)).content).toBe('ok');
		expect((await provider.complete(request)).content).toBe('ok');
		const sent = calls.map((call) => JSON.parse(String(call.init.body)));
		expect(sent.map((body) => [body.max_tokens, body.max_completion_tokens])).toEqual([
			[64, undefined],
			[undefined, 64],
			[undefined, 64],
		]);
	});

	test('concurrent requests sent with max_tokens each fall back', async () => {
		const { impl, calls } = rejectMaxTokens();
		const provider = openAICompatible({ baseUrl: 'http://x', fetch: impl });
		const request = { model: 'm', messages: [{ role: 'user' as const, content: 'hi' }], maxTokens: 64 };
		const replies = await Promise.all([provider.complete(request), provider.complete(request)]);
		expect(replies.map((reply) => reply.content)).toEqual(['ok', 'ok']);
		expect(calls).toHaveLength(4);
	});

	test('other 400s are not retried', async () => {
		const { impl, calls } = fakeFetch(() => Response.json({ error: { message: 'bad messages' } }, { status: 400 }));
		const promise = openAICompatible({ baseUrl: 'http://x', fetch: impl }).complete({
			model: 'm',
			messages: [],
			maxTokens: 64,
		});
		await expect(promise).rejects.toThrow('bad messages');
		expect(calls).toHaveLength(1);
	});
});

describe('an unreachable model server', () => {
	test('is named in the error and counts as retryable', async () => {
		const { ProviderError } = await import('../src/llm/types');
		const { isRetryable } = await import('../src/llm/middleware');
		const refused = (async () => {
			throw Object.assign(new Error('Unable to connect. Is the computer able to access the url?'), { code: 'ConnectionRefused' });
		}) as unknown as typeof fetch;
		const error = await openAICompatible({ baseUrl: 'http://localhost:11434/v1', fetch: refused })
			.complete({ model: 'm', messages: [] })
			.catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ProviderError);
		expect((error as Error).message).toContain('could not reach http://localhost:11434');
		expect((error as Error).message).toContain('Is the model server running?');
		expect(isRetryable(error)).toBe(true);
	});
});
