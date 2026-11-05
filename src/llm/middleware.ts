import { ProviderError, type CompletionRequest, type CompletionResult, type Provider } from './types';

export type RetryOptions = {
	retries?: number;
	baseDelayMs?: number;
	maxDelayMs?: number;
	sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
};

export type FallbackTarget = { model: string; provider?: Provider };

export type ResilienceOptions = RetryOptions & {
	timeoutMs?: number;
	fallback?: FallbackTarget[];
	meter?: (provider: Provider) => Provider;
};

export const DEFAULT_TIMEOUT_MS = 120_000;
export const DEFAULT_RETRIES = 2;

const wait = (ms: number, signal?: AbortSignal) =>
	new Promise<void>((resolve) => {
		const done = () => {
			clearTimeout(timer);
			signal?.removeEventListener('abort', done);
			resolve();
		};
		const timer = setTimeout(done, ms);
		signal?.addEventListener('abort', done, { once: true });
	});

function wrap(provider: Provider, complete: (request: CompletionRequest) => Promise<CompletionResult>): Provider {
	return { id: provider.id, defaultModel: provider.defaultModel, complete };
}

export function isRetryable(error: unknown): boolean {
	if (error instanceof ProviderError) {
		return error.unreachable || error.status === 408 || error.status === 429 || (error.status !== null && error.status >= 500);
	}
	return typeof (error as { code?: unknown } | null)?.code === 'string';
}

const isAuthError = (error: unknown) => error instanceof ProviderError && (error.status === 401 || error.status === 403);

export function withTimeout(provider: Provider, timeoutMs: number): Provider {
	if (timeoutMs <= 0) return provider;
	return wrap(provider, async (request) => {
		const timeout = AbortSignal.timeout(timeoutMs);
		const signal = request.signal === undefined ? timeout : AbortSignal.any([request.signal, timeout]);
		try {
			return await provider.complete({ ...request, signal });
		} catch (error) {
			if (timeout.aborted && request.signal?.aborted !== true) {
				throw new ProviderError(provider.id, null, `no answer from ${request.model} after ${timeoutMs / 1000}s`);
			}
			throw error;
		}
	});
}

export async function retry<T>(work: () => Promise<T>, options: RetryOptions & { signal?: AbortSignal } = {}): Promise<T> {
	const retries = options.retries ?? DEFAULT_RETRIES;
	const base = options.baseDelayMs ?? 500;
	const max = options.maxDelayMs ?? 20_000;
	const sleep = options.sleep ?? wait;
	const aborted = () => options.signal?.aborted === true;
	for (let attempt = 0; ; attempt++) {
		try {
			return await work();
		} catch (error) {
			if (attempt >= retries || aborted() || !isRetryable(error)) throw error;
			const hinted = error instanceof ProviderError ? error.retryAfterMs : undefined;
			const backoff = base * 2 ** attempt * (0.75 + Math.random() / 2);
			await sleep(Math.min(hinted ?? backoff, max), options.signal);
			if (aborted()) throw error;
		}
	}
}

export function withRetry(provider: Provider, options: RetryOptions = {}): Provider {
	if ((options.retries ?? DEFAULT_RETRIES) <= 0) return provider;
	return wrap(provider, (request) => retry(() => provider.complete(request), { ...options, signal: request.signal }));
}

export function withFallback(provider: Provider, chain: FallbackTarget[]): Provider {
	if (chain.length === 0) return provider;
	return wrap(provider, async (request) => {
		const targets = [
			{ provider, model: request.model },
			...chain.map((t) => ({ provider: t.provider ?? provider, model: t.model })),
		];
		const refused = new Set<Provider>();
		let lastError: unknown;
		for (const [i, target] of targets.entries()) {
			if (refused.has(target.provider)) continue;
			try {
				const result = await target.provider.complete({ ...request, model: target.model });
				return { ...result, model: result.model ?? target.model };
			} catch (error) {
				if (request.signal?.aborted === true) throw error;
				lastError = error;
				if (isAuthError(error)) refused.add(target.provider);
				const next = targets.slice(i + 1).find((t) => !refused.has(t.provider));
				if (next !== undefined) {
					console.warn(`[llm] ${target.model} failed (${error instanceof Error ? error.message : error}); trying ${next.model}`);
				}
			}
		}
		throw lastError;
	});
}

export function resilient(provider: Provider, options: ResilienceOptions = {}): Provider {
	const meter = options.meter ?? ((p: Provider) => p);
	const guard = (p: Provider) => withRetry(meter(withTimeout(p, options.timeoutMs ?? DEFAULT_TIMEOUT_MS)), options);
	return withFallback(
		guard(provider),
		(options.fallback ?? []).map((t) => (t.provider === undefined ? t : { ...t, provider: guard(t.provider) })),
	);
}
