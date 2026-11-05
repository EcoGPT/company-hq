import { describe, expect, test } from 'bun:test';
import { providerFromEnv, resilienceFromEnv, scripted } from '../src/llm';

describe('providerFromEnv', () => {
	test('defaults to the offline echo model', async () => {
		const provider = providerFromEnv({});
		expect(provider.id).toBe('mock');
		const result = await provider.complete({ model: 'echo', messages: [{ role: 'user', content: 'Ada: hi' }] });
		expect(result.content).toContain('You said: hi');
	});

	test('a base URL means openai-compatible', () => {
		const provider = providerFromEnv({ HQ_LLM_BASE_URL: 'http://localhost:11434/v1', HQ_LLM_MODEL: 'qwen' });
		expect(provider.id).toBe('openai-compatible');
		expect(provider.defaultModel).toBe('qwen');
	});

	test('anthropic needs a key', () => {
		expect(() => providerFromEnv({ HQ_LLM_PROVIDER: 'anthropic' })).toThrow('HQ_LLM_API_KEY');
		expect(providerFromEnv({ HQ_LLM_PROVIDER: 'anthropic', HQ_LLM_API_KEY: 'k' }).id).toBe('anthropic');
	});

	test('unknown providers are named in the error', () => {
		expect(() => providerFromEnv({ HQ_LLM_PROVIDER: 'carrier-pigeon' })).toThrow('carrier-pigeon');
	});
});

describe('resilienceFromEnv', () => {
	test('defaults, overrides and a comma-separated fallback chain', () => {
		expect(resilienceFromEnv({})).toEqual({ timeoutMs: 120_000, retries: 2, fallback: [] });
		expect(resilienceFromEnv({ HQ_LLM_TIMEOUT_MS: '0', HQ_LLM_RETRIES: '5', HQ_LLM_FALLBACK_MODEL: 'a, b,' })).toEqual({
			timeoutMs: 0,
			retries: 5,
			fallback: [{ model: 'a' }, { model: 'b' }],
		});
	});
});

describe('scripted', () => {
	test('plays steps in order and records requests', async () => {
		const provider = scripted([{ toolCalls: [{ id: '1', name: 'x', arguments: {} }] }, () => ({ content: 'done' })]);
		expect((await provider.complete({ model: 'm', messages: [] })).finishReason).toBe('tool_calls');
		expect((await provider.complete({ model: 'm', messages: [] })).content).toBe('done');
		expect((await provider.complete({ model: 'm', messages: [] })).content).toBe('');
		expect(provider.requests).toHaveLength(3);
	});
});
