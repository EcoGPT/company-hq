import { afterEach, describe, expect, test } from 'bun:test';
import type { Server } from 'bun';
import { CORE_MIGRATIONS, Hub } from '../../src/core/hub';
import { appMigrations } from '../../src/apps/mount';
import { migrate } from '../../src/db/database';
import type { SocketData } from '../../src/realtime/socket';
import { client, connect, enrolled, pair, serve, type Connection } from '../../test/helpers';
import { decodeProblems } from '../library/decode';
import meetings from './app';
import { migrations, VISIBLE_NOW } from './store';
import { MAX_INVITEES, MAX_MEETINGS_AHEAD, MAX_OPEN_SERIES } from './v1';

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const inHours = (n: number) => new Date(Date.now() + n * HOUR).toISOString();

type Wire = {
	id: string;
	title: string;
	scheduled_at: string;
	created_by_person_id: string;
	conversation_id: string;
	invitee_person_ids: string[];
	recurrence: string | null;
	series_id: string | null;
};

async function setup() {
	const base = await pair({ apps: [meetings] });
	const { hq } = base;
	const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
	hq.hub.conversations.addMember(hq.hub.general().id, cy.id);
	const c = await enrolled(hq, hq.hub.keys.mint(cy.id, 'setup').secret, 'Cy Mac');
	const calls = async (who: { as: ReturnType<typeof client> }) => {
		const body = (await who.as('GET', '/v1/calls')).body;
		expect(decodeProblems('CallsSnapshot', body)).toEqual([]);
		for (const meeting of body.meetings) expect(decodeProblems('Meeting', meeting)).toEqual([]);
		return body.meetings as Wire[];
	};
	const create = async (who: { as: ReturnType<typeof client> }, body: Record<string, unknown>) => {
		const made = await who.as('POST', '/v1/meetings', body);
		if (made.status === 201) expect(decodeProblems('MeetingEnvelope', made.body)).toEqual([]);
		return made;
	};
	return { ...base, cy, c, calls, create };
}

let server: Server<SocketData> | undefined;
let open: Connection[] = [];
afterEach(() => {
	for (const connection of open) connection.ws.close();
	open = [];
	void server?.stop(true);
	server = undefined;
});

describe('creating a meeting', () => {
	test('lists it for the organizer and the people invited, not for anyone else', async () => {
		const { a, b, c, hq, create, calls } = await setup();
		const made = await create(a, { title: 'Launch sync', scheduled_at: inHours(2), invitee_person_ids: [b.person.id] });
		expect(made.status).toBe(201);
		const meeting = made.body.meeting as Wire;
		expect(meeting).toMatchObject({
			title: 'Launch sync',
			created_by_person_id: a.person.id,
			recurrence: null,
			series_id: null,
		});
		expect(meeting.invitee_person_ids.sort()).toEqual([a.person.id, b.person.id].sort());
		// It has a thread of its own, with just the two of them (and the assistant) in it.
		expect(hq.hub.conversations.memberIds(meeting.conversation_id)).toEqual(expect.arrayContaining([a.person.id, b.person.id]));
		expect(hq.hub.conversations.isMember(meeting.conversation_id, c.person.id)).toBe(false);

		expect((await calls(a)).map((m) => m.id)).toEqual([meeting.id]);
		expect((await calls(b)).map((m) => m.id)).toEqual([meeting.id]);
		expect(await calls(c)).toEqual([]);
	});

	test('a meeting with no time starts now, and the organizer is the only one invited if no one is named', async () => {
		const { a, create, calls } = await setup();
		const before = Date.now();
		const made = await create(a, { title: 'Quick call' });
		expect(made.status).toBe(201);
		expect(Date.parse(made.body.meeting.scheduled_at)).toBeGreaterThanOrEqual(before - 1000);
		expect(made.body.meeting.invitee_person_ids).toEqual([a.person.id]);
		expect(await calls(a)).toHaveLength(1);
	});

	test('lists soonest first, and drops one once it has ended', async () => {
		const { a, hq, create, calls } = await setup();
		const later = (await create(a, { title: 'Later', scheduled_at: inHours(5) })).body.meeting as Wire;
		const sooner = (await create(a, { title: 'Sooner', scheduled_at: inHours(1) })).body.meeting as Wire;
		expect((await calls(a)).map((m) => m.title)).toEqual(['Sooner', 'Later']);
		hq.hub.db
			.query('UPDATE meetings SET starts_at = starts_at - $d, ends_at = ends_at - $d WHERE id = $id')
			.run({ id: sooner.id, d: 3 * HOUR });
		expect((await calls(a)).map((m) => m.id)).toEqual([later.id]);
	});

	test('refuses what it cannot make sense of', async () => {
		const { a, hq, create } = await setup();
		const refused = async (body: Record<string, unknown>) => (await create(a, body)).body.error;
		const malformed = async (body: Record<string, unknown>) => (await create(a, body)).status;
		expect(await malformed({ title: '  ' })).toBe(400);
		expect(await refused({ title: 'x', scheduled_at: 'tomorrow' })).toBe('invalid_time');
		expect(await refused({ title: 'x', scheduled_at: inHours(-2) })).toBe('in_the_past');
		expect(await refused({ title: 'x', scheduled_at: new Date(Date.now() + 11 * 365 * DAY).toISOString() })).toBe(
			'too_far_ahead',
		);
		expect(await refused({ title: 'x', recurrence: { freq: 'weekly', timezone: 'Mars/Olympus', weekdays: [] } })).toBe(
			'invalid_timezone',
		);
		expect(await malformed({ title: 'x', recurrence: { freq: 'hourly', timezone: 'UTC', weekdays: [] } })).toBe(400);
		expect(await malformed({ title: 'x', recurrence: { freq: 'weekly', timezone: 'UTC', weekdays: [7] } })).toBe(400);
		// Invitees must be people on this server who sign in: not a made-up id, the assistant, or someone removed.
		expect(await refused({ title: 'x', invitee_person_ids: ['nobody'] })).toBe('person_not_found');
		expect(await refused({ title: 'x', invitee_person_ids: [hq.assistant.self.id] })).toBe('person_not_found');
		const gone = hq.hub.people.create({ name: 'Gus', handle: 'gus' });
		hq.hub.people.setRemoved(gone.id, Date.now());
		expect(await refused({ title: 'x', invitee_person_ids: [gone.id] })).toBe('person_not_found');
		expect((await a.as('GET', '/v1/calls')).body.meetings).toEqual([]);
	});

	test('takes a bounded list of invitees and a small body', async () => {
		const { a, b, create } = await setup();
		const many = Array.from({ length: MAX_INVITEES + 1 }, () => b.person.id);
		expect((await create(a, { title: 'x', invitee_person_ids: many })).status).toBe(400);
		expect((await create(a, { title: 'x'.repeat(70_000) })).status).toBe(413);
		const same = Array.from({ length: MAX_INVITEES }, () => b.person.id);
		expect((await create(a, { title: 'x', invitee_person_ids: same })).status).toBe(201);
	});

	test('caps how many meetings and repeating meetings one person keeps ahead', async () => {
		const { a, b, hq, create } = await setup();
		const insert = hq.hub.db.query(
			`INSERT INTO meetings (id, title, starts_at, ends_at, room_id, organizer_id, status, created_at)
			VALUES ($id, 'x', $at, $at, $room, $organizer, 'scheduled', 0)`,
		);
		const room = hq.hub.general().id;
		for (let i = 0; i < MAX_MEETINGS_AHEAD; i += 1) {
			insert.run({ id: `m${i}`, at: Date.now() + DAY, room, organizer: a.person.id });
		}
		expect((await create(a, { title: 'one more' })).body.error).toBe('too_many_meetings');
		expect((await create(b, { title: 'someone else is fine' })).status).toBe(201);

		const other = await setup();
		const series = other.hq.hub.db.query(
			`INSERT INTO meeting_series (id, organizer_id, title, freq, timezone, weekdays, anchor_at, duration_ms, created_at)
			VALUES ($id, $organizer, 'x', 'daily', 'UTC', '[]', 0, 0, 0)`,
		);
		for (let i = 0; i < MAX_OPEN_SERIES; i += 1) series.run({ id: `s${i}`, organizer: other.a.person.id });
		const body = { title: 'again', recurrence: { freq: 'daily', timezone: 'UTC', weekdays: [] } };
		expect((await other.create(other.a, body)).body.error).toBe('too_many_series');
		expect((await other.create(other.a, { title: 'once' })).status).toBe(201);
	});

	test('needs a sign-in', async () => {
		const { hq } = await setup();
		expect((await client(hq)('POST', '/v1/meetings', { title: 'x' })).status).toBe(401);
		expect((await client(hq)('PUT', '/v1/meetings/x/invitees', { person_ids: [] })).status).toBe(401);
		expect((await client(hq)('DELETE', '/v1/meetings/x')).status).toBe(401);
		expect((await client(hq)('DELETE', '/v1/meeting-series/x')).status).toBe(401);
	});
});

describe('who sees a meeting', () => {
	test('those who run it, are invited, or can open its room, and no one when the room is closed', async () => {
		const { a, b, c, hq, create, calls } = await setup();
		const meeting = (await create(a, { title: 'Sync', scheduled_at: inHours(1), invitee_person_ids: [b.person.id] })).body
			.meeting as Wire;
		const store = hq.hub.db;
		// Invited but no longer in the room: still sees it, because they are invited.
		hq.hub.conversations.removeMember(meeting.conversation_id, b.person.id);
		expect((await calls(b)).map((m) => m.id)).toEqual([meeting.id]);
		// In the room but not invited and not the organizer: sees it, because they can see the room.
		store.query('DELETE FROM meeting_attendees WHERE meeting_id = $id').run({ id: meeting.id });
		hq.hub.conversations.addMember(meeting.conversation_id, c.person.id);
		expect((await calls(c)).map((m) => m.id)).toEqual([meeting.id]);
		expect(await calls(b)).toEqual([]);
		// The organizer sees it after leaving the room.
		hq.hub.conversations.removeMember(meeting.conversation_id, a.person.id);
		expect((await calls(a)).map((m) => m.id)).toEqual([meeting.id]);
		// Close the room and it is closed to all three.
		hq.hub.conversations.archive(meeting.conversation_id);
		expect(await calls(a)).toEqual([]);
		expect(await calls(c)).toEqual([]);
		expect((await a.as('DELETE', `/v1/meetings/${meeting.id}`)).status).toBe(404);
	});

	test('a meeting the assistant scheduled shows up too, for those it is for', async () => {
		const { a, b, hq, calls } = await setup();
		const result = await hq.registry.call(
			'schedule_meeting',
			{ title: 'From chat', starts_at: inHours(3), attendee_handles: ['bo'], organizer_handle: 'ada' },
			{ hub: hq.hub, caller: hq.assistant.self, conversationId: hq.hub.general().id },
		);
		expect(result.ok).toBe(true);
		expect((await calls(a)).map((m) => m.title)).toEqual(['From chat']);
		expect((await calls(b)).map((m) => m.title)).toEqual(['From chat']);
	});

	test('the list is bounded', async () => {
		const { a, hq, calls } = await setup();
		const insert = hq.hub.db.query(
			`INSERT INTO meetings (id, title, starts_at, ends_at, room_id, organizer_id, status, created_at)
			VALUES ($id, 'x', $at, $at, $room, $organizer, 'scheduled', 0)`,
		);
		for (let i = 0; i < 201; i += 1) {
			insert.run({ id: `m${i}`, at: Date.now() + DAY, room: hq.hub.general().id, organizer: a.person.id });
		}
		expect(await calls(a)).toHaveLength(200);
	});
});

describe('changing who is invited', () => {
	test('replaces the list; the organizer stays; a new person joins the thread and a left-out one leaves it', async () => {
		const { a, b, c, hq, create, calls } = await setup();
		const meeting = (await create(a, { title: 'Sync', scheduled_at: inHours(1), invitee_person_ids: [b.person.id] })).body
			.meeting as Wire;
		const put = await a.as('PUT', `/v1/meetings/${meeting.id}/invitees`, { person_ids: [c.person.id] });
		expect(put.status).toBe(200);
		expect(decodeProblems('MeetingEnvelope', put.body)).toEqual([]);
		expect(put.body.meeting.invitee_person_ids.sort()).toEqual([a.person.id, c.person.id].sort());
		expect(hq.hub.conversations.isMember(meeting.conversation_id, c.person.id)).toBe(true);
		expect(hq.hub.conversations.isMember(meeting.conversation_id, b.person.id)).toBe(false);
		expect(hq.hub.conversations.isMember(meeting.conversation_id, a.person.id)).toBe(true);
		expect(await calls(b)).toEqual([]);
		expect((await calls(c)).map((m) => m.id)).toEqual([meeting.id]);
		// An empty list leaves the organizer alone with it.
		const alone = await a.as('PUT', `/v1/meetings/${meeting.id}/invitees`, { person_ids: [] });
		expect(alone.body.meeting.invitee_person_ids).toEqual([a.person.id]);
		expect(await calls(c)).toEqual([]);
	});

	test('a room the meeting shares with others is left as it is', async () => {
		const { a, b, c, hq, create } = await setup();
		const meeting = (await create(a, { title: 'Sync', scheduled_at: inHours(1), invitee_person_ids: [b.person.id] })).body
			.meeting as Wire;
		hq.hub.db.query('UPDATE meetings SET own_room = 0 WHERE id = $id').run({ id: meeting.id });
		await a.as('PUT', `/v1/meetings/${meeting.id}/invitees`, { person_ids: [c.person.id] });
		expect(hq.hub.conversations.isMember(meeting.conversation_id, b.person.id)).toBe(true);
		expect(hq.hub.conversations.isMember(meeting.conversation_id, c.person.id)).toBe(true);
	});

	test('a shared room is not opened to new people by someone who has left it', async () => {
		const { a, b, c, hq, create, calls } = await setup();
		const meeting = (await create(a, { title: 'Sync', scheduled_at: inHours(1), invitee_person_ids: [b.person.id] })).body
			.meeting as Wire;
		hq.hub.db.query('UPDATE meetings SET own_room = 0 WHERE id = $id').run({ id: meeting.id });
		hq.hub.conversations.removeMember(meeting.conversation_id, a.person.id);
		const put = await a.as('PUT', `/v1/meetings/${meeting.id}/invitees`, { person_ids: [c.person.id] });
		expect(put.status).toBe(200);
		// Cy is on the meeting's list, but did not get into the room and its history.
		expect(put.body.meeting.invitee_person_ids.sort()).toEqual([a.person.id, c.person.id].sort());
		expect(hq.hub.conversations.isMember(meeting.conversation_id, c.person.id)).toBe(false);
		expect(hq.hub.conversations.isMember(meeting.conversation_id, b.person.id)).toBe(true);
		expect((await calls(c)).map((m) => m.id)).toEqual([meeting.id]);
	});

	test('names only people on this server', async () => {
		const { a, hq, create } = await setup();
		const meeting = (await create(a, { title: 'Sync', scheduled_at: inHours(1) })).body.meeting as Wire;
		const put = (ids: string[]) => a.as('PUT', `/v1/meetings/${meeting.id}/invitees`, { person_ids: ids });
		expect((await put(['nobody'])).body.error).toBe('person_not_found');
		expect((await put([hq.assistant.self.id])).body.error).toBe('person_not_found');
		expect((await put(Array.from({ length: MAX_INVITEES + 1 }, () => a.person.id))).status).toBe(400);
		expect((await a.as('PUT', `/v1/meetings/${meeting.id}/invitees`, { people: [] })).status).toBe(400);
	});

	test('is for the organizer or an admin on a signed-in device', async () => {
		const { a, b, c, hq, ada, create } = await setup();
		const meeting = (await create(b, { title: 'Bo’s', scheduled_at: inHours(1), invitee_person_ids: [c.person.id] })).body
			.meeting as Wire;
		const path = `/v1/meetings/${meeting.id}/invitees`;
		// Invited, but not the organizer.
		expect((await c.as('PUT', path, { person_ids: [] })).status).toBe(403);
		// Not seen at all: as good as missing.
		const dee = hq.hub.people.create({ name: 'Dee', handle: 'dee' });
		const d = await enrolled(hq, hq.hub.keys.mint(dee.id, 'setup').secret, 'Dee Mac');
		expect((await d.as('PUT', path, { person_ids: [] })).status).toBe(404);
		expect((await a.as('PUT', '/v1/meetings/nope/invitees', { person_ids: [] })).status).toBe(404);
		// An admin who is not in the room or the list does not see it, so it is as good as missing to them too.
		expect((await a.as('PUT', path, { person_ids: [] })).status).toBe(404);
		hq.hub.conversations.addMember(meeting.conversation_id, a.person.id);
		// Seen, the admin's script key is still not a device; the admin's device is.
		expect((await client(hq, ada.key)('PUT', path, { person_ids: [] })).status).toBe(403);
		expect((await a.as('PUT', path, { person_ids: [b.person.id] })).status).toBe(200);
		expect((await b.as('PUT', path, { person_ids: [c.person.id] })).status).toBe(200);
	});
});

describe('cancelling', () => {
	test('the organizer or an admin device cancels; an invited member cannot', async () => {
		const { a, b, c, hq, ada, create, calls } = await setup();
		const make = async () =>
			(await create(b, { title: 'Bo’s', scheduled_at: inHours(1), invitee_person_ids: [a.person.id, c.person.id] })).body
				.meeting as Wire;
		const first = await make();
		expect((await c.as('DELETE', `/v1/meetings/${first.id}`)).status).toBe(403);
		expect(await calls(c)).toHaveLength(1);
		expect((await client(hq, ada.key)('DELETE', `/v1/meetings/${first.id}`)).status).toBe(403);
		expect(await a.as('DELETE', `/v1/meetings/${first.id}`)).toEqual({ status: 200, body: { ok: true } });
		expect(await calls(c)).toEqual([]);
		expect(await calls(b)).toEqual([]);
		// The organizer can too, and asking twice is fine.
		const second = await make();
		expect((await b.as('DELETE', `/v1/meetings/${second.id}`)).status).toBe(200);
		expect((await b.as('DELETE', `/v1/meetings/${second.id}`)).status).toBe(200);
		expect((await b.as('DELETE', '/v1/meetings/nope')).status).toBe(404);
	});

	test('does not reveal a meeting to someone who cannot see it', async () => {
		const { a, b, create, hq } = await setup();
		const meeting = (await create(b, { title: 'Private', scheduled_at: inHours(1) })).body.meeting as Wire;
		const outsider = hq.hub.people.create({ name: 'Dee', handle: 'dee' });
		const d = await enrolled(hq, hq.hub.keys.mint(outsider.id, 'setup').secret, 'Dee Mac');
		expect((await d.as('DELETE', `/v1/meetings/${meeting.id}`)).body).toEqual({ error: 'meeting_not_found' });
		// Even an admin device cannot cancel what is not in front of it.
		expect((await a.as('DELETE', `/v1/meetings/${meeting.id}`)).body).toEqual({ error: 'meeting_not_found' });
		expect(hq.hub.db.query('SELECT status FROM meetings WHERE id = $id').get({ id: meeting.id })).toEqual({
			status: 'scheduled',
		});
	});
});

describe('a repeating meeting', () => {
	const weekly = { freq: 'weekly', timezone: 'UTC', weekdays: [] };

	test('is made once, shows how it repeats, and puts the next one up when this one is cancelled', async () => {
		const { a, b, create, calls, hq } = await setup();
		const first = (
			await create(a, { title: 'Standup', scheduled_at: inHours(1), invitee_person_ids: [b.person.id], recurrence: weekly })
		).body.meeting as Wire;
		expect(first.series_id).not.toBeNull();
		expect(first.recurrence).toMatch(/^Weekly on (Sun|Mon|Tue|Wed|Thu|Fri|Sat) at \d\d:\d\d$/);
		expect(await calls(b)).toHaveLength(1);

		expect((await a.as('DELETE', `/v1/meetings/${first.id}`)).status).toBe(200);
		const next = (await calls(b)).at(0)!;
		expect(next.id).not.toBe(first.id);
		expect(next.series_id).toBe(first.series_id);
		expect(next.conversation_id).toBe(first.conversation_id);
		expect(next.recurrence).toBe(first.recurrence);
		expect(next.invitee_person_ids.sort()).toEqual(first.invitee_person_ids.sort());
		expect(Date.parse(next.scheduled_at) - Date.parse(first.scheduled_at)).toBe(7 * DAY);
		// Skipping again moves on again, and still only one is ahead.
		await a.as('DELETE', `/v1/meetings/${next.id}`);
		const third = await calls(a);
		expect(third).toHaveLength(1);
		expect(Date.parse(third[0]!.scheduled_at) - Date.parse(first.scheduled_at)).toBe(14 * DAY);
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM meetings').get()).toEqual({ n: 3 });
	});

	test('ending it cancels what is ahead for good, and keeps what happened', async () => {
		const { a, b, c, create, calls, hq } = await setup();
		const first = (
			await create(a, { title: 'Standup', scheduled_at: inHours(1), invitee_person_ids: [b.person.id], recurrence: weekly })
		).body.meeting as Wire;
		const seriesId = first.series_id!;
		expect((await c.as('DELETE', `/v1/meeting-series/${seriesId}`)).status).toBe(404);
		expect((await b.as('DELETE', `/v1/meeting-series/${seriesId}`)).status).toBe(403);
		expect(await calls(b)).toHaveLength(1);
		expect(await a.as('DELETE', `/v1/meeting-series/${seriesId}`)).toEqual({ status: 200, body: { ok: true } });
		expect(await calls(a)).toEqual([]);
		expect(await calls(b)).toEqual([]);
		// Skipping an occurrence of an ended series does not bring it back, and neither does the tick.
		await a.as('DELETE', `/v1/meetings/${first.id}`);
		await hq.scheduler.run('meetings', 'reminders');
		expect(await calls(a)).toEqual([]);
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM meetings').get()).toEqual({ n: 1 });
		expect((await a.as('DELETE', `/v1/meeting-series/${seriesId}`)).status).toBe(200);
		expect((await a.as('DELETE', '/v1/meeting-series/nope')).status).toBe(404);
	});

	test('an admin device may end a series it can see', async () => {
		const { a, b, create, calls } = await setup();
		const first = (
			await create(b, { title: 'Bo’s standup', scheduled_at: inHours(1), invitee_person_ids: [a.person.id], recurrence: weekly })
		).body.meeting as Wire;
		expect((await a.as('DELETE', `/v1/meeting-series/${first.series_id}`)).status).toBe(200);
		expect(await calls(b)).toEqual([]);
	});

	test('one invite list is for every occurrence, now and next', async () => {
		const { a, b, c, create, calls } = await setup();
		const first = (
			await create(a, { title: 'Standup', scheduled_at: inHours(1), invitee_person_ids: [b.person.id], recurrence: weekly })
		).body.meeting as Wire;
		await a.as('PUT', `/v1/meetings/${first.id}/invitees`, { person_ids: [c.person.id] });
		expect(await calls(b)).toEqual([]);
		await a.as('DELETE', `/v1/meetings/${first.id}`);
		const next = (await calls(c)).at(0)!;
		expect(next.invitee_person_ids.sort()).toEqual([a.person.id, c.person.id].sort());
		expect(await calls(b)).toEqual([]);
		// Editing the one that was skipped edits the one that is ahead.
		await a.as('PUT', `/v1/meetings/${first.id}/invitees`, { person_ids: [b.person.id] });
		expect((await calls(b)).map((m) => m.id)).toEqual([next.id]);
		expect(await calls(c)).toEqual([]);
	});

	test('the reminder tick puts the next one up once the last has passed', async () => {
		const { a, create, calls, hq } = await setup();
		const first = (
			await create(a, { title: 'Daily', scheduled_at: inHours(1), recurrence: { freq: 'daily', timezone: 'UTC', weekdays: [] } })
		).body.meeting as Wire;
		// Nothing to add while one is ahead.
		await hq.scheduler.run('meetings', 'reminders');
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM meetings').get()).toEqual({ n: 1 });
		// Three days go by with the server asleep: the series started, and its one occurrence was, three days earlier.
		hq.hub.db
			.query('UPDATE meetings SET starts_at = starts_at - $d, ends_at = ends_at - $d WHERE id = $id')
			.run({ id: first.id, d: 3 * DAY });
		hq.hub.db
			.query('UPDATE meeting_series SET anchor_at = anchor_at - $d WHERE id = $id')
			.run({ id: first.series_id, d: 3 * DAY });
		await hq.scheduler.run('meetings', 'reminders');
		const now = Date.now();
		const ahead = await calls(a);
		expect(ahead).toHaveLength(1);
		const at = Date.parse(ahead[0]!.scheduled_at);
		expect(at).toBeGreaterThan(now - 30 * 60_000);
		expect(at).toBeLessThanOrEqual(now + DAY);
		expect(ahead[0]!.series_id).toBe(first.series_id);
	});

	test('keeps a monthly meeting’s wall clock in its own zone', async () => {
		const { a, create } = await setup();
		const made = await create(a, {
			title: 'Review',
			scheduled_at: '2030-01-15T15:00:00Z',
			recurrence: { freq: 'monthly', timezone: 'America/New_York', weekdays: [] },
		});
		expect(made.body.meeting.recurrence).toBe('Monthly on day 15 at 10:00');
	});
});

describe('the meetings frame', () => {
	test('tells each person their own whole list when it changes', async () => {
		const { hq, a, b, c, create } = await setup();
		server = serve(hq);
		const bo = await connect(server, b.bearer);
		const cy = await connect(server, c.bearer);
		// Dee is connected, but has nothing to do with any of it.
		const dee = hq.hub.people.create({ name: 'Dee', handle: 'dee' });
		const d = await enrolled(hq, hq.hub.keys.mint(dee.id, 'setup').secret, 'Dee Mac');
		const outsider = await connect(server, d.bearer);
		open.push(bo, cy, outsider);

		const meeting = (await create(a, { title: 'Sync', scheduled_at: inHours(1), invitee_person_ids: [b.person.id] })).body
			.meeting as Wire;
		const seen = await bo.take('meetings');
		expect(decodeProblems('MeetingsPayload', seen)).toEqual([]);
		expect(seen.meetings.map((m: Wire) => m.id)).toEqual([meeting.id]);

		// Moving Bo out and Cy in: Bo's list is empty now and Cy's has it.
		await a.as('PUT', `/v1/meetings/${meeting.id}/invitees`, { person_ids: [c.person.id] });
		expect((await bo.take('meetings', (f) => f.meetings.length === 0)).meetings).toEqual([]);
		expect((await cy.take('meetings')).meetings.map((m: Wire) => m.id)).toEqual([meeting.id]);

		await a.as('DELETE', `/v1/meetings/${meeting.id}`);
		expect((await cy.take('meetings', (f) => f.meetings.length === 0)).meetings).toEqual([]);
		await outsider.settle();
		expect(outsider.types()).not.toContain('meetings');
	});
});

describe('reminders and repeating meetings that nobody can read', () => {
	const daily = { freq: 'daily', timezone: 'UTC', weekdays: [] };
	const minutes = (n: number) => new Date(Date.now() + n * 60_000).toISOString();
	const reminders = (hq: Awaited<ReturnType<typeof setup>>['hq'], roomId: string) =>
		hq.hub.messages.list(roomId).filter((m) => (m.metadata as { reminder?: boolean } | null)?.reminder === true);
	const state = (hq: Awaited<ReturnType<typeof setup>>['hq'], seriesId: string) => ({
		ended: hq.hub.db
			.query<{ ended_at: number | null }, { id: string }>('SELECT ended_at FROM meeting_series WHERE id = $id')
			.get({ id: seriesId })!.ended_at,
		meetings: hq.hub.db
			.query<{ status: string }, { id: string }>('SELECT status FROM meetings WHERE series_id = $id ORDER BY starts_at')
			.all({ id: seriesId })
			.map((m) => m.status),
	});

	test('a daily series reminds once for each occurrence, never twice', async () => {
		const { a, hq, create } = await setup();
		const first = (await create(a, { title: 'Daily', scheduled_at: minutes(10), recurrence: daily })).body.meeting as Wire;
		await hq.scheduler.run('meetings', 'reminders');
		await hq.scheduler.run('meetings', 'reminders');
		expect(reminders(hq, first.conversation_id)).toHaveLength(1);

		// The occurrence passes; the next is a day off and so not due yet.
		hq.hub.db
			.query('UPDATE meetings SET starts_at = starts_at - $d, ends_at = ends_at - $d WHERE id = $id')
			.run({ id: first.id, d: HOUR });
		await hq.scheduler.run('meetings', 'reminders');
		expect(reminders(hq, first.conversation_id)).toHaveLength(1);
		const next = hq.hub.db
			.query<{ id: string }, { id: string; at: number }>(
				"SELECT id FROM meetings WHERE series_id = $id AND status = 'scheduled' AND ends_at > $at",
			)
			.all({ id: first.series_id!, at: Date.now() });
		expect(next).toHaveLength(1);

		// The day comes round: one more reminder, and ticking on adds none.
		hq.hub.db
			.query('UPDATE meetings SET starts_at = $at, ends_at = $at + 1800000 WHERE id = $id')
			.run({ id: next[0]!.id, at: Date.now() + 10 * 60_000 });
		for (let i = 0; i < 3; i += 1) await hq.scheduler.run('meetings', 'reminders');
		const sent = reminders(hq, first.conversation_id);
		expect(sent).toHaveLength(2);
		expect(new Set(sent.map((m) => (m.metadata as { meeting: string }).meeting)).size).toBe(2);
	});

	test('a meeting in a room that was archived is not reminded', async () => {
		const { a, hq, create } = await setup();
		const meeting = (await create(a, { title: 'Closed', scheduled_at: minutes(10) })).body.meeting as Wire;
		hq.hub.conversations.archive(meeting.conversation_id);
		expect((await hq.scheduler.run('meetings', 'reminders')).output).toBe('nothing starting soon');
		expect(reminders(hq, meeting.conversation_id)).toHaveLength(0);
	});

	test('a series whose room was archived ends, and its next occurrence is never made', async () => {
		const { a, hq, create } = await setup();
		const first = (await create(a, { title: 'Daily', scheduled_at: minutes(10), recurrence: daily })).body.meeting as Wire;
		hq.hub.conversations.archive(first.conversation_id);
		await hq.scheduler.run('meetings', 'reminders');
		expect(state(hq, first.series_id!)).toEqual({ ended: expect.any(Number), meetings: ['cancelled'] });
		expect(reminders(hq, first.conversation_id)).toHaveLength(0);

		// The same when the occurrence ahead has already passed: nothing follows it.
		const other = (await create(a, { title: 'Daily 2', scheduled_at: minutes(10), recurrence: daily })).body.meeting as Wire;
		hq.hub.db
			.query('UPDATE meetings SET starts_at = starts_at - $d, ends_at = ends_at - $d WHERE id = $id')
			.run({ id: other.id, d: 3 * DAY });
		hq.hub.db
			.query('UPDATE meeting_series SET anchor_at = anchor_at - $d WHERE id = $id')
			.run({ id: other.series_id, d: 3 * DAY });
		hq.hub.conversations.archive(other.conversation_id);
		await hq.scheduler.run('meetings', 'reminders');
		await hq.scheduler.run('meetings', 'reminders');
		expect(state(hq, other.series_id!)).toEqual({ ended: expect.any(Number), meetings: ['scheduled'] });
	});

	test('a series whose organizer was removed ends, with what was ahead cancelled', async () => {
		const { b, hq, create } = await setup();
		const first = (await create(b, { title: 'Bo’s daily', scheduled_at: minutes(10), recurrence: daily })).body.meeting as Wire;
		hq.hub.people.setRemoved(b.person.id, Date.now());
		await hq.scheduler.run('meetings', 'reminders');
		expect(state(hq, first.series_id!)).toEqual({ ended: expect.any(Number), meetings: ['cancelled'] });
		expect(reminders(hq, first.conversation_id)).toHaveLength(0);
	});

	test('an admin skipping an occurrence of a removed organizer’s series ends it instead of making another', async () => {
		const { a, b, hq, create } = await setup();
		const first = (
			await create(b, { title: 'Bo’s daily', scheduled_at: minutes(10), invitee_person_ids: [a.person.id], recurrence: daily })
		).body.meeting as Wire;
		hq.hub.people.setRemoved(b.person.id, Date.now());
		expect((await a.as('DELETE', `/v1/meetings/${first.id}`)).status).toBe(200);
		expect(state(hq, first.series_id!)).toEqual({ ended: expect.any(Number), meetings: ['cancelled'] });
	});
});

describe('the list the app polls', () => {
	test('reads the start index, not every meeting ever made', async () => {
		const { hq } = await setup();
		const plan = hq.hub.db
			.query<{ detail: string }, { p: string; at: number; earliest: number; limit: number }>(`EXPLAIN QUERY PLAN ${VISIBLE_NOW}`)
			.all({ p: 'x', at: Date.now(), earliest: Date.now() - DAY, limit: 200 })
			.map((row) => row.detail);
		expect(plan.some((detail) => /SEARCH m USING INDEX meetings_starts \(starts_at>\?\)/.test(detail))).toBe(true);
		expect(plan.some((detail) => /SCAN m(?! USING)/.test(detail))).toBe(false);
	});

	test('still lists a day-long meeting that started most of a day ago, and not one that has ended', async () => {
		const { a, hq, calls } = await setup();
		const insert = hq.hub.db.query(
			`INSERT INTO meetings (id, title, starts_at, ends_at, room_id, organizer_id, status, created_at)
			VALUES ($id, $id, $start, $end, $room, $organizer, 'scheduled', 0)`,
		);
		const room = hq.hub.general().id;
		insert.run({ id: 'long', start: Date.now() - 23 * HOUR, end: Date.now() + HOUR, room, organizer: a.person.id });
		insert.run({ id: 'over', start: Date.now() - 30 * HOUR, end: Date.now() - 6 * HOUR, room, organizer: a.person.id });
		expect((await calls(a)).map((m) => m.id)).toEqual(['long']);
	});
});

describe('the migration', () => {
	test('keeps the meetings that were there and their ids', () => {
		const prefixed = appMigrations([{ slug: 'meetings', name: 'm', description: 'm', migrations }]);
		const hub = Hub.open(':memory:', prefixed.slice(0, 2));
		const person = hub.people.create({ name: 'Ada', handle: 'ada' });
		const room = hub.general();
		hub.db
			.query(
				`INSERT INTO meetings (id, title, agenda, starts_at, ends_at, room_id, organizer_id, status, created_at)
				VALUES ('keep-me', 'Old', 'agenda', 5, 10, $room, $person, 'scheduled', 1)`,
			)
			.run({ room: room.id, person: person.id });
		hub.db.query("INSERT INTO meeting_attendees (meeting_id, person_id) VALUES ('keep-me', $person)").run({ person: person.id });

		migrate(hub.db, [...CORE_MIGRATIONS, ...prefixed]);
		expect(hub.db.query('SELECT id, title, agenda, series_id, own_room FROM meetings').all()).toEqual([
			{ id: 'keep-me', title: 'Old', agenda: 'agenda', series_id: null, own_room: 0 },
		]);
		expect(hub.db.query('SELECT COUNT(*) AS n FROM meeting_attendees').get()).toEqual({ n: 1 });
	});
});
