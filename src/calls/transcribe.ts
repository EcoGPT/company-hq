import type { Ai } from '../ai/types';
import { AudioTooLarge } from '../ai/types';
import type { FileStore } from '../core/files';
import { HttpError } from '../http/router';
import type { CallRecaps } from './recap';
import { segmentPath, wavHeader, type Recorder } from './recording';
import type { Line, RecordingStore, RetranscribeLimits, Segment } from './recording-store';
import type { CallStore } from './store';

/** Pieces sent to speech-to-text at once, per call. */
const PARALLEL = 2;
/** One line's text is cut here; a 30 s piece says far less. */
const MAX_LINE = 10_000;
/** Retranscribing waits this long after the end, so the last audio is on disk. */
export const RETRANSCRIBE_AFTER_MS = 3_000;
/** Each run sends the whole call to the host's speech-to-text again, which costs money: 3 an hour a call, 10 a person. */
export const RETRANSCRIBE_LIMITS: RetranscribeLimits = { perCall: 3, perPerson: 10, windowMs: 60 * 60_000 };

/**
 * After a call ends, each stored piece of each seat's audio goes to the host's speech-to-text as a WAV of its own, and its
 * text becomes a line by that seat's person, at the piece's start. The lines form one version; the call shows it only if
 * every piece was written down, and otherwise keeps the one it had and the failure is kept with the version.
 */
export class CallTranscripts {
	private readonly jobs = new Set<Promise<void>>();

	constructor(
		private readonly files: FileStore,
		private readonly ai: Ai,
		private readonly calls: CallStore,
		private readonly store: RecordingStore,
		private readonly recorder: Recorder,
		private readonly recaps: CallRecaps,
		private readonly clock: () => number,
		private readonly log: (line: string) => void,
	) {}

	get configured(): boolean {
		return this.ai.has('transcribe');
	}

	/** Runs after `call.ended`. Without speech-to-text the audio is still written and the transcript stays empty. */
	ended(callId: string): void {
		const id = this.configured ? this.store.startTranscript(callId, this.clock()) : null;
		this.track(id === null ? this.recorder.finish(callId) : this.run(callId, id));
	}

	/** `POST /v1/calls/:id/retranscribe`: a new version from the saved audio, then the recap again. Answers once started. */
	retranscribe(callId: string, personId: string): void {
		if (!this.configured) throw new HttpError(503, 'not_configured');
		const call = this.calls.get(callId);
		if (call === null) throw new HttpError(404, 'not_found');
		if (call.ended_at === null) throw new HttpError(409, 'call_live');
		if (this.clock() - call.ended_at < RETRANSCRIBE_AFTER_MS) throw new HttpError(409, 'too_soon');
		const run = this.store.requestTranscript(callId, personId, this.clock(), RETRANSCRIBE_LIMITS);
		if ('refused' in run) {
			if (run.refused === 'running') throw new HttpError(409, 'transcribing');
			throw new HttpError(429, 'too_many_retranscribes');
		}
		this.track(this.run(callId, run.id));
	}

	/** Marks runs a stopped server left behind as failed, so the call can be retranscribed. */
	recover(): void {
		const n = this.store.interrupted(this.clock());
		if (n > 0) this.log(`[calls] ${n} transcription run${n === 1 ? '' : 's'} stopped with the server; retranscribe to finish`);
	}

	async idle(): Promise<void> {
		while (this.jobs.size > 0) await Promise.all([...this.jobs]);
	}

	private track(job: Promise<void>): void {
		const done = job.catch((error: unknown) =>
			this.log(`[calls] after-call work failed: ${error instanceof Error ? error.name : 'error'}`),
		);
		this.jobs.add(done);
		void done.finally(() => this.jobs.delete(done));
	}

	private async run(callId: string, id: string): Promise<void> {
		await this.recorder.finish(callId);
		const segments = this.store.segments(callId);
		const lines: Line[] = [];
		const errors: string[] = [];
		let next = 0;
		const worker = async () => {
			while (next < segments.length) {
				const segment = segments[next++]!;
				try {
					lines.push(...(await this.piece(segment)));
				} catch (error) {
					errors.push(error instanceof Error ? `${error.name}: ${error.message}` : 'error');
				}
			}
		};
		await Promise.all(Array.from({ length: Math.min(PARALLEL, segments.length) }, worker));
		const at = this.clock();
		if (errors.length > 0) {
			this.store.failTranscript(id, segments.length, errors.length, errors[0]!.slice(0, 300), at);
			this.log(
				`[calls] call ${callId}: ${errors.length} of ${segments.length} pieces were not transcribed; the transcript was kept as it was`,
			);
			return;
		}
		lines.sort((a, b) => a.at_ms - b.at_ms || a.person_id.localeCompare(b.person_id));
		// A run that heard nothing does not replace one that heard something (a provider that answers "" for everything).
		const shown = this.store.recap(callId).transcript_id;
		if (lines.length === 0 && shown !== null && this.store.lines(shown).length > 0) {
			this.store.failTranscript(id, segments.length, 0, 'nothing was heard; the earlier transcript was kept', at);
			this.log(`[calls] call ${callId}: the new transcript was empty; the earlier one was kept`);
			return;
		}
		this.store.selectTranscript(id, callId, segments.length, lines, at);
		const call = this.calls.get(callId);
		if (call !== null) await this.recaps.run(call, lines);
	}

	/** One stored piece, as lines: one, or one per part if the provider takes less than a whole piece. */
	private async piece(segment: Segment): Promise<Line[]> {
		const file = Bun.file(segmentPath(this.files, segment));
		if (!(await file.exists()) || file.size < segment.bytes) throw new Error('a piece of audio is missing from disk');
		const parts = async (size: number): Promise<Line[]> => {
			const lines: Line[] = [];
			for (let from = 0; from < segment.bytes; from += size) {
				const to = Math.min(segment.bytes, from + size);
				const audio = new Blob([wavHeader(to - from), await file.slice(from, to).arrayBuffer()], { type: 'audio/wav' });
				const { text } = await this.ai.transcribe(audio, { filename: `${segment.id}.wav` });
				const said = text.trim().slice(0, MAX_LINE);
				if (said !== '')
					lines.push({ person_id: segment.person_id, at_ms: segment.started_at + Math.round(from / 32), text: said });
			}
			return lines;
		};
		try {
			return await parts(segment.bytes);
		} catch (error) {
			// Each WAV must stay under HQ_STT_MAX_MB: split the piece to fit and try once more.
			if (!(error instanceof AudioTooLarge) || error.maxBytes <= 44 + 2) throw error;
			return parts(Math.floor((error.maxBytes - 44) / 2) * 2);
		}
	}
}
