import { DEFAULT_TIMEOUT_MS, retry, type RetryOptions } from '../llm/middleware';
import { stripReasoning } from '../llm/reasoning';
import { ProviderError, type ChatMessage, type Provider } from '../llm/types';
import type { Usage } from '../llm/usage';
import { AiUnavailable, AudioTooLarge, type Ai, type AiAdapters, type Capability, type CapabilityInfo } from './types';

const HINTS: Record<Exclude<Capability, 'chat'>, string> = {
	embed: 'set HQ_EMBED_MODEL',
	transcribe: 'set HQ_STT_MODEL',
};

const EMBED_BATCH = 64;

const AUDIO_EXTENSIONS: Record<string, string> = {
	'audio/mpeg': 'mp3',
	'audio/mp3': 'mp3',
	'audio/mp4': 'm4a',
	'audio/m4a': 'm4a',
	'audio/x-m4a': 'm4a',
	'audio/wav': 'wav',
	'audio/wave': 'wav',
	'audio/x-wav': 'wav',
	'audio/webm': 'webm',
	'video/webm': 'webm',
	'audio/ogg': 'ogg',
	'audio/flac': 'flac',
	'audio/x-flac': 'flac',
	'video/mp4': 'mp4',
	'video/mpeg': 'mpeg',
};

const KNOWN_EXTENSIONS = new Set([...Object.values(AUDIO_EXTENSIONS), 'mpga', 'oga', 'opus', 'aac']);

function audioFilename(name: string | undefined, type: string): string {
	const base = name?.trim() || 'recording';
	const ext = AUDIO_EXTENSIONS[type.split(';')[0]!.trim().toLowerCase()];
	if (ext === undefined || KNOWN_EXTENSIONS.has(base.split('.').pop()!.toLowerCase())) return base;
	return `${base}.${ext}`;
}

type Timed = Exclude<Capability, 'chat'>;

export const AI_TIMEOUTS_MS: Record<Timed, number> = {
	embed: DEFAULT_TIMEOUT_MS,
	transcribe: 10 * 60_000,
};

export type AiOptions = {
	chat: Provider;
	chatModel?: string;
	adapters?: AiAdapters;
	usage?: Usage;
	retry?: RetryOptions;
	timeoutsMs?: Partial<Record<Timed, number>>;
};

export function createAi(options: AiOptions): Ai {
	const adapters = options.adapters ?? {};
	const chatModel = () => options.chatModel ?? options.chat.defaultModel;

	async function attempt<T>(
		capability: Timed,
		provider: string,
		model: string,
		work: (signal: AbortSignal | undefined) => Promise<T>,
		signal?: AbortSignal,
	): Promise<T> {
		const ms = options.timeoutsMs?.[capability] ?? AI_TIMEOUTS_MS[capability];
		if (ms <= 0) return work(signal);
		const timeout = AbortSignal.timeout(ms);
		try {
			return await work(signal === undefined ? timeout : AbortSignal.any([signal, timeout]));
		} catch (error) {
			if (timeout.aborted && signal?.aborted !== true) {
				throw new ProviderError(provider, null, `no answer from ${model} after ${ms / 1000}s`);
			}
			throw error;
		}
	}

	async function track<T>(
		capability: Timed,
		provider: string,
		model: string,
		work: (signal: AbortSignal | undefined) => Promise<T>,
		signal?: AbortSignal,
		tokens?: (result: T) => number | undefined,
	) {
		try {
			const result = await retry(() => attempt(capability, provider, model, work, signal), { ...options.retry, signal });
			options.usage?.record({ capability, provider, model, ok: true, inputTokens: tokens?.(result) });
			return result;
		} catch (error) {
			if (signal?.aborted !== true) options.usage?.record({ capability, provider, model, ok: false });
			throw error;
		}
	}

	function pick<K extends keyof AiAdapters>(capability: K, model: string | undefined) {
		const adapter = adapters[capability];
		if (adapter === undefined) throw new AiUnavailable(capability, HINTS[capability]);
		const resolved = model ?? adapter.defaultModel;
		if (resolved === undefined) throw new AiUnavailable(capability, `${adapter.id} has no default model`);
		return { adapter: adapter as NonNullable<AiAdapters[K]>, model: resolved };
	}

	return {
		has: (capability) => capability === 'chat' || adapters[capability] !== undefined,
		describe() {
			const info = (adapter: { id: string; defaultModel?: string } | undefined): CapabilityInfo | null =>
				adapter === undefined ? null : { provider: adapter.id, model: adapter.defaultModel ?? null };
			return {
				chat: { provider: options.chat.id, model: chatModel() ?? null },
				embed: info(adapters.embed),
				transcribe: info(adapters.transcribe),
			};
		},
		async chat(input, chatOptions = {}) {
			const model = chatOptions.model ?? chatModel();
			if (model === undefined) throw new AiUnavailable('chat', 'set HQ_LLM_MODEL');
			const messages: ChatMessage[] = typeof input === 'string' ? [{ role: 'user', content: input }] : input;
			const result = await options.chat.complete({
				model,
				messages: chatOptions.system === undefined ? messages : [{ role: 'system', content: chatOptions.system }, ...messages],
				temperature: chatOptions.temperature,
				maxTokens: chatOptions.maxTokens,
				signal: chatOptions.signal,
			});
			return stripReasoning(result.content);
		},
		async embed(input, embedOptions = {}) {
			const { adapter, model } = pick('embed', embedOptions.model);
			const vectors: number[][] = [];
			for (let i = 0; i < input.length; i += EMBED_BATCH) {
				const batch = input.slice(i, i + EMBED_BATCH);
				const result = await track(
					'embed',
					adapter.id,
					model,
					(signal) => adapter.embed({ model, input: batch, signal }),
					embedOptions.signal,
					(r) => r.usage?.inputTokens,
				);
				if (result.vectors.length !== batch.length) {
					throw new Error(`${adapter.id} returned ${result.vectors.length} vectors for ${batch.length} inputs`);
				}
				vectors.push(...result.vectors);
			}
			return vectors;
		},
		async transcribe(audio, { model: wanted, ...rest } = {}) {
			const { adapter, model } = pick('transcribe', wanted);
			if (audio.size === 0) throw new Error('the recording is empty');
			if (adapter.maxBytes !== undefined && audio.size > adapter.maxBytes) throw new AudioTooLarge(adapter.maxBytes);
			const filename = audioFilename(rest.filename ?? (audio instanceof File ? audio.name : undefined), audio.type);
			return track(
				'transcribe',
				adapter.id,
				model,
				(signal) => adapter.transcribe({ ...rest, filename, model, audio, signal }),
				rest.signal,
			);
		},
	};
}

export function cosine(a: number[], b: number[]): number {
	let dot = 0;
	let na = 0;
	let nb = 0;
	for (let i = 0; i < Math.min(a.length, b.length); i++) {
		dot += a[i]! * b[i]!;
		na += a[i]! * a[i]!;
		nb += b[i]! * b[i]!;
	}
	return na === 0 || nb === 0 ? 0 : dot / Math.sqrt(na * nb);
}
