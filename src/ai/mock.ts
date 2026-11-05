import type { Embedder, TranscribeRequest, Transcriber } from './types';

export function hashVector(text: string, dimensions = 256): number[] {
	const vector = new Array<number>(dimensions).fill(0);
	for (const word of text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []) {
		const stem = word.length > 4 ? word.replace(/(ing|ed|es|s)$/, '') : word;
		vector[Number(BigInt(Bun.hash(stem)) % BigInt(dimensions))]! += 1;
	}
	const norm = Math.hypot(...vector);
	return norm === 0 ? vector : vector.map((v) => v / norm);
}

export function hashEmbedder(dimensions = 256): Embedder & { calls: string[][] } {
	const calls: string[][] = [];
	return {
		id: 'mock',
		defaultModel: `hash-${dimensions}`,
		calls,
		async embed({ input }) {
			calls.push([...input]);
			return { vectors: input.map((text) => hashVector(text, dimensions)) };
		},
	};
}

export function scriptedTranscriber(
	texts: (string | ((request: TranscribeRequest) => string))[] = [],
): Transcriber & { requests: TranscribeRequest[] } {
	const queue = [...texts];
	const requests: TranscribeRequest[] = [];
	return {
		id: 'mock',
		defaultModel: 'scripted',
		requests,
		async transcribe(request) {
			requests.push(request);
			const next = queue.shift();
			if (next === undefined)
				return { text: `(mock transcript of ${request.filename ?? 'a recording'}, ${request.audio.size} bytes)` };
			return { text: typeof next === 'function' ? next(request) : next };
		},
	};
}
