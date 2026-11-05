import { describe, expect, test } from 'bun:test';
import { resilient, withFallback, withRetry, withTimeout } from '../src/llm/middleware';
import { retryAfter } from '../src/llm/http';
import { ProviderError, type CompletionRequest, type Provider } from '../src/llm/types';

const request: CompletionRequest = { model: 'main', messages: [{ role: 'user', content: 'hi' }] };

function flaky(failures: unknown[], id = 'flaky'): Provider & { models: string[] } {
	const queue = [...failures];
	const models: string[] = [];
	return {
		id,
		defaultModel: 'main',
		models,
		async complete(req) {
			models.push(req.model);
			const failure = queue.shift();
			if (failure !== undefined) throw failure;
			return { content: `ok from ${req.model}`, toolCalls: [], finishReason: 'stop' };
		},
	};
}

const noSleep = { sleep: async () => {} };

describe('withRetry', () => {
	test('retries 429 and 5xx, then succeeds', async () => {
		const inner = flaky([new ProviderError('x', 429, 'slow'), new ProviderError('x', 503, 'busy')]);
		const result = await withRetry(inner, { retries: 2, ...noSleep }).complete(request);
		expect(result.content).toBe('ok from main');
		expect(inner.models).toHaveLength(3);
	});

	test('gives up after the budget and never retries a 400', async () => {
		const tooMany = flaky([1, 2, 3].map(() => new ProviderError('x', 500, 'down')));
		await expect(withRetry(tooMany, { retries: 2, ...noSleep }).complete(request)).rejects.toThrow('down');
		expect(tooMany.models).toHaveLength(3);
		const bad = flaky([new ProviderError('x', 400, 'bad request')]);
		await expect(withRetry(bad, noSleep).complete(request)).rejects.toThrow('bad request');
		expect(bad.models).toHaveLength(1);
	});

	test('network errors retry; Retry-After sets the wait', async () => {
		const waits: number[] = [];
		const inner = flaky([
			Object.assign(new Error('refused'), { code: 'ConnectionRefused' }),
			new ProviderError('x', 429, 'slow', 1500),
		]);
		await withRetry(inner, { retries: 3, baseDelayMs: 100, sleep: async (ms) => void waits.push(ms) }).complete(request);
		expect(waits).toHaveLength(2);
		expect(waits[0]).toBeGreaterThanOrEqual(75);
		expect(waits[0]).toBeLessThanOrEqual(125);
		expect(waits[1]).toBe(1500);
	});

	test('aborting cuts a Retry-After wait short', async () => {
		const inner = flaky([new ProviderError('x', 429, 'slow down', 20_000), new ProviderError('x', 429, 'slow down', 20_000)]);
		const controller = new AbortController();
		setTimeout(() => controller.abort(new Error('stopping')), 20);
		const started = Date.now();
		await expect(withRetry(inner).complete({ ...request, signal: controller.signal })).rejects.toThrow('slow down');
		expect(Date.now() - started).toBeLessThan(1000);
		expect(inner.models).toHaveLength(1);
	});

	test('retryAfter reads seconds and dates', () => {
		expect(retryAfter(new Response(null, { headers: { 'retry-after': '3' } }))).toBe(3000);
		expect(retryAfter(new Response(null, { headers: { 'retry-after': 'Wed, 21 Oct 2015 07:28:00 GMT' } }))).toBe(0);
		expect(retryAfter(new Response(null))).toBeUndefined();
	});
});

describe('withTimeout', () => {
	const slow: Provider = {
		id: 'slow',
		complete: (req) =>
			new Promise((_, reject) => req.signal?.addEventListener('abort', () => reject(req.signal?.reason), { once: true })),
	};

	test('turns a hang into a ProviderError', async () => {
		const promise = withTimeout(slow, 20).complete(request);
		await expect(promise).rejects.toBeInstanceOf(ProviderError);
		await expect(promise).rejects.toThrow('no answer from main after 0.02s');
	});

	test('a caller abort stays an abort', async () => {
		const controller = new AbortController();
		const promise = withTimeout(slow, 5_000).complete({ ...request, signal: controller.signal });
		controller.abort();
		await expect(promise).rejects.not.toBeInstanceOf(ProviderError);
	});
});

describe('withFallback', () => {
	test('walks the chain and reports which model answered', async () => {
		const inner = flaky([new ProviderError('x', 500, 'down')]);
		const result = await withFallback(inner, [{ model: 'backup' }]).complete(request);
		expect(result).toMatchObject({ content: 'ok from backup', model: 'backup' });
		expect(inner.models).toEqual(['main', 'backup']);
	});

	test('can fall back to a different provider', async () => {
		const primary = flaky([new ProviderError('a', 401, 'bad key')], 'a');
		const other = flaky([], 'b');
		const result = await withFallback(primary, [{ provider: other, model: 'other-model' }]).complete(request);
		expect(result.content).toBe('ok from other-model');
	});

	test('an auth error skips fallbacks on the same provider', async () => {
		for (const status of [401, 403]) {
			const inner = flaky([new ProviderError('x', status, 'bad key')]);
			await expect(withFallback(inner, [{ model: 'backup' }]).complete(request)).rejects.toThrow('bad key');
			expect(inner.models).toEqual(['main']);
		}
	});

	test('404, 429, 5xx and timeouts still fall back', async () => {
		for (const status of [404, 429, 500, 503, null]) {
			const inner = flaky([new ProviderError('x', status, 'nope')]);
			expect((await withFallback(inner, [{ model: 'backup' }]).complete(request)).content).toBe('ok from backup');
		}
	});

	test('throws the last error when everything fails', async () => {
		const inner = flaky([new ProviderError('x', 500, 'first'), new ProviderError('x', 500, 'second')]);
		await expect(withFallback(inner, [{ model: 'b' }]).complete(request)).rejects.toThrow('second');
	});
});

describe('resilient', () => {
	test('retries each target before falling back', async () => {
		const inner = flaky([1, 2, 3].map(() => new ProviderError('x', 503, 'busy')));
		const provider = resilient(inner, { retries: 2, fallback: [{ model: 'backup' }], ...noSleep });
		expect((await provider.complete(request)).content).toBe('ok from backup');
		expect(inner.models).toEqual(['main', 'main', 'main', 'backup']);
		expect(provider.id).toBe('flaky');
		expect(provider.defaultModel).toBe('main');
	});

	test('a bad key fails once instead of retrying and falling back', async () => {
		const inner = flaky([new ProviderError('x', 401, 'bad key')]);
		const provider = resilient(inner, { retries: 2, fallback: [{ model: 'backup' }], ...noSleep });
		await expect(provider.complete(request)).rejects.toThrow('bad key');
		expect(inner.models).toEqual(['main']);
	});
});
