import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import { newId } from '../core/ids';

/** After calls-core's `calls/001`. */
export const RECORDING_MIGRATIONS: Migration[] = [
	{
		// Each seat's audio is kept as raw 16 kHz mono 16-bit pieces of about 30 s, one file each, never deleted. A transcript
		// is a version: a call shows the one in `calls.transcript_id`, picked only once every piece of it was written down.
		id: 'calls/002_recordings',
		up: `CREATE TABLE call_segments (
			id TEXT PRIMARY KEY,
			call_id TEXT NOT NULL REFERENCES calls(id),
			device_id TEXT NOT NULL REFERENCES devices(id),
			person_id TEXT NOT NULL REFERENCES people(id),
			started_at INTEGER NOT NULL,
			bytes INTEGER NOT NULL CHECK (bytes > 0 AND bytes % 2 = 0)
		);
		CREATE INDEX call_segments_seat ON call_segments(call_id, device_id, started_at);
		CREATE TABLE call_transcripts (
			id TEXT PRIMARY KEY,
			call_id TEXT NOT NULL REFERENCES calls(id),
			state TEXT NOT NULL CHECK (state IN ('running', 'ready', 'failed')),
			pieces INTEGER NOT NULL DEFAULT 0,
			failed_pieces INTEGER NOT NULL DEFAULT 0,
			error TEXT,
			started_at INTEGER NOT NULL,
			finished_at INTEGER
		);
		CREATE INDEX call_transcripts_call ON call_transcripts(call_id, started_at);
		CREATE TABLE call_transcript_lines (
			transcript_id TEXT NOT NULL REFERENCES call_transcripts(id),
			seq INTEGER NOT NULL,
			person_id TEXT NOT NULL REFERENCES people(id),
			at_ms INTEGER NOT NULL,
			text TEXT NOT NULL,
			PRIMARY KEY (transcript_id, seq)
		);
		ALTER TABLE calls ADD COLUMN transcript_id TEXT REFERENCES call_transcripts(id);
		ALTER TABLE calls ADD COLUMN summary TEXT;
		ALTER TABLE calls ADD COLUMN recap_at INTEGER;`,
	},
	{
		// Who asked for a run: retranscribes are limited per call and per person, and the count has to outlive a restart.
		id: 'calls/003_retranscribe_requests',
		up: `ALTER TABLE call_transcripts ADD COLUMN requested_by TEXT REFERENCES people(id);
		CREATE INDEX call_transcripts_requested ON call_transcripts(requested_by, started_at) WHERE requested_by IS NOT NULL;`,
	},
];

/** Retranscribes allowed in a window, per call and per person. */
export type RetranscribeLimits = { perCall: number; perPerson: number; windowMs: number };

export type Segment = {
	id: string;
	call_id: string;
	device_id: string;
	person_id: string;
	/** Epoch milliseconds of the first sample, on the server's receive clock. */
	started_at: number;
	bytes: number;
};

export type TranscriptRun = {
	id: string;
	call_id: string;
	state: 'running' | 'ready' | 'failed';
	pieces: number;
	failed_pieces: number;
	error: string | null;
	started_at: number;
	finished_at: number | null;
};

export type Line = { person_id: string; at_ms: number; text: string };

export type CallRecap = { transcript_id: string | null; summary: string | null; recap_at: number | null };

export class RecordingStore {
	constructor(private readonly db: Database) {}

	addSegment(segment: Omit<Segment, 'id'> & { id?: string }): Segment {
		const row: Segment = { ...segment, id: segment.id ?? newId() };
		this.db
			.query(
				`INSERT INTO call_segments (id, call_id, device_id, person_id, started_at, bytes)
				VALUES ($id, $call_id, $device_id, $person_id, $started_at, $bytes)`,
			)
			.run(row);
		return row;
	}

	/** A call's audio, in time order across seats. */
	segments(callId: string, deviceId?: string): Segment[] {
		return this.db
			.query<Segment, { c: string; d: string | null }>(
				`SELECT * FROM call_segments WHERE call_id = $c AND ($d IS NULL OR device_id = $d) ORDER BY started_at, device_id, id`,
			)
			.all({ c: callId, d: deviceId ?? null });
	}

	/** When this seat's recording began, or null before its first stored piece. */
	firstAt(callId: string, deviceId: string): number | null {
		return this.db
			.query<{ at: number | null }, { c: string; d: string }>(
				'SELECT MIN(started_at) AS at FROM call_segments WHERE call_id = $c AND device_id = $d',
			)
			.get({ c: callId, d: deviceId })!.at;
	}

	/** Every byte of call audio on disk, in all calls: what the quota counts. */
	totalBytes(): number {
		return this.db.query<{ n: number }, []>('SELECT COALESCE(SUM(bytes), 0) AS n FROM call_segments').get()!.n;
	}

	recap(callId: string): CallRecap {
		return (
			this.db
				.query<CallRecap, { id: string }>('SELECT transcript_id, summary, recap_at FROM calls WHERE id = $id')
				.get({ id: callId }) ?? { transcript_id: null, summary: null, recap_at: null }
		);
	}

	/** A new transcript version, running. Null when one is already running for the call. */
	startTranscript(callId: string, at: number): string | null {
		return this.db.transaction(() => {
			if (this.running(callId)) return null;
			const id = newId();
			this.db
				.query(`INSERT INTO call_transcripts (id, call_id, state, started_at) VALUES ($id, $c, 'running', $at)`)
				.run({ id, c: callId, at });
			return id;
		})();
	}

	/**
	 * A run someone asked for: refused while one is running for the call, or when the call or the person has had their
	 * share of runs in the window. Counted from the runs themselves, so a restart forgets nothing.
	 */
	requestTranscript(
		callId: string,
		personId: string,
		at: number,
		limits: RetranscribeLimits,
	): { id: string } | { refused: 'running' | 'call' | 'person' } {
		return this.db.transaction(() => {
			if (this.running(callId)) return { refused: 'running' as const };
			const count = (where: string, value: string) =>
				this.db
					.query<{ n: number }, { v: string; since: number }>(
						`SELECT COUNT(*) AS n FROM call_transcripts WHERE ${where} = $v AND requested_by IS NOT NULL AND started_at > $since`,
					)
					.get({ v: value, since: at - limits.windowMs })!.n;
			if (count('call_id', callId) >= limits.perCall) return { refused: 'call' as const };
			if (count('requested_by', personId) >= limits.perPerson) return { refused: 'person' as const };
			const id = newId();
			this.db
				.query(`INSERT INTO call_transcripts (id, call_id, state, started_at, requested_by) VALUES ($id, $c, 'running', $at, $p)`)
				.run({ id, c: callId, at, p: personId });
			return { id };
		})();
	}

	running(callId: string): boolean {
		return (
			this.db
				.query<{ n: number }, { c: string }>(
					`SELECT COUNT(*) AS n FROM call_transcripts WHERE call_id = $c AND state = 'running'`,
				)
				.get({ c: callId })!.n > 0
		);
	}

	runs(callId: string): TranscriptRun[] {
		return this.db
			.query<TranscriptRun, { c: string }>('SELECT * FROM call_transcripts WHERE call_id = $c ORDER BY started_at, id')
			.all({ c: callId });
	}

	/** Every piece was written down: the lines are stored and this version becomes the call's transcript. */
	selectTranscript(id: string, callId: string, pieces: number, lines: Line[], at: number): void {
		this.db.transaction(() => {
			const insert = this.db.query(
				'INSERT INTO call_transcript_lines (transcript_id, seq, person_id, at_ms, text) VALUES ($t, $seq, $p, $at, $text)',
			);
			lines.forEach((line, seq) => insert.run({ t: id, seq, p: line.person_id, at: line.at_ms, text: line.text }));
			this.db
				.query(`UPDATE call_transcripts SET state = 'ready', pieces = $n, finished_at = $at WHERE id = $id`)
				.run({ id, n: pieces, at });
			this.db.query('UPDATE calls SET transcript_id = $id WHERE id = $c').run({ id, c: callId });
		})();
	}

	/** Some piece failed: this version is kept as a record of the failure and the call keeps the transcript it had. */
	failTranscript(id: string, pieces: number, failed: number, error: string, at: number): void {
		this.db
			.query(
				`UPDATE call_transcripts SET state = 'failed', pieces = $n, failed_pieces = $f, error = $e, finished_at = $at WHERE id = $id`,
			)
			.run({ id, n: pieces, f: failed, e: error, at });
	}

	/** A run the server was stopped in the middle of will never finish. */
	interrupted(at: number): number {
		return this.db
			.query(
				`UPDATE call_transcripts SET state = 'failed', error = 'the server stopped before it finished', finished_at = $at
				WHERE state = 'running'`,
			)
			.run({ at }).changes;
	}

	lines(transcriptId: string): Line[] {
		return this.db
			.query<Line, { t: string }>(
				'SELECT person_id, at_ms, text FROM call_transcript_lines WHERE transcript_id = $t ORDER BY seq',
			)
			.all({ t: transcriptId });
	}

	setRecap(callId: string, summary: string | null, at: number): void {
		this.db.query('UPDATE calls SET summary = $s, recap_at = $at WHERE id = $id').run({ id: callId, s: summary, at });
	}
}
