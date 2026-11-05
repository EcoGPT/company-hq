import { describe, expect, test } from 'bun:test';
import { z } from 'zod';
import {
	aiFromEnv,
	AiUnavailable,
	cosine,
	createAi,
	endpointFromEnv,
	hashEmbedder,
	hashVector,
	openAICompatibleEmbedder,
} from '../src/ai';
import { defineApp } from '../src/apps/define';
import { createHq } from '../src/hq';
import { echo } from '../src/llm';
import { ProviderError } from '../src/llm/types';
import { defineTool } from '../src/tools/define';
import { fakeFetch } from './helpers';

describe('AI capabilities from env', () => {
	test('nothing set means only chat', () => {
		expect(aiFromEnv({})).toEqual({});
		expect(createAi({ chat: echo() }).describe()).toEqual({
			chat: { provider: 'mock', model: 'echo' },
			embed: null,
			transcribe: null,
		});
	});

	test('a model turns a capability on and borrows the chat endpoint and key', () => {
		expect(endpointFromEnv({ HQ_LLM_BASE_URL: 'http://llm/v1', HQ_LLM_API_KEY: 'sk', HQ_EMBED_MODEL: 'nomic' }, 'EMBED')).toEqual(
			{ baseUrl: 'http://llm/v1', apiKey: 'sk', defaultModel: 'nomic' },
		);
	});

	test('the chat key never travels to a different host', () => {
		const env = {
			HQ_LLM_BASE_URL: 'http://llm/v1',
			HQ_LLM_API_KEY: 'sk',
			HQ_EMBED_MODEL: 'm',
			HQ_EMBED_BASE_URL: 'http://other/v1',
		};
		expect(endpointFromEnv(env, 'EMBED')).toEqual({ baseUrl: 'http://other/v1', apiKey: undefined, defaultModel: 'm' });
		expect(() =>
			endpointFromEnv({ HQ_LLM_PROVIDER: 'anthropic', HQ_LLM_BASE_URL: 'http://gw', HQ_EMBED_MODEL: 'm' }, 'EMBED'),
		).toThrow('HQ_EMBED_BASE_URL is required');
	});

	test('the provider can be mock or none; anything else is an error', () => {
		expect(aiFromEnv({ HQ_EMBED_PROVIDER: 'mock' }).embed?.id).toBe('mock');
		expect(aiFromEnv({ HQ_EMBED_PROVIDER: 'none', HQ_EMBED_MODEL: 'm', HQ_LLM_BASE_URL: 'http://x' })).toEqual({});
		expect(() => aiFromEnv({ HQ_EMBED_PROVIDER: 'carrier-pigeon' })).toThrow('carrier-pigeon');
	});
});

describe('openAICompatibleEmbedder', () => {
	test('posts to /embeddings and keeps input order', async () => {
		const { impl, calls } = fakeFetch(() =>
			Response.json({
				data: [
					{ index: 1, embedding: [0, 1] },
					{ index: 0, embedding: [1, 0] },
				],
				usage: { prompt_tokens: 7 },
			}),
		);
		const embedder = openAICompatibleEmbedder({ baseUrl: 'http://e/v1/', apiKey: 'k', fetch: impl });
		const result = await embedder.embed({ model: 'm', input: ['a', 'b'] });
		expect(calls[0]?.url).toBe('http://e/v1/embeddings');
		expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ model: 'm', input: ['a', 'b'] });
		expect((calls[0]?.init.headers as Record<string, string>).authorization).toBe('Bearer k');
		expect(result).toEqual({
			vectors: [
				[1, 0],
				[0, 1],
			],
			usage: { inputTokens: 7 },
		});
	});

	test('errors are ProviderErrors', async () => {
		const { impl } = fakeFetch(() => Response.json({ error: { message: 'no such model' } }, { status: 404 }));
		await expect(
			openAICompatibleEmbedder({ baseUrl: 'http://e', fetch: impl }).embed({ model: 'm', input: ['a'] }),
		).rejects.toBeInstanceOf(ProviderError);
	});
});

describe('createAi', () => {
	test('embeds in batches and tallies usage', async () => {
		const hq = createHq();
		const embedder = hashEmbedder(8);
		const ai = createAi({ chat: echo(), adapters: { embed: embedder }, usage: hq.usage });
		const vectors = await ai.embed(Array.from({ length: 70 }, (_, i) => `doc ${i}`));
		expect(vectors).toHaveLength(70);
		expect(embedder.calls.map((c) => c.length)).toEqual([64, 6]);
		expect(hq.usage.totals()).toMatchObject([{ capability: 'embed', provider: 'mock', model: 'hash-8', calls: 2 }]);
	});

	test('unconfigured capabilities say how to turn them on', async () => {
		const ai = createAi({ chat: echo() });
		expect(ai.has('chat')).toBe(true);
		expect(ai.has('embed')).toBe(false);
		await expect(ai.embed(['x'])).rejects.toBeInstanceOf(AiUnavailable);
		await expect(ai.embed(['x'])).rejects.toThrow('embed is not configured (set HQ_EMBED_MODEL)');
	});

	test('transient embedding failures retry', async () => {
		let calls = 0;
		const ai = createAi({
			chat: echo(),
			retry: { sleep: async () => {} },
			adapters: {
				embed: {
					id: 'flaky',
					defaultModel: 'm',
					async embed({ input }) {
						if (++calls === 1) throw new ProviderError('flaky', 503, 'busy');
						return { vectors: input.map(() => [1]) };
					},
				},
			},
		});
		expect(await ai.embed(['a'])).toEqual([[1]]);
		expect(calls).toBe(2);
	});

	test('a hung embedding server times out instead of blocking forever', async () => {
		const ai = createAi({
			chat: echo(),
			timeoutsMs: { embed: 20 },
			adapters: {
				embed: {
					id: 'stuck',
					defaultModel: 'm',
					embed: ({ signal }) =>
						new Promise((_, reject) => signal?.addEventListener('abort', () => reject(signal.reason), { once: true })),
				},
			},
		});
		await expect(ai.embed(['a'])).rejects.toThrow('stuck: no answer from m after 0.02s');
	});

	test('chat takes a prompt, adds the system message and drops reasoning', async () => {
		const ai = createAi({
			chat: {
				id: 't',
				defaultModel: 'm',
				complete: async (r) => ({
					content: `<think>hmm</think> ${r.messages.map((m) => m.role).join(',')}`,
					toolCalls: [],
					finishReason: 'stop',
				}),
			},
		});
		expect(await ai.chat('hi', { system: 'be brief' })).toBe('system,user');
	});

	test('hash vectors put related text closer', () => {
		const launch = hashVector('We launch the beta on Friday');
		expect(cosine(launch, hashVector('when is the launch?'))).toBeGreaterThan(
			cosine(launch, hashVector('lunch menu for the offsite')),
		);
	});
});

describe('apps and tools see ai', () => {
	test('through AppContext and ToolContext', async () => {
		const seen: boolean[] = [];
		const app = defineApp({
			slug: 'probe',
			name: 'Probe',
			description: 'd',
			tools: [defineTool({ name: 'probe', description: 'p', input: z.object({}), run: (_, { ai }) => ai?.has('embed') })],
			setup: (ctx) => void seen.push(ctx.ai.has('embed')),
		});
		const hq = createHq({ apps: [app], ai: { embed: hashEmbedder() } });
		expect(seen).toEqual([true]);
		expect(await hq.registry.call('probe', {}, { hub: hq.hub, caller: hq.assistant.self })).toEqual({ ok: true, value: true });
	});
});
