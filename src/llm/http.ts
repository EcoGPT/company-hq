import { ProviderError } from './types';

export function retryAfter(response: Response): number | undefined {
	const raw = response.headers.get('retry-after');
	if (raw === null) return undefined;
	const seconds = Number(raw);
	if (Number.isFinite(seconds)) return Math.max(seconds, 0) * 1000;
	const at = Date.parse(raw);
	return Number.isNaN(at) ? undefined : Math.max(at - Date.now(), 0);
}

export async function providerFetch(
	provider: string,
	url: string,
	init: RequestInit,
	fetchImpl: typeof fetch = fetch,
): Promise<Response> {
	try {
		return await fetchImpl(url, init);
	} catch (error) {
		if (init.signal?.aborted) throw error;
		const reason = error instanceof Error ? error.message : String(error);
		throw new ProviderError(
			provider,
			null,
			`could not reach ${new URL(url).origin} (${reason}). Is the model server running?`,
			undefined,
			true,
		);
	}
}

export async function readProviderJson<T>(response: Response, provider: string): Promise<T> {
	const text = await response.text();
	let body: unknown;
	try {
		body = JSON.parse(text);
	} catch {
		throw new ProviderError(provider, response.status, `non-JSON response: ${text.slice(0, 200)}`, retryAfter(response));
	}
	if (!response.ok) {
		const error = (body as { error?: { message?: string } | string } | null)?.error;
		const message = typeof error === 'string' ? error : error?.message;
		throw new ProviderError(provider, response.status, message ?? `HTTP ${response.status}`, retryAfter(response));
	}
	return body as T;
}
