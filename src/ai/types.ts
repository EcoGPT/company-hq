import type { ChatMessage } from '../llm/types';

export type EmbedRequest = { model: string; input: string[]; signal?: AbortSignal };
export type EmbedResult = { vectors: number[][]; usage?: { inputTokens: number } };

export interface Embedder {
	readonly id: string;
	readonly defaultModel?: string;
	embed(request: EmbedRequest): Promise<EmbedResult>;
}

export type TranscribeRequest = {
	model: string;
	audio: Blob;
	filename?: string;
	language?: string;
	prompt?: string;
	signal?: AbortSignal;
};
export type TranscribeResult = { text: string; language?: string; durationSeconds?: number };

export interface Transcriber {
	readonly id: string;
	readonly defaultModel?: string;
	readonly maxBytes?: number;
	transcribe(request: TranscribeRequest): Promise<TranscribeResult>;
}

export type AiAdapters = {
	embed?: Embedder;
	transcribe?: Transcriber;
};

export type Capability = 'chat' | keyof AiAdapters;

export type CapabilityInfo = { provider: string; model: string | null };

export type ChatOptions = {
	system?: string;
	model?: string;
	temperature?: number;
	maxTokens?: number;
	signal?: AbortSignal;
};

export type Ai = {
	has(capability: Capability): boolean;
	describe(): Record<Capability, CapabilityInfo | null>;
	chat(input: string | ChatMessage[], options?: ChatOptions): Promise<string>;
	embed(input: string[], options?: { model?: string; signal?: AbortSignal }): Promise<number[][]>;
	transcribe(audio: Blob, options?: Omit<TranscribeRequest, 'audio' | 'model'> & { model?: string }): Promise<TranscribeResult>;
};

export class AiUnavailable extends Error {
	constructor(
		readonly capability: Capability,
		hint: string,
	) {
		super(`${capability} is not configured (${hint})`);
	}
}

export class AudioTooLarge extends Error {
	constructor(readonly maxBytes: number) {
		super(`the recording is over ${+(maxBytes / 1024 / 1024).toFixed(1)} MB, the speech-to-text limit (HQ_STT_MAX_MB)`);
	}
}

export function defineEmbedder(embedder: Embedder): Embedder {
	return embedder;
}

export function defineTranscriber(transcriber: Transcriber): Transcriber {
	return transcriber;
}
