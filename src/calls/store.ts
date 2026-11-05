import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import { newId } from '../core/ids';

/** Ids start at `calls/001`. */
export const CALL_MIGRATIONS: Migration[] = [
	{
		// A call happens in one conversation; a meeting's call happens in the meeting's room. One seat per device: a rejoin
		// reuses the row and counts up `generation`. Tracks are what each seat sends, named `<device_id>-<source>`; pulls are
		// the other devices' tracks it receives, kept so a seat that goes stops receiving them at the relay.
		id: 'calls/001_calls',
		up: `CREATE TABLE calls (
			id TEXT PRIMARY KEY,
			conversation_id TEXT NOT NULL REFERENCES conversations(id),
			kind TEXT NOT NULL CHECK (kind IN ('conversation', 'meeting')),
			meeting_id TEXT,
			title TEXT,
			started_by TEXT NOT NULL REFERENCES people(id),
			started_at INTEGER NOT NULL,
			ended_at INTEGER
		);
		CREATE INDEX calls_live ON calls(conversation_id, meeting_id) WHERE ended_at IS NULL;
		CREATE INDEX calls_conversation ON calls(conversation_id, started_at);
		CREATE TABLE call_seats (
			call_id TEXT NOT NULL REFERENCES calls(id),
			device_id TEXT NOT NULL REFERENCES devices(id),
			person_id TEXT NOT NULL REFERENCES people(id),
			session_id TEXT,
			generation INTEGER NOT NULL,
			is_muted INTEGER NOT NULL DEFAULT 0,
			is_camera_on INTEGER NOT NULL DEFAULT 0,
			is_screen_sharing INTEGER NOT NULL DEFAULT 0,
			is_hand_raised INTEGER NOT NULL DEFAULT 0,
			joined_at INTEGER NOT NULL,
			left_at INTEGER,
			last_seen_at INTEGER NOT NULL,
			PRIMARY KEY (call_id, device_id)
		);
		CREATE INDEX call_seats_present ON call_seats(device_id) WHERE left_at IS NULL;
		CREATE TABLE call_tracks (
			id INTEGER PRIMARY KEY,
			call_id TEXT NOT NULL REFERENCES calls(id),
			device_id TEXT NOT NULL REFERENCES devices(id),
			person_id TEXT NOT NULL REFERENCES people(id),
			session_id TEXT NOT NULL,
			track_name TEXT NOT NULL,
			source TEXT NOT NULL CHECK (source IN ('mic', 'cam', 'screen')),
			mid TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			ended_at INTEGER
		);
		CREATE INDEX call_tracks_live ON call_tracks(call_id, device_id) WHERE ended_at IS NULL;
		CREATE TABLE call_pulls (
			id INTEGER PRIMARY KEY,
			call_id TEXT NOT NULL REFERENCES calls(id),
			device_id TEXT NOT NULL REFERENCES devices(id),
			session_id TEXT NOT NULL,
			mid TEXT NOT NULL,
			track_name TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			ended_at INTEGER
		);
		CREATE INDEX call_pulls_live ON call_pulls(call_id, device_id) WHERE ended_at IS NULL;
		CREATE TABLE call_rings (
			call_id TEXT NOT NULL REFERENCES calls(id),
			person_id TEXT NOT NULL REFERENCES people(id),
			state TEXT NOT NULL CHECK (state IN ('ringing', 'answered', 'declined', 'missed', 'ended')),
			created_at INTEGER NOT NULL,
			expires_at INTEGER NOT NULL,
			resolved_at INTEGER,
			PRIMARY KEY (call_id, person_id)
		);
		CREATE INDEX call_rings_live ON call_rings(person_id) WHERE state = 'ringing';`,
	},
];

export type CallKind = 'conversation' | 'meeting';
export type Source = 'mic' | 'cam' | 'screen';

export type CallRow = {
	id: string;
	conversation_id: string;
	kind: CallKind;
	meeting_id: string | null;
	title: string | null;
	started_by: string;
	started_at: number;
	ended_at: number | null;
};

export type Seat = {
	call_id: string;
	device_id: string;
	person_id: string;
	session_id: string | null;
	generation: number;
	is_muted: number;
	is_camera_on: number;
	is_screen_sharing: number;
	is_hand_raised: number;
	joined_at: number;
	left_at: number | null;
	last_seen_at: number;
};

export type Track = {
	id: number;
	call_id: string;
	device_id: string;
	person_id: string;
	session_id: string;
	track_name: string;
	source: Source;
	mid: string;
	created_at: number;
	ended_at: number | null;
};

/** A transceiver on one relay session: a track a seat sends, or one it pulls. */
export type Mid = { session_id: string; mid: string };

export type RingState = 'ringing' | 'answered' | 'declined' | 'missed' | 'ended';

export type Ring = {
	call_id: string;
	person_id: string;
	state: RingState;
	created_at: number;
	expires_at: number;
	resolved_at: number | null;
};

export const FLAGS = ['is_muted', 'is_camera_on', 'is_screen_sharing', 'is_hand_raised'] as const;
export type Flags = Partial<Record<(typeof FLAGS)[number], boolean>>;

/** The flag that shows a quiet track in the roster. A microphone track always shows. */
export const FLAG_OF: Record<Source, 'is_camera_on' | 'is_screen_sharing' | null> = {
	mic: null,
	cam: 'is_camera_on',
	screen: 'is_screen_sharing',
};

export class CallStore {
	constructor(private readonly db: Database) {}

	get(id: string): CallRow | null {
		return this.db.query<CallRow, { id: string }>('SELECT * FROM calls WHERE id = $id').get({ id });
	}

	/** The live meeting call held in this room, if any. */
	liveMeetingIn(conversationId: string): CallRow | null {
		return this.db
			.query<CallRow, { c: string }>(
				'SELECT * FROM calls WHERE conversation_id = $c AND meeting_id IS NOT NULL AND ended_at IS NULL ORDER BY started_at LIMIT 1',
			)
			.get({ c: conversationId });
	}

	live(conversationId: string, meetingId: string | null): CallRow | null {
		return this.db
			.query<CallRow, { c: string; m: string | null }>(
				'SELECT * FROM calls WHERE conversation_id = $c AND meeting_id IS $m AND ended_at IS NULL ORDER BY started_at LIMIT 1',
			)
			.get({ c: conversationId, m: meetingId });
	}

	liveCalls(): CallRow[] {
		return this.db.query<CallRow, []>('SELECT * FROM calls WHERE ended_at IS NULL').all();
	}

	create(input: Omit<CallRow, 'id' | 'ended_at'>): CallRow {
		const call: CallRow = { id: newId(), ...input, ended_at: null };
		this.db
			.query(
				`INSERT INTO calls (id, conversation_id, kind, meeting_id, title, started_by, started_at)
				VALUES ($id, $conversation_id, $kind, $meeting_id, $title, $started_by, $started_at)`,
			)
			.run({
				id: call.id,
				conversation_id: call.conversation_id,
				kind: call.kind,
				meeting_id: call.meeting_id,
				title: call.title,
				started_by: call.started_by,
				started_at: call.started_at,
			});
		return call;
	}

	/** Marks the call over, with every seat left and every track ended. False if it had already ended. */
	end(id: string, at: number): boolean {
		return this.db.transaction(() => {
			const { changes } = this.db.query('UPDATE calls SET ended_at = $at WHERE id = $id AND ended_at IS NULL').run({ id, at });
			if (changes === 0) return false;
			this.db.query('UPDATE call_seats SET left_at = $at WHERE call_id = $id AND left_at IS NULL').run({ id, at });
			this.db.query('UPDATE call_tracks SET ended_at = $at WHERE call_id = $id AND ended_at IS NULL').run({ id, at });
			this.db.query('UPDATE call_pulls SET ended_at = $at WHERE call_id = $id AND ended_at IS NULL').run({ id, at });
			return true;
		})();
	}

	/** The calls in rooms `personId` is in now, newest first, ended ones included. One nobody ever got into is not listed. */
	recentFor(personId: string, limit: number): CallRow[] {
		return this.db
			.query<CallRow, { p: string; limit: number }>(
				`SELECT c.* FROM calls c
				JOIN open_conversation_members m ON m.conversation_id = c.conversation_id AND m.person_id = $p
				WHERE EXISTS (SELECT 1 FROM call_seats s WHERE s.call_id = c.id)
				ORDER BY c.started_at DESC, c.id DESC LIMIT $limit`,
			)
			.all({ p: personId, limit });
	}

	seats(callId: string): Seat[] {
		return this.db
			.query<Seat, { id: string }>('SELECT * FROM call_seats WHERE call_id = $id ORDER BY joined_at, device_id')
			.all({ id: callId });
	}

	seat(callId: string, deviceId: string): Seat | null {
		return this.db
			.query<Seat, { c: string; d: string }>('SELECT * FROM call_seats WHERE call_id = $c AND device_id = $d')
			.get({ c: callId, d: deviceId });
	}

	presentCount(callId: string): number {
		return this.db
			.query<{ n: number }, { id: string }>('SELECT COUNT(*) AS n FROM call_seats WHERE call_id = $id AND left_at IS NULL')
			.get({ id: callId })!.n;
	}

	/** Where this device is seated now, in any call. */
	seatsOfDevice(deviceId: string): Seat[] {
		return this.db
			.query<Seat, { d: string }>('SELECT * FROM call_seats WHERE device_id = $d AND left_at IS NULL')
			.all({ d: deviceId });
	}

	presentSeats(): Seat[] {
		return this.db.query<Seat, []>('SELECT * FROM call_seats WHERE left_at IS NULL').all();
	}

	/**
	 * Seats the device: a new row, or the old one again with its generation counted up, its flags cleared and its old
	 * tracks and pulls ended. Returns the seat and what ended, to close at the relay.
	 */
	sit(callId: string, deviceId: string, personId: string, at: number): { seat: Seat; ended: Mid[] } {
		return this.db.transaction(() => {
			const ended = this.release(callId, deviceId, at);
			this.db
				.query(
					`INSERT INTO call_seats (call_id, device_id, person_id, generation, joined_at, last_seen_at)
					VALUES ($c, $d, $p, 1, $at, $at)
					ON CONFLICT (call_id, device_id) DO UPDATE SET generation = generation + 1, session_id = NULL,
						is_muted = 0, is_camera_on = 0, is_screen_sharing = 0, is_hand_raised = 0,
						joined_at = $at, left_at = NULL, last_seen_at = $at`,
				)
				.run({ c: callId, d: deviceId, p: personId, at });
			return { seat: this.seat(callId, deviceId)!, ended };
		})();
	}

	/** Gives the seat its relay session, unless the seat was taken again or left meanwhile. */
	setSession(callId: string, deviceId: string, generation: number, sessionId: string): boolean {
		const { changes } = this.db
			.query(
				`UPDATE call_seats SET session_id = $s
				WHERE call_id = $c AND device_id = $d AND generation = $g AND left_at IS NULL AND session_id IS NULL`,
			)
			.run({ c: callId, d: deviceId, g: generation, s: sessionId });
		return changes > 0;
	}

	/** Takes a seat that never got a session back out: a first seat is removed, a rejoin is marked left. */
	unseat(callId: string, deviceId: string, generation: number, at: number): void {
		const params = { c: callId, d: deviceId, g: generation, at };
		this.db.transaction(() => {
			if (generation === 1) {
				this.db
					.query('DELETE FROM call_seats WHERE call_id = $c AND device_id = $d AND generation = $g AND session_id IS NULL')
					.run({ c: callId, d: deviceId, g: generation });
			}
			this.db
				.query(
					'UPDATE call_seats SET left_at = $at WHERE call_id = $c AND device_id = $d AND generation = $g AND left_at IS NULL',
				)
				.run(params);
		})();
	}

	/** The seat leaves; what it sends and pulls ends. Returns those, to close at the relay, or null if it was not seated. */
	leave(callId: string, deviceId: string, at: number): Mid[] | null {
		return this.db.transaction(() => {
			const { changes } = this.db
				.query('UPDATE call_seats SET left_at = $at WHERE call_id = $c AND device_id = $d AND left_at IS NULL')
				.run({ c: callId, d: deviceId, at });
			return changes === 0 ? null : this.release(callId, deviceId, at);
		})();
	}

	touch(callId: string, deviceId: string, at: number): boolean {
		const { changes } = this.db
			.query('UPDATE call_seats SET last_seen_at = $at WHERE call_id = $c AND device_id = $d AND left_at IS NULL')
			.run({ c: callId, d: deviceId, at });
		return changes > 0;
	}

	setFlags(callId: string, deviceId: string, flags: Flags): void {
		for (const column of FLAGS) {
			const value = flags[column];
			if (value === undefined) continue;
			this.db
				.query(`UPDATE call_seats SET ${column} = $v WHERE call_id = $c AND device_id = $d AND left_at IS NULL`)
				.run({ v: value ? 1 : 0, c: callId, d: deviceId });
		}
	}

	liveTracks(callId: string): Track[] {
		return this.db
			.query<Track, { id: string }>('SELECT * FROM call_tracks WHERE call_id = $id AND ended_at IS NULL ORDER BY id')
			.all({ id: callId });
	}

	/** Records published tracks; a source sent again replaces the device's earlier track of that source. */
	addTracks(seat: Seat, sessionId: string, tracks: { source: Source; mid: string; trackName: string }[], at: number): void {
		this.db.transaction(() => {
			this.endTracks(
				seat.call_id,
				seat.device_id,
				tracks.map((t) => t.source),
				at,
			);
			const insert = this.db.query(
				`INSERT INTO call_tracks (call_id, device_id, person_id, session_id, track_name, source, mid, created_at)
				VALUES ($c, $d, $p, $s, $name, $source, $mid, $at)`,
			);
			for (const track of tracks) {
				insert.run({
					c: seat.call_id,
					d: seat.device_id,
					p: seat.person_id,
					s: sessionId,
					name: track.trackName,
					source: track.source,
					mid: track.mid,
					at,
				});
			}
		})();
	}

	/** Ends everything the device sends and pulls in this call. */
	private release(callId: string, deviceId: string, at: number): Mid[] {
		const tracks = this.endTracks(callId, deviceId, ['mic', 'cam', 'screen'], at);
		return [...tracks, ...this.endPulls(callId, deviceId, null, at)];
	}

	addPulls(seat: Seat & { session_id: string }, pulls: { mid: string; trackName: string }[], at: number): void {
		const insert = this.db.query(
			`INSERT INTO call_pulls (call_id, device_id, session_id, mid, track_name, created_at) VALUES ($c, $d, $s, $mid, $name, $at)`,
		);
		this.db.transaction(() => {
			for (const pull of pulls) {
				insert.run({ c: seat.call_id, d: seat.device_id, s: seat.session_id, mid: pull.mid, name: pull.trackName, at });
			}
		})();
	}

	/** Ends the device's live pulls (only these mids, when given) and returns them. */
	endPulls(callId: string, deviceId: string, mids: string[] | null, at: number): Mid[] {
		const ended = this.db
			.query<Mid & { id: number }, { c: string; d: string }>(
				'SELECT id, session_id, mid FROM call_pulls WHERE call_id = $c AND device_id = $d AND ended_at IS NULL ORDER BY id',
			)
			.all({ c: callId, d: deviceId })
			.filter((p) => mids === null || mids.includes(p.mid));
		const update = this.db.query('UPDATE call_pulls SET ended_at = $at WHERE id = $id');
		for (const pull of ended) update.run({ at, id: pull.id });
		return ended.map(({ session_id, mid }) => ({ session_id, mid }));
	}

	/** Ends the device's live tracks of these sources and returns them. */
	endTracks(callId: string, deviceId: string, sources: Source[], at: number): Track[] {
		const ended = this.db
			.query<Track, { c: string; d: string }>(
				'SELECT * FROM call_tracks WHERE call_id = $c AND device_id = $d AND ended_at IS NULL ORDER BY id',
			)
			.all({ c: callId, d: deviceId })
			.filter((t) => sources.includes(t.source));
		const update = this.db.query('UPDATE call_tracks SET ended_at = $at WHERE id = $id');
		for (const track of ended) update.run({ at, id: track.id });
		return ended;
	}

	ring(callId: string, personIds: string[], at: number, expiresAt: number): void {
		const insert = this.db.query(
			`INSERT OR IGNORE INTO call_rings (call_id, person_id, state, created_at, expires_at) VALUES ($c, $p, 'ringing', $at, $exp)`,
		);
		this.db.transaction(() => {
			for (const p of personIds) insert.run({ c: callId, p, at, exp: expiresAt });
		})();
	}

	/** Ends a ring that is still ringing. True if it was. */
	resolveRing(callId: string, personId: string, state: Exclude<RingState, 'ringing'>, at: number): boolean {
		const { changes } = this.db
			.query(
				`UPDATE call_rings SET state = $state, resolved_at = $at WHERE call_id = $c AND person_id = $p AND state = 'ringing'`,
			)
			.run({ state, at, c: callId, p: personId });
		return changes > 0;
	}

	/** Rings still ringing: for one call, for one person, or past their time. */
	ringing(filter: { callId?: string; personId?: string; expiredBy?: number }): Ring[] {
		return this.db
			.query<Ring, { c: string | null; p: string | null; at: number | null }>(
				`SELECT * FROM call_rings WHERE state = 'ringing'
				AND ($c IS NULL OR call_id = $c) AND ($p IS NULL OR person_id = $p) AND ($at IS NULL OR expires_at <= $at)
				ORDER BY created_at DESC`,
			)
			.all({ c: filter.callId ?? null, p: filter.personId ?? null, at: filter.expiredBy ?? null });
	}
}
