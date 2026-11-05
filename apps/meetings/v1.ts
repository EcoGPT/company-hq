import { HttpError, json, readBody, z, type AppRequestContext, type AppRoute, type Hub, type Person } from '@hq/sdk';
import { FREQUENCIES, validTimezone, type Rule } from './recurrence';
import { Meetings, type Meeting } from './store';
import { parseTime } from './time';
import { affected, presentWire, sendMeetings } from './wire';

const MINUTE = 60_000;
/** The app has no length to choose, so every meeting is this long. */
const LENGTH = 30 * MINUTE;
const MAX_AHEAD = 10 * 365 * 24 * 60 * MINUTE;
/** Per person, so one account cannot fill the server with rooms. */
export const MAX_INVITEES = 100;
export const MAX_MEETINGS_AHEAD = 100;
export const MAX_OPEN_SERIES = 20;
const BODY_LIMIT = 64 * 1024;

const createSchema = z.object({
	title: z.string().trim().min(1).max(200),
	scheduled_at: z.string().max(40).nullish(),
	invitee_person_ids: z.array(z.string().max(64)).max(MAX_INVITEES).default([]),
	recurrence: z
		.object({
			freq: z.enum(FREQUENCIES),
			timezone: z.string().max(64),
			weekdays: z.array(z.number().int().min(0).max(6)).max(7).default([]),
		})
		.nullish(),
});

const inviteesSchema = z.object({ person_ids: z.array(z.string().max(64)).max(MAX_INVITEES) });

const notFound = () => new HttpError(404, 'meeting_not_found');

/** Everyone named must be a person on this server who signs in and has not been removed. */
function people(hub: Hub, ids: string[], organizerId: string): string[] {
	for (const id of ids) {
		const person = hub.people.get(id);
		if (person === null || person.kind !== 'human' || person.removed_at !== null) throw new HttpError(404, 'person_not_found');
	}
	return [...new Set(ids)].filter((id) => id !== organizerId);
}

/** The organizer, or an admin on a signed-in device: a script key of an admin does not run other people's meetings. */
function mayManage(ctx: AppRequestContext, organizerId: string): boolean {
	if (organizerId === ctx.person.id) return true;
	const actor: Person | null = ctx.hub.people.get(ctx.person.id);
	return ctx.keyKind === 'device' && actor?.role === 'admin' && actor.removed_at === null && ctx.hub.keys.isActive(ctx.keyId);
}

/** The meeting if this person can see it; one they cannot see is as good as missing. */
function visible(ctx: AppRequestContext, id: string): Meeting {
	const store = new Meetings(ctx.hub);
	const meeting = store.get(id);
	if (meeting === null || !store.canSee(meeting.id, ctx.person.id)) throw notFound();
	return meeting;
}

function create(ctx: AppRequestContext, body: z.infer<typeof createSchema>) {
	const { hub, person } = ctx;
	const store = new Meetings(hub);
	const at = Date.now();
	let startsAt = at;
	if (body.scheduled_at != null) {
		try {
			startsAt = parseTime(body.scheduled_at);
		} catch {
			throw new HttpError(400, 'invalid_time');
		}
	}
	if (startsAt + LENGTH < at) throw new HttpError(400, 'in_the_past');
	if (startsAt > at + MAX_AHEAD) throw new HttpError(400, 'too_far_ahead');
	const rule: Rule | null =
		body.recurrence == null
			? null
			: {
					freq: body.recurrence.freq,
					timezone: body.recurrence.timezone,
					weekdays:
						body.recurrence.freq === 'weekly' || body.recurrence.freq === 'biweekly'
							? [...new Set(body.recurrence.weekdays)].sort()
							: [],
				};
	if (rule !== null && !validTimezone(rule.timezone)) throw new HttpError(400, 'invalid_timezone');
	const invitees = people(hub, body.invitee_person_ids, person.id);
	if (store.countAhead(person.id, at) >= MAX_MEETINGS_AHEAD) throw new HttpError(429, 'too_many_meetings');
	if (rule !== null && store.countOpenSeries(person.id) >= MAX_OPEN_SERIES) throw new HttpError(429, 'too_many_series');

	const room = hub.conversations.createRoom({ title: body.title, createdBy: person.id, memberIds: [person.id, ...invitees] });
	const meeting = hub.db.transaction(() => {
		const series =
			rule === null
				? null
				: store.createSeries({ organizerId: person.id, title: body.title, rule, anchor: startsAt, durationMs: LENGTH });
		return store.schedule({
			title: body.title,
			startsAt,
			endsAt: startsAt + LENGTH,
			roomId: room.id,
			organizerId: person.id,
			attendeeIds: invitees,
			seriesId: series?.id,
			ownRoom: true,
		});
	})();
	sendMeetings(hub, affected(hub, [meeting]));
	return json({ meeting: presentWire(hub, [meeting])[0] }, 201);
}

/** Makes `ids` the whole invite list. Rooms opened for the meeting follow it; a shared room is left as it is. */
function invite(ctx: AppRequestContext, meeting: Meeting, ids: string[]) {
	const { hub } = ctx;
	const store = new Meetings(hub);
	const invitees = people(hub, ids, meeting.organizer_id);
	// A repeating meeting has one thread and one list for all of it.
	const targets = new Map<string, Meeting>([[meeting.id, meeting]]);
	if (meeting.series_id !== null) for (const m of store.aheadInSeries(meeting.series_id, Date.now())) targets.set(m.id, m);
	const before = affected(hub, [...targets.values()]);
	for (const target of targets.values()) store.setAttendees(target.id, invitees);

	const room = hub.conversations.get(meeting.room_id);
	if (room !== null && room.archived_at === null && room.kind === 'room') {
		const members = hub.conversations.memberIds(room.id);
		// A room made for the meeting follows its list. A shared room is not the meeting's to open: as in core, only someone
		// in it now adds people, and the invitees are otherwise just recorded on the meeting.
		if (meeting.own_room === 1 || hub.conversations.isMember(room.id, ctx.person.id)) {
			for (const id of invitees) hub.conversations.addMember(room.id, id);
		}
		if (meeting.own_room === 1) {
			const keep = new Set([meeting.organizer_id, ...invitees]);
			const dropped = members.filter((id) => !keep.has(id) && hub.people.get(id)?.kind === 'human');
			for (const id of dropped) {
				hub.conversations.removeMember(room.id, id);
				hub.bus.emit({ type: 'conversation.removed', conversationId: room.id, audience: [id] });
			}
		}
		hub.bus.emit({ type: 'conversation.changed', conversationId: room.id, audience: hub.conversations.memberIds(room.id) });
	}
	sendMeetings(hub, [...before, ...affected(hub, [...targets.values()])]);
	return { meeting: presentWire(hub, [store.get(meeting.id)!])[0] };
}

function cancel(ctx: AppRequestContext) {
	const { hub } = ctx;
	const store = new Meetings(hub);
	const meeting = visible(ctx, ctx.params.id ?? '');
	if (!mayManage(ctx, meeting.organizer_id)) throw new HttpError(403, 'forbidden');
	const people = affected(hub, [meeting]);
	if (meeting.status === 'scheduled') store.update(meeting, { status: 'cancelled' });
	// The next occurrence takes its place.
	const series = meeting.series_id === null ? null : store.series(meeting.series_id);
	if (series !== null) store.advance(series, Date.now());
	sendMeetings(hub, people);
	return { ok: true };
}

function endSeries(ctx: AppRequestContext) {
	const { hub } = ctx;
	const store = new Meetings(hub);
	const series = store.series(ctx.params.id ?? '');
	if (series === null || !store.canSeeSeries(series.id, ctx.person.id)) throw new HttpError(404, 'series_not_found');
	if (!mayManage(ctx, series.organizer_id)) throw new HttpError(403, 'forbidden');
	const ended = store.endSeries(series.id, Date.now());
	sendMeetings(hub, affected(hub, ended, [series.organizer_id]));
	return { ok: true };
}

export const routes: AppRoute[] = [
	{
		method: 'POST',
		path: '/v1/meetings',
		mount: 'v1',
		maxBodyBytes: BODY_LIMIT,
		handler: async (ctx) => create(ctx, await readBody(ctx.req, createSchema)),
	},
	{
		method: 'PUT',
		path: '/v1/meetings/:id/invitees',
		mount: 'v1',
		maxBodyBytes: BODY_LIMIT,
		handler: async (ctx) => {
			// The body takes time to arrive, so who is asking and what the meeting is are looked at after it.
			const body = await readBody(ctx.req, inviteesSchema);
			const meeting = visible(ctx, ctx.params.id ?? '');
			if (!mayManage(ctx, meeting.organizer_id)) throw new HttpError(403, 'forbidden');
			return invite(ctx, meeting, body.person_ids);
		},
	},
	{ method: 'DELETE', path: '/v1/meetings/:id', mount: 'v1', handler: cancel },
	{ method: 'DELETE', path: '/v1/meeting-series/:id', mount: 'v1', handler: endSeries },
];
