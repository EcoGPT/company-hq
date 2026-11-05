import { describe, expect, test } from 'bun:test';
import { aiFromEnv, AiUnavailable, AudioTooLarge, createAi, openAICompatibleTranscriber, scriptedTranscriber } from '../src/ai';
import { createHq } from '../src/hq';
import { echo } from '../src/llm';
import { fakeFetch } from './helpers';

describe('speech-to-text', () => {
	test('uploads multipart to /audio/transcriptions', async () => {
		const { impl, calls } = fakeFetch(() => ({ text: ' Hello team. ', language: 'en', duration: 2.5 }));
		const stt = openAICompatibleTranscriber({ baseUrl: 'http://stt/v1', apiKey: 'k', fetch: impl });
		const result = await stt.transcribe({
			model: 'whisper-1',
			audio: new Blob(['RIFF....']),
			filename: 'standup.wav',
			language: 'en',
		});
		expect(result).toEqual({ text: 'Hello team.', language: 'en', durationSeconds: 2.5 });
		expect(calls[0]?.url).toBe('http://stt/v1/audio/transcriptions');
		const headers = calls[0]?.init.headers as Record<string, string>;
		expect(headers['content-type']).toBeUndefined();
		expect(headers.authorization).toBe('Bearer k');
		const form = calls[0]?.init.body as FormData;
		expect(form.get('model')).toBe('whisper-1');
		expect(form.get('language')).toBe('en');
		expect((form.get('file') as File).name).toBe('standup.wav');
	});

	test('through ai.transcribe, with usage and an empty-file guard', async () => {
		const hq = createHq({ ai: { transcribe: scriptedTranscriber(['We ship Friday.']) } });
		expect(await hq.ai.transcribe(new Blob(['abc']), { filename: 'a.m4a' })).toEqual({ text: 'We ship Friday.' });
		await expect(hq.ai.transcribe(new Blob([]))).rejects.toThrow('empty');
		expect(hq.usage.totals()).toMatchObject([{ capability: 'transcribe', calls: 1 }]);
	});

	test('names the upload from its content type and refuses files over the limit', async () => {
		const { impl, calls } = fakeFetch(() => ({ text: 'hi' }));
		const stt = openAICompatibleTranscriber({ baseUrl: 'http://stt/v1', defaultModel: 'whisper-1', fetch: impl });
		const ai = createAi({ chat: echo(), adapters: { transcribe: stt } });
		await ai.transcribe(new Blob(['abc'], { type: 'audio/webm;codecs=opus' }));
		await ai.transcribe(new File(['abc'], 'blob', { type: 'audio/x-m4a' }));
		await ai.transcribe(new Blob(['abc'], { type: 'audio/wav' }), { filename: 'standup.mp3' });
		await ai.transcribe(new Blob(['abc'], { type: 'audio/ogg' }), { filename: 'Sync 10.27' });
		expect(calls.map((c) => ((c.init.body as FormData).get('file') as File).name)).toEqual([
			'recording.webm',
			'blob.m4a',
			'standup.mp3',
			'Sync 10.27.ogg',
		]);
		expect(stt.maxBytes).toBe(25 * 1024 * 1024);
		expect(aiFromEnv({ HQ_STT_BASE_URL: 'http://stt', HQ_STT_MODEL: 'w', HQ_STT_MAX_MB: '100' }).transcribe?.maxBytes).toBe(
			100 * 1024 * 1024,
		);
		expect(aiFromEnv({ HQ_STT_BASE_URL: 'http://stt', HQ_STT_MODEL: 'w', HQ_STT_MAX_MB: '0' }).transcribe?.maxBytes).toBe(
			Infinity,
		);
		const small = createAi({ chat: echo(), adapters: { transcribe: { ...stt, maxBytes: 2 } } });
		await expect(small.transcribe(new Blob(['abc']))).rejects.toBeInstanceOf(AudioTooLarge);
		expect(calls).toHaveLength(4);
	});

	test('is off until a model is set', async () => {
		await expect(createAi({ chat: echo() }).transcribe(new Blob(['x']))).rejects.toBeInstanceOf(AiUnavailable);
		expect(
			aiFromEnv({ HQ_LLM_BASE_URL: 'http://groq/openai/v1', HQ_STT_MODEL: 'whisper-large-v3' }).transcribe?.defaultModel,
		).toBe('whisper-large-v3');
	});
});
