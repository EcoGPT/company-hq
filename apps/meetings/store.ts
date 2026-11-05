import type { Hub, Migration, Person } from '@hq/sdk';
import { newId, now } from '@hq/sdk';
import { nextStart, type Rule } from './recurrence';

export type MeetingStatus = 'scheduled' | 'cancelled';

export type ActionItem = { title: string; owner: string | null; due: string | null; task_id: string | null };

export type Meeting = {
	id: string;
	title: string;
	agenda: string;
	starts_at: number;
	ends_at: number;
	room_id: string;
	organizer_id: string;
	status: MeetingStatus;
	reminded_at: number | null;
	transcript: string | null;
	summary: string | null;
	action_items: string | null;
	recapped_at: number | null;
	created_at: number;
	series_id: string | null;
	/** 1 when the room was opened for this meeting alone, so inviting and uninviting moves people in and out of it. */
	own_room: number;
};

/** A meeting that repeats. Its occurrences are ordinary meetings that point back here; one is kept ahead at a time. */
export type Series = {
	id: string;
	organizer_id: string;
	title: string;
	freq: Rule['freq'];
	timezone: string;
	weekdays: string;
	anchor_at: number;
	duration_ms: number;
	ended_at: number | null;
	created_at: number;
};

export const ruleOf = (series: Series): Rule => ({
	freq: series.freq,
	timezone: series.timezone,
	weekdays: JSON.parse(series.weekdays) as number[],
});

export const migrations: Migration[] = [
	{
		id: '001_meetings',
		up: `CREATE TABLE meetings (
			id TEXT PRIMARY KEY,
			title TEXT NOT NULL,
			agenda TEXT NOT NULL DEFAULT '',
			starts_at INTEGER NOT NULL,
			ends_at INTEGER NOT NULL,
			room_id TEXT NOT NULL REFERENCES conversations(id),
			organizer_id TEXT NOT NULL REFERENCES people(id),
			status TEXT NOT NULL CHECK (status IN ('scheduled', 'cancelled')),
			reminded_at INTEGER,
			transcript TEXT,
			summary TEXT,
			action_items TEXT,
			recapped_at INTEGER,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX meetings_starts ON meetings(starts_at);
		CREATE TABLE meeting_attendees (
			meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
			person_id TEXT NOT NULL REFERENCES people(id),
			PRIMARY KEY (meeting_id, person_id)
		);
		CREATE INDEX meeting_attendees_person ON meeting_attendees(person_id);`,
	},
	{
		id: '002_feed_tokens',
		up: `CREATE TABLE meeting_feed_tokens (
			person_id TEXT PRIMARY KEY REFERENCES people(id),
			hash TEXT NOT NULL UNIQUE,
			created_at INTEGER NOT NULL
		)`,
	},
	{
		id: '003_series',
		up: `CREATE TABLE meeting_series (
			id TEXT PRIMARY KEY,
			organizer_id TEXT NOT NULL REFERENCES people(id),
			title TEXT NOT NULL,
			freq TEXT NOT NULL CHECK (freq IN ('daily', 'weekdays', 'weekly', 'biweekly', 'monthly')),
			timezone TEXT NOT NULL,
			weekdays TEXT NOT NULL,
			anchor_at INTEGER NOT NULL,
			duration_ms INTEGER NOT NULL,
			ended_at INTEGER,
			created_at INTEGER NOT NULL
		);
		ALTER TABLE meetings ADD COLUMN series_id TEXT REFERENCES meeting_series(id);
		ALTER TABLE meetings ADD COLUMN own_room INTEGER NOT NULL DEFAULT 0;
		CREATE INDEX meetings_series ON meetings(series_id, starts_at);`,
	},
];

/** No meeting is longer than a day (the assistant's tool caps it), so one that has not ended started within this long. */
const LONGEST_MS = 24 * 3_600_000;

/**
 * Whom a meeting is for, as `$p`: the one who runs it, someone invited, or anyone who can open its room now. A meeting
 * whose room is archived is closed to everyone, as the room is.
 */
const VISIBLE = `NOT EXISTS (SELECT 1 FROM conversations r WHERE r.id = m.room_id AND r.archived_at IS NOT NULL)
	AND (m.organizer_id = $p
		OR EXISTS (SELECT 1 FROM meeting_attendees a WHERE a.meeting_id = m.id AND a.person_id = $p)
		OR EXISTS (SELECT 1 FROM open_conversation_members c WHERE c.conversation_id = m.room_id AND c.person_id = $p))`;

/** The list the app polls. The lower bound on the start lets it read the start index instead of every meeting ever made. */
export const VISIBLE_NOW = `SELECT * FROM meetings m WHERE m.starts_at >= $earliest AND m.status = 'scheduled' AND m.ends_at >= $at AND ${VISIBLE}
	ORDER BY m.starts_at, m.id LIMIT $limit`;

const feedHash = (token: string) => new Bun.CryptoHasher('sha256').update(token).digest('hex');

export type When = 'upcoming' | 'past' | 'all';

export class Meetings {
	constructor(private readonly hub: Hub) {}

	rotateFeed(personId: string): string {
		const token = `cal_${Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString('base64url')}`;
		this.hub.db
			.query(
				`INSERT INTO meeting_feed_tokens (person_id, hash, created_at) VALUES ($person, $hash, $at)
				ON CONFLICT(person_id) DO UPDATE SET hash = $hash, created_at = $at`,
			)
			.run({ person: personId, hash: feedHash(token), at: Date.now() });
		return token;
	}

	feed(token: string): { person_id: string; created_at: number } | null {
		return this.hub.db
			.query<{ person_id: string; created_at: number }, { hash: string }>(
				'SELECT person_id, created_at FROM meeting_feed_tokens WHERE hash = $hash',
			)
			.get({ hash: feedHash(token) });
	}

	schedule(input: {
		title: string;
		agenda?: string;
		startsAt: number;
		endsAt: number;
		roomId: string;
		organizerId: string;
		attendeeIds: string[];
		seriesId?: string;
		ownRoom?: boolean;
	}): Meeting {
		const meeting: Meeting = {
			id: newId(),
			title: input.title.trim(),
			agenda: input.agenda?.trim() ?? '',
			starts_at: input.startsAt,
			ends_at: input.endsAt,
			room_id: input.roomId,
			organizer_id: input.organizerId,
			status: 'scheduled',
			reminded_at: null,
			transcript: null,
			summary: null,
			action_items: null,
			recapped_at: null,
			created_at: now(),
			series_id: input.seriesId ?? null,
			own_room: input.ownRoom ? 1 : 0,
		};
		this.hub.db.transaction(() => {
			this.hub.db
				.query(
					`INSERT INTO meetings (id, title, agenda, starts_at, ends_at, room_id, organizer_id, status, created_at, series_id, own_room)
					VALUES ($id, $title, $agenda, $starts_at, $ends_at, $room_id, $organizer_id, $status, $created_at, $series_id, $own_room)`,
				)
				.run({
					id: meeting.id,
					title: meeting.title,
					agenda: meeting.agenda,
					starts_at: meeting.starts_at,
					ends_at: meeting.ends_at,
					room_id: meeting.room_id,
					organizer_id: meeting.organizer_id,
					status: meeting.status,
					created_at: meeting.created_at,
					series_id: meeting.series_id,
					own_room: meeting.own_room,
				});
			this.addAttendees(meeting.id, input.attendeeIds);
		})();
		return meeting;
	}

	get(id: string): Meeting | null {
		return this.hub.db.query<Meeting, { id: string }>('SELECT * FROM meetings WHERE id = $id').get({ id });
	}

	attendeeIds(id: string): string[] {
		return this.attendeesOf([id]).get(id) ?? [];
	}

	attendeesOf(meetingIds: string[]): Map<string, string[]> {
		const byMeeting = new Map<string, string[]>(meetingIds.map((id) => [id, []]));
		const rows = this.hub.db
			.query<{ meeting_id: string; person_id: string }, { ids: string }>(
				'SELECT meeting_id, person_id FROM meeting_attendees WHERE meeting_id IN (SELECT value FROM json_each($ids)) ORDER BY person_id',
			)
			.all({ ids: JSON.stringify(meetingIds) });
		for (const row of rows) byMeeting.get(row.meeting_id)?.push(row.person_id);
		return byMeeting;
	}

	participants(meeting: Meeting): Person[] {
		const ids = [...new Set([meeting.organizer_id, ...this.attendeeIds(meeting.id)])];
		const people = this.hub.people.byIds(ids);
		return ids.flatMap((id) => people.get(id) ?? []);
	}

	addAttendees(id: string, personIds: string[]): void {
		const insert = this.hub.db.query('INSERT OR IGNORE INTO meeting_attendees (meeting_id, person_id) VALUES ($id, $person)');
		for (const person of personIds) insert.run({ id, person });
	}

	list(filter: { when?: When; personId?: string; seenBy?: string[]; at?: number; limit?: number } = {}): Meeting[] {
		const when = filter.when ?? 'upcoming';
		return this.hub.db
			.query<Meeting, { when: string; at: number; person: string | null; seen: string | null; limit: number }>(
				`SELECT * FROM meetings m
				WHERE ($when = 'all'
					OR ($when = 'upcoming' AND m.status = 'scheduled' AND m.ends_at >= $at)
					OR ($when = 'past' AND m.ends_at < $at))
				AND ($person IS NULL OR m.organizer_id = $person
					OR EXISTS (SELECT 1 FROM meeting_attendees a WHERE a.meeting_id = m.id AND a.person_id = $person))
				AND ($seen IS NULL OR NOT EXISTS (SELECT 1 FROM json_each($seen) v WHERE NOT EXISTS
					(SELECT 1 FROM open_conversation_members c WHERE c.conversation_id = m.room_id AND c.person_id = v.value)))
				ORDER BY CASE WHEN $when = 'upcoming' THEN m.starts_at ELSE -m.starts_at END
				LIMIT $limit`,
			)
			.all({
				when,
				at: filter.at ?? Date.now(),
				person: filter.personId ?? null,
				seen: filter.seenBy === undefined ? null : JSON.stringify(filter.seenBy),
				limit: filter.limit ?? 50,
			});
	}

	/** Makes the invite list exactly these people. The organizer is never listed: they are always in. */
	setAttendees(id: string, personIds: string[]): void {
		this.hub.db.transaction(() => {
			this.hub.db
				.query('DELETE FROM meeting_attendees WHERE meeting_id = $id AND person_id NOT IN (SELECT value FROM json_each($keep))')
				.run({ id, keep: JSON.stringify(personIds) });
			this.addAttendees(id, personIds);
		})();
	}

	/** Meetings `personId` may see that have not ended and are not cancelled, soonest first. */
	visibleTo(personId: string, filter: { at?: number; limit?: number } = {}): Meeting[] {
		const at = filter.at ?? Date.now();
		return this.hub.db
			.query<Meeting, { p: string; at: number; earliest: number; limit: number }>(VISIBLE_NOW)
			.all({ p: personId, at, earliest: at - LONGEST_MS, limit: filter.limit ?? 200 });
	}

	/** Whether this room was opened for a meeting of its own (a Quick Call's room is one). */
	ownsRoom(roomId: string): boolean {
		return this.hub.db.query('SELECT 1 FROM meetings WHERE room_id = $r AND own_room = 1 LIMIT 1').get({ r: roomId }) !== null;
	}

	canSee(id: string, personId: string): boolean {
		return this.hub.db.query(`SELECT 1 FROM meetings m WHERE m.id = $id AND ${VISIBLE}`).get({ id, p: personId }) !== null;
	}

	canSeeSeries(seriesId: string, personId: string): boolean {
		return (
			this.hub.db
				.query(`SELECT 1 FROM meetings m WHERE m.series_id = $series AND ${VISIBLE} LIMIT 1`)
				.get({ series: seriesId, p: personId }) !== null
		);
	}

	/** Meetings someone runs that have not ended or been cancelled, for the cap on how many a person may have. */
	countAhead(organizerId: string, at: number): number {
		return this.hub.db
			.query<{ n: number }, { p: string; at: number }>(
				"SELECT COUNT(*) AS n FROM meetings WHERE organizer_id = $p AND status = 'scheduled' AND ends_at >= $at",
			)
			.get({ p: organizerId, at })!.n;
	}

	countOpenSeries(organizerId: string): number {
		return this.hub.db
			.query<{ n: number }, { p: string }>(
				'SELECT COUNT(*) AS n FROM meeting_series WHERE organizer_id = $p AND ended_at IS NULL',
			)
			.get({ p: organizerId })!.n;
	}

	series(id: string): Series | null {
		return this.hub.db.query<Series, { id: string }>('SELECT * FROM meeting_series WHERE id = $id').get({ id });
	}

	createSeries(input: { organizerId: string; title: string; rule: Rule; anchor: number; durationMs: number }): Series {
		const series: Series = {
			id: newId(),
			organizer_id: input.organizerId,
			title: input.title.trim(),
			freq: input.rule.freq,
			timezone: input.rule.timezone,
			weekdays: JSON.stringify(input.rule.weekdays),
			anchor_at: input.anchor,
			duration_ms: input.durationMs,
			ended_at: null,
			created_at: now(),
		};
		this.hub.db
			.query(
				`INSERT INTO meeting_series (id, organizer_id, title, freq, timezone, weekdays, anchor_at, duration_ms, ended_at, created_at)
				VALUES ($id, $organizer_id, $title, $freq, $timezone, $weekdays, $anchor_at, $duration_ms, $ended_at, $created_at)`,
			)
			.run({ ...series });
		return series;
	}

	/** Stops the series for good and cancels what is still ahead or under way. What already happened stays. */
	endSeries(id: string, at: number): Meeting[] {
		return this.hub.db.transaction(() => {
			this.hub.db.query('UPDATE meeting_series SET ended_at = $at WHERE id = $id AND ended_at IS NULL').run({ id, at });
			const ahead = this.aheadInSeries(id, at);
			for (const meeting of ahead) this.update(meeting, { status: 'cancelled' });
			return ahead;
		})();
	}

	/** The occurrences of a series that have not ended and are not cancelled. */
	aheadInSeries(seriesId: string, at: number): Meeting[] {
		return this.hub.db
			.query<Meeting, { id: string; at: number }>(
				"SELECT * FROM meetings WHERE series_id = $id AND status = 'scheduled' AND ends_at >= $at ORDER BY starts_at",
			)
			.all({ id: seriesId, at });
	}

	/**
	 * Keeps one occurrence ahead of a live series, whatever happened to the last: it was cancelled, it ended, or nobody
	 * looked for a while. The new one has the last one's room and invite list. A series that is closed (its room archived or
	 * its organizer removed) is ended instead, with what was ahead cancelled. Returns the meetings added or cancelled.
	 */
	advance(series: Series, at: number): Meeting[] {
		if (series.ended_at !== null) return [];
		if (this.closed(series)) return this.endSeries(series.id, at);
		if (this.aheadInSeries(series.id, at).length > 0) return [];
		const last = this.lastOf(series.id);
		if (last === null) return [];
		const start = nextStart(ruleOf(series), series.anchor_at, Math.max(last.starts_at, at - series.duration_ms));
		if (start === null) return [];
		const added = this.schedule({
			title: series.title,
			startsAt: start,
			endsAt: start + series.duration_ms,
			roomId: last.room_id,
			organizerId: series.organizer_id,
			attendeeIds: this.attendeeIds(last.id),
			seriesId: series.id,
			ownRoom: last.own_room === 1,
		});
		return [added];
	}

	private lastOf(seriesId: string): Meeting | null {
		return this.hub.db
			.query<Meeting, { id: string }>('SELECT * FROM meetings WHERE series_id = $id ORDER BY starts_at DESC LIMIT 1')
			.get({ id: seriesId });
	}

	/** A series whose room was archived or whose organizer was removed: nobody is left to run it or to read its reminders. */
	private closed(series: Series): boolean {
		const room = this.lastOf(series.id)?.room_id;
		return (
			(room !== undefined && this.hub.conversations.get(room)?.archived_at != null) ||
			this.hub.people.get(series.organizer_id)?.removed_at != null
		);
	}

	/**
	 * `advance` for every live series, for when the occurrence ahead has passed. Returns the meetings added or cancelled, whose
	 * people need their list again.
	 */
	advanceAll(at: number): Meeting[] {
		const live = this.hub.db.query<Series, []>('SELECT * FROM meeting_series WHERE ended_at IS NULL').all();
		return live.flatMap((series) => this.advance(series, at));
	}

	dueForReminder(at: number, leadMs: number): Meeting[] {
		return this.hub.db
			.query<Meeting, { at: number; until: number }>(
				`SELECT * FROM meetings m WHERE m.status = 'scheduled' AND m.reminded_at IS NULL
				AND m.starts_at > $at AND m.starts_at <= $until
				AND NOT EXISTS (SELECT 1 FROM conversations r WHERE r.id = m.room_id AND r.archived_at IS NOT NULL)
				ORDER BY m.starts_at`,
			)
			.all({ at, until: at + leadMs });
	}

	saveRecap(meeting: Meeting, recap: { transcript: string; summary: string; actionItems: ActionItem[] }): Meeting {
		const next: Meeting = {
			...meeting,
			transcript: recap.transcript,
			summary: recap.summary,
			action_items: JSON.stringify(recap.actionItems),
			recapped_at: now(),
		};
		this.hub.db
			.query(
				'UPDATE meetings SET transcript = $transcript, summary = $summary, action_items = $items, recapped_at = $at WHERE id = $id',
			)
			.run({ id: next.id, transcript: next.transcript, summary: next.summary, items: next.action_items, at: next.recapped_at });
		return next;
	}

	update(
		meeting: Meeting,
		patch: Partial<Pick<Meeting, 'title' | 'agenda' | 'starts_at' | 'ends_at' | 'status' | 'reminded_at'>>,
	): Meeting {
		const next = { ...meeting, ...patch };
		if (patch.starts_at !== undefined && patch.starts_at !== meeting.starts_at && patch.reminded_at === undefined)
			next.reminded_at = null;
		this.hub.db
			.query(
				`UPDATE meetings SET title = $title, agenda = $agenda, starts_at = $starts_at, ends_at = $ends_at,
				status = $status, reminded_at = $reminded_at WHERE id = $id`,
			)
			.run({
				id: next.id,
				title: next.title,
				agenda: next.agenda,
				starts_at: next.starts_at,
				ends_at: next.ends_at,
				status: next.status,
				reminded_at: next.reminded_at,
			});
		return next;
	}
}
