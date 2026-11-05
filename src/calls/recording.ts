import { envNumber, type Env } from '../config';
import type { FileStore } from '../core/files';
import type { RecordingStore, Segment } from './recording-store';

/** The feed's audio: 16 kHz, mono, signed 16-bit little-endian. */
export const SAMPLE_RATE = 16_000;
const BYTES_PER_SECOND = SAMPLE_RATE * 2;
const BYTES_PER_MS = BYTES_PER_SECOND / 1000;
/** A stored piece holds at most this much audio (30 s), and is cut sooner at a gap. */
export const SEGMENT_BYTES = 30 * BYTES_PER_SECOND;
/** Audio that starts this long after where the last frame ended is a gap (a mute, a dropped feed): a new piece begins. */
export const GAP_MS = 500;
/**
 * Audio may run this far ahead of the receive clock: room for the burst that arrives after a network stall, with the speech
 * queued during it. Audio sent faster than people speak for longer than that is dropped.
 */
export const AHEAD_MS = 10_000;
/** How long a stopping server waits for call audio to reach disk. */
export const STOP_WAIT_MS = 5_000;
/** One seat's recording spans at most this long (4 h, a WAV of about 461 MB). Past it nothing more is kept. */
export const MAX_SEAT_MS = 4 * 3600_000;
export const DEFAULT_QUOTA_MB = 10_240;

export type RecordingOptions = {
	/** All call audio kept, in all calls together. Past it no new audio is stored. Default `HQ_CALLS_RECORDING_QUOTA_MB`. */
	quotaBytes?: number;
	maxSeatMs?: number;
	/** How long `stop` waits for audio still being written (default 5 s). */
	stopWaitMs?: number;
};

/** `HQ_CALLS_RECORDING_QUOTA_MB` in bytes (default 10,240 MB; 0 keeps no audio). */
export function recordingQuotaBytes(env: Env = process.env): number {
	return Math.max(0, envNumber(env, 'HQ_CALLS_RECORDING_QUOTA_MB', DEFAULT_QUOTA_MB)) * 1024 * 1024;
}

/** A seat: one device in one call, and the person it belongs to. */
export type SeatRef = { callId: string; deviceId: string; personId: string };

/** The piece of a seat's audio still in memory. */
type Take = SeatRef & { startedAt: number; end: number; chunks: Uint8Array<ArrayBuffer>[]; bytes: number; firstAt: number };

const seatKey = (callId: string, deviceId: string) => `${callId} ${deviceId}`;

export const segmentPath = (files: FileStore, s: Pick<Segment, 'call_id' | 'device_id' | 'id'>) =>
	files.path('calls', s.call_id, s.device_id, `${s.id}.pcm`);

/**
 * Turns each seat's feed into stored pieces. Time comes from when frames arrive: a frame of `n` bytes ends now and began
 * `n / 32` ms ago, and frames that follow on without a gap are laid end to end. A muted app sends nothing, so a mute is a
 * gap, and a gap starts a new piece. A piece is written when it reaches 30 s, at a gap, when its feed closes, when the
 * call ends and when the server stops; until then it is only in memory.
 */
export class Recorder {
	private readonly takes = new Map<string, Take>();
	private readonly writes = new Map<string, Set<Promise<void>>>();
	private writing = 0;
	/** Bytes of call audio on disk, counted once at start and kept up to date. */
	private stored: number;
	private readonly quotaBytes: number;
	private readonly maxSeatMs: number;
	private quotaLogged = false;
	private readonly capped = new Set<string>();
	/** When each seat's recording began, kept here as well, since a piece just cut may not be on disk yet. */
	private readonly firsts = new Map<string, number>();

	constructor(
		private readonly files: FileStore,
		private readonly store: RecordingStore,
		private readonly clock: () => number,
		private readonly log: (line: string) => void,
		options: RecordingOptions = {},
	) {
		this.quotaBytes = options.quotaBytes ?? recordingQuotaBytes();
		this.maxSeatMs = options.maxSeatMs ?? MAX_SEAT_MS;
		this.stored = store.totalBytes();
	}

	/** One frame of a seat's audio, received now. */
	audio(seat: SeatRef, pcm: Uint8Array): void {
		const at = this.clock();
		const ms = pcm.byteLength / BYTES_PER_MS;
		const key = seatKey(seat.callId, seat.deviceId);
		let take = this.takes.get(key);
		if (take !== undefined && at - ms > take.end + GAP_MS) {
			this.flush(seat.callId, seat.deviceId);
			take = undefined;
		}
		if (take === undefined) {
			const startedAt = at - ms;
			const firstAt = this.firsts.get(key) ?? this.store.firstAt(seat.callId, seat.deviceId) ?? startedAt;
			this.firsts.set(key, firstAt);
			take = { ...seat, startedAt, end: startedAt, chunks: [], bytes: 0, firstAt };
			this.takes.set(key, take);
		}
		if (take.end + ms > at + AHEAD_MS) return;
		if (take.end + ms - take.firstAt > this.maxSeatMs) {
			if (!this.capped.has(key))
				this.log(`[calls] call ${seat.callId}: a seat reached the recording length cap; no more of its audio is kept`);
			this.capped.add(key);
			return;
		}
		take.chunks.push(new Uint8Array(pcm));
		take.bytes += pcm.byteLength;
		take.end += ms;
		if (take.bytes >= SEGMENT_BYTES) {
			this.flush(seat.callId, seat.deviceId);
			// The next piece carries straight on from this one.
			this.takes.set(key, { ...seat, startedAt: take.end, end: take.end, chunks: [], bytes: 0, firstAt: take.firstAt });
		}
	}

	/** Writes the seat's piece in memory, if any. */
	flush(callId: string, deviceId: string): void {
		const key = seatKey(callId, deviceId);
		const take = this.takes.get(key);
		this.takes.delete(key);
		if (take === undefined || take.bytes === 0) return;
		if (this.stored + this.writing + take.bytes > this.quotaBytes) {
			if (!this.quotaLogged)
				this.log('[calls] the recording quota (HQ_CALLS_RECORDING_QUOTA_MB) is full; new call audio is not kept');
			this.quotaLogged = true;
			return;
		}
		this.writing += take.bytes;
		const id = crypto.randomUUID();
		const row = {
			id,
			call_id: callId,
			device_id: deviceId,
			person_id: take.personId,
			started_at: Math.round(take.startedAt),
			bytes: take.bytes,
		};
		const pending = this.writes.get(callId) ?? new Set();
		this.writes.set(callId, pending);
		const write: Promise<void> = this.files
			.save(segmentPath(this.files, row), new Blob(take.chunks).stream(), take.bytes, () => {
				this.store.addSegment(row);
				this.stored += row.bytes;
			})
			.then(
				() => {},
				(error: unknown) =>
					this.log(
						`[calls] call ${callId}: a piece of audio could not be written (${error instanceof Error ? error.name : 'error'})`,
					),
			)
			.finally(() => {
				this.writing -= take.bytes;
				pending.delete(write);
			});
		pending.add(write);
	}

	/** Writes every piece of the call still in memory and waits until all its audio is on disk. */
	async finish(callId: string): Promise<void> {
		for (const take of [...this.takes.values()]) if (take.callId === callId) this.flush(callId, take.deviceId);
		const pending = this.writes.get(callId);
		while (pending !== undefined && pending.size > 0) await Promise.all([...pending]);
		this.writes.delete(callId);
		for (const key of this.firsts.keys()) if (key.startsWith(`${callId} `)) this.firsts.delete(key);
	}

	/**
	 * The server is stopping: writes every piece still in memory and waits for all audio to reach disk, for at most
	 * `ms`. False if some was still being written.
	 */
	async save(ms: number): Promise<boolean> {
		for (const take of [...this.takes.values()]) this.flush(take.callId, take.deviceId);
		const writes = Promise.all([...this.writes.values()].flatMap((pending) => [...pending])).then(() => true);
		let timer: ReturnType<typeof setTimeout> | undefined;
		const late = new Promise<false>((resolve) => (timer = setTimeout(() => resolve(false), ms)));
		const done = await Promise.race([writes, late]);
		clearTimeout(timer);
		if (!done) this.log('[calls] stopped before all call audio was written');
		return done;
	}

	async idle(): Promise<void> {
		for (const callId of [...this.writes.keys()]) await this.finish(callId);
	}
}

/** The 44-byte header of a 16 kHz mono 16-bit WAV holding `dataBytes` of samples. */
export function wavHeader(dataBytes: number): Uint8Array<ArrayBuffer> {
	const header = new Uint8Array(44);
	const view = new DataView(header.buffer);
	const text = (at: number, value: string) => [...value].forEach((c, i) => view.setUint8(at + i, c.charCodeAt(0)));
	text(0, 'RIFF');
	view.setUint32(4, 36 + dataBytes, true);
	text(8, 'WAVE');
	text(12, 'fmt ');
	view.setUint32(16, 16, true);
	view.setUint16(20, 1, true);
	view.setUint16(22, 1, true);
	view.setUint32(24, SAMPLE_RATE, true);
	view.setUint32(28, BYTES_PER_SECOND, true);
	view.setUint16(32, 2, true);
	view.setUint16(34, 16, true);
	text(36, 'data');
	view.setUint32(40, dataBytes, true);
	return header;
}

type Piece = { silence: number } | { segment: Segment; from: number; to: number };

/**
 * How one seat's pieces lay out on its timeline from its first sample: silence for each gap, and where two pieces overlap
 * the later one starts where the earlier ended.
 */
export function layout(segments: Segment[]): { pieces: Piece[]; bytes: number } {
	const pieces: Piece[] = [];
	if (segments.length === 0) return { pieces, bytes: 0 };
	const origin = segments[0]!.started_at;
	let cursor = 0;
	for (const segment of segments) {
		const at = Math.round((segment.started_at - origin) * (SAMPLE_RATE / 1000)) * 2;
		if (at > cursor) pieces.push({ silence: at - cursor });
		const from = Math.max(0, cursor - at);
		if (from >= segment.bytes) continue;
		pieces.push({ segment, from, to: segment.bytes });
		cursor = at + segment.bytes;
	}
	return { pieces, bytes: cursor };
}

export const seconds = (bytes: number) => Math.round(bytes / BYTES_PER_SECOND);

const SILENCE = new Uint8Array(64 * 1024);

function* silence(bytes: number): Generator<Uint8Array> {
	for (let left = bytes; left > 0; left -= SILENCE.byteLength) yield SILENCE.subarray(0, Math.min(left, SILENCE.byteLength));
}

/** One seat's recording as a WAV, read from disk as it is sent. A piece missing from disk plays as silence. */
export function wavStream(files: FileStore, segments: Segment[]): { bytes: number; stream: ReadableStream<Uint8Array> } {
	const { pieces, bytes } = layout(segments);
	async function* body(): AsyncGenerator<Uint8Array> {
		yield wavHeader(bytes);
		for (const piece of pieces) {
			if ('silence' in piece) {
				yield* silence(piece.silence);
				continue;
			}
			const file = Bun.file(segmentPath(files, piece.segment));
			let sent = 0;
			if (await file.exists()) {
				const reader = file.slice(piece.from, piece.to).stream().getReader();
				for (let chunk = await reader.read(); !chunk.done; chunk = await reader.read()) {
					const part = chunk.value.subarray(0, piece.to - piece.from - sent);
					sent += part.byteLength;
					yield part;
				}
			}
			yield* silence(piece.to - piece.from - sent);
		}
	}
	const iterator = body();
	const stream = new ReadableStream<Uint8Array>({
		async pull(controller) {
			const next = await iterator.next();
			if (next.done) controller.close();
			else controller.enqueue(next.value);
		},
		async cancel() {
			await iterator.return(undefined);
		},
	});
	return { bytes: 44 + bytes, stream };
}
