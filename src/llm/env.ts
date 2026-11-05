import { envNumber, type Env } from '../config';
import { anthropic } from './anthropic';
import { DEFAULT_RETRIES, DEFAULT_TIMEOUT_MS, type ResilienceOptions } from './middleware';
import { echo } from './mock';
import { openAICompatible } from './openai-compatible';
import type { Provider } from './types';

export const setting = (env: Env, name: string): string | undefined => env[name]?.trim() || undefined;

export function providerFromEnv(env: Env): Provider {
	const apiKey = setting(env, 'HQ_LLM_API_KEY');
	const baseUrl = setting(env, 'HQ_LLM_BASE_URL');
	const defaultModel = setting(env, 'HQ_LLM_MODEL');
	const kind = setting(env, 'HQ_LLM_PROVIDER') ?? (baseUrl === undefined ? 'mock' : 'openai-compatible');
	switch (kind) {
		case 'openai-compatible':
			if (baseUrl === undefined) throw new Error('HQ_LLM_BASE_URL is required for openai-compatible');
			return openAICompatible({ baseUrl, apiKey, defaultModel });
		case 'anthropic':
			if (apiKey === undefined) throw new Error('HQ_LLM_API_KEY is required for anthropic');
			return anthropic({ apiKey, baseUrl, defaultModel });
		case 'mock':
			return echo();
		default:
			throw new Error(`unknown HQ_LLM_PROVIDER: ${kind} (expected openai-compatible, anthropic or mock)`);
	}
}

export function resilienceFromEnv(env: Env): ResilienceOptions {
	return {
		timeoutMs: envNumber(env, 'HQ_LLM_TIMEOUT_MS', DEFAULT_TIMEOUT_MS),
		retries: envNumber(env, 'HQ_LLM_RETRIES', DEFAULT_RETRIES),
		fallback: (env.HQ_LLM_FALLBACK_MODEL ?? '')
			.split(',')
			.map((model) => model.trim())
			.filter((model) => model !== '')
			.map((model) => ({ model })),
	};
}
