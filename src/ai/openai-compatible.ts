import { post, type OpenAICompatibleOptions } from '../llm/openai-compatible';
import type { Embedder, Transcriber } from './types';

const ID = 'openai-compatible';

type EmbeddingsResponse = { data?: { index?: number; embedding: number[] }[]; usage?: { prompt_tokens?: number } };

export function openAICompatibleEmbedder(options: OpenAICompatibleOptions): Embedder {
	return {
		id: ID,
		defaultModel: options.defaultModel,
		async embed({ model, input, signal }) {
			const body = await post<EmbeddingsResponse>(options, '/embeddings', { json: { model, input } }, signal);
			const data = [...(body.data ?? [])].sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
			return {
				vectors: data.map((d) => d.embedding),
				...(body.usage?.prompt_tokens === undefined ? {} : { usage: { inputTokens: body.usage.prompt_tokens } }),
			};
		},
	};
}

type TranscriptionResponse = { text?: string; language?: string; duration?: number };

export function openAICompatibleTranscriber(options: OpenAICompatibleOptions & { maxBytes?: number }): Transcriber {
	return {
		id: ID,
		defaultModel: options.defaultModel,
		maxBytes: options.maxBytes ?? 25 * 1024 * 1024,
		async transcribe({ model, audio, filename, language, prompt, signal }) {
			const form = new FormData();
			const name = filename ?? (audio instanceof File ? audio.name : 'recording');
			form.append('file', new Blob([await audio.arrayBuffer()], { type: audio.type }), name);
			form.append('model', model);
			form.append('response_format', 'json');
			if (language !== undefined) form.append('language', language);
			if (prompt !== undefined) form.append('prompt', prompt);
			const body = await post<TranscriptionResponse>(options, '/audio/transcriptions', { form }, signal);
			return {
				text: (body.text ?? '').trim(),
				...(body.language === undefined ? {} : { language: body.language }),
				...(body.duration === undefined ? {} : { durationSeconds: body.duration }),
			};
		},
	};
}
