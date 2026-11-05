import { envNumber, type Env } from '../config';
import { setting } from '../llm/env';
import type { OpenAICompatibleOptions } from '../llm/openai-compatible';
import { hashEmbedder, scriptedTranscriber } from './mock';
import { openAICompatibleEmbedder, openAICompatibleTranscriber } from './openai-compatible';
import type { AiAdapters } from './types';

export function endpointFromEnv(env: Env, prefix: string): OpenAICompatibleOptions | 'mock' | null {
	const kind = setting(env, `HQ_${prefix}_PROVIDER`);
	const model = setting(env, `HQ_${prefix}_MODEL`);
	if (kind === 'mock') return 'mock';
	if (kind === 'none' || (kind === undefined && model === undefined)) return null;
	if (kind !== undefined && kind !== 'openai-compatible') {
		throw new Error(`unknown HQ_${prefix}_PROVIDER: ${kind} (expected openai-compatible, mock or none)`);
	}
	const own = setting(env, `HQ_${prefix}_BASE_URL`);
	const chatIsCompatible = (setting(env, 'HQ_LLM_PROVIDER') ?? 'openai-compatible') === 'openai-compatible';
	const inherited = own === undefined && chatIsCompatible ? setting(env, 'HQ_LLM_BASE_URL') : undefined;
	const baseUrl = own ?? inherited;
	if (baseUrl === undefined) throw new Error(`HQ_${prefix}_BASE_URL is required for HQ_${prefix}_MODEL`);
	return {
		baseUrl,
		apiKey: setting(env, `HQ_${prefix}_API_KEY`) ?? (inherited === undefined ? undefined : setting(env, 'HQ_LLM_API_KEY')),
		defaultModel: model,
	};
}

export function aiFromEnv(env: Env): AiAdapters {
	const adapters: AiAdapters = {};
	const embed = endpointFromEnv(env, 'EMBED');
	if (embed === 'mock') adapters.embed = hashEmbedder();
	else if (embed !== null) adapters.embed = openAICompatibleEmbedder(embed);
	const stt = endpointFromEnv(env, 'STT');
	if (stt === 'mock') adapters.transcribe = scriptedTranscriber();
	else if (stt !== null) {
		const maxMb = envNumber(env, 'HQ_STT_MAX_MB', 25);
		adapters.transcribe = openAICompatibleTranscriber({ ...stt, maxBytes: maxMb > 0 ? maxMb * 1024 * 1024 : Infinity });
	}
	return adapters;
}
