import {
	type AppContext,
	AudioTooLarge,
	canSee,
	defineApp,
	defineTool,
	HttpError,
	type Hub,
	type Person,
	personByHandle,
	readBody,
	type ToolContext,
	ToolError,
	z,
} from '@hq/sdk';
import { callRecap, callTarget } from './call';
import { calendar } from './ics';
import { parseTime } from './time';
import { routes as v1Routes } from './v1';
import { meetingsFor } from './wire';
import { recapMeeting } from './recap';
import reminders from './reminders';
import { Meetings, migrations, type ActionItem, type Meeting } from './store';

const MINUTE = 60_000;
const contexts = new WeakMap<Hub, AppContext>();

const personId = (hub: Hub, handle: string): string => personByHandle(hub, handle).id;

function changed(hub: Hub, meeting: Meeting): Meeting {
	hub.bus.emit({ type: 'app.event', app: 'meetings', name: 'changed', data: { id: meeting.id } });
	return meeting;
}

type Lookup = { attendees: Map<string, string[]>; people: Map<string, Person> };

function lookup(hub: Hub, meetings: Meeting[]): Lookup {
	const attendees = new Meetings(hub).attendeesOf(meetings.map((m) => m.id));
	const people = hub.people.byIds([...meetings.map((m) => m.organizer_id), ...[...attendees.values()].flat()]);
	return { attendees, people };
}

function present(hub: Hub, meeting: Meeting, { attendees, people }: Lookup = lookup(hub, [meeting])) {
	const handle = (id: string) => `@${people.get(id)?.handle ?? 'unknown'}`;
	const room = hub.conversations.get(meeting.room_id);
	return {
		id: meeting.id,
		title: meeting.title,
		agenda: meeting.agenda,
		starts_at: new Date(meeting.starts_at).toISOString(),
		ends_at: new Date(meeting.ends_at).toISOString(),
		status: meeting.status,
		room: { id: meeting.room_id, title: room?.title ?? null },
		organizer: handle(meeting.organizer_id),
		attendees: (attendees.get(meeting.id) ?? []).map(handle),
		summary: meeting.summary,
		action_items: meeting.action_items === null ? [] : (JSON.parse(meeting.action_items) as ActionItem[]),
		has_transcript: meeting.transcript !== null,
	};
}

function presentAll(hub: Hub, meetings: Meeting[]) {
	const found = lookup(hub, meetings);
	return meetings.map((meeting) => present(hub, meeting, found));
}

function icsResponse(hub: Hub, who: Person, viewer: Person, origin: string): Response {
	const meetings = new Meetings(hub).list({ when: 'all', personId: who.id, seenBy: [viewer.id], limit: 500 });
	const { attendees, people } = lookup(hub, meetings);
	const base = hub.publicUrl ?? origin;
	const events = meetings.map((m) => {
		const handles = (attendees.get(m.id) ?? []).map((id) => `@${people.get(id)?.handle ?? 'unknown'}`);
		const room = hub.conversations.get(m.room_id);
		return {
			uid: `${m.id}@hq`,
			start: m.starts_at,
			end: m.ends_at,
			title: m.title,
			description: [m.agenda, handles.length > 0 ? `Attendees: ${handles.join(', ')}` : '', m.summary ?? '']
				.filter(Boolean)
				.join('\n\n'),
			location: room === null ? undefined : `HQ · ${room.title}`,
			url: `${base}/#/c/${m.room_id}`,
			cancelled: m.status === 'cancelled',
		};
	});
	return new Response(calendar(`${who.name} · HQ meetings`, events), {
		headers: { 'content-type': 'text/calendar; charset=utf-8', 'content-disposition': `inline; filename="${who.handle}.ics"` },
	});
}

function keyedSince(hub: Hub, personId: string, issued: number): boolean {
	let covered = issued;
	for (const key of hub.keys.list(personId)) {
		if (key.created_at > covered) return false;
		covered = Math.max(covered, key.revoked_at ?? Number.POSITIVE_INFINITY);
		if (covered === Number.POSITIVE_INFINITY) return true;
	}
	return false;
}

function canEdit(store: Meetings, meeting: Meeting, ctx: ToolContext): boolean {
	const { hub, caller, viewers = [] } = ctx;
	if (hub.conversations.get(meeting.room_id)?.archived_at !== null) return false;
	const attendees = store.attendeeIds(meeting.id);
	const may = (person: Person | undefined) =>
		person !== undefined && (person.role === 'admin' || meeting.organizer_id === person.id || attendees.includes(person.id));
	if (caller.kind !== 'assistant')
		return may(caller) && (caller.role === 'admin' || hub.conversations.isMember(meeting.room_id, caller.id));
	if (!canSee(ctx, meeting.room_id)) return false;
	if (ctx.requester !== undefined) {
		const requester = hub.people.get(ctx.requester) ?? undefined;
		return requester?.kind === 'human' && may(requester);
	}
	const people = hub.people.byIds(viewers);
	return viewers.every((id) => may(people.get(id)));
}

function editable(app: AppContext, id: string, person: Person): Meeting {
	const store = new Meetings(app.hub);
	const meeting = store.get(id);
	if (meeting === null) throw new HttpError(404, 'meeting not found');
	if (!canEdit(store, meeting, { hub: app.hub, caller: person }))
		throw new HttpError(403, 'only the organizer, attendees or an admin can do that');
	return meeting;
}

async function recapOrHttpError(app: AppContext, meeting: Meeting, transcript: string) {
	if (transcript.trim() === '') throw new HttpError(400, 'the transcript is empty');
	const result = await recapMeeting(app, meeting, transcript);
	return { ...present(app.hub, result.meeting), message_id: result.message_id };
}

function chooseRoom(
	ctx: ToolContext,
	input: { roomId?: string; conversationId?: string; title: string; memberIds: string[]; createdBy: string },
) {
	const { hub } = ctx;
	if (input.roomId !== undefined) {
		const room = hub.conversations.get(input.roomId);
		if (room === null || !canSee(ctx, room.id)) throw new ToolError(`no conversation ${input.roomId} that you are in`);
		return room;
	}
	const here = input.conversationId === undefined ? null : hub.conversations.get(input.conversationId);
	if (here?.kind === 'room') return here;
	return hub.conversations.createRoom({ title: input.title, createdBy: input.createdBy, memberIds: input.memberIds });
}

function schedule(
	ctx: ToolContext,
	input: {
		title: string;
		starts_at: string;
		duration_minutes: number;
		attendee_handles: string[];
		agenda?: string;
		room_id?: string;
		organizer_handle?: string;
	},
): Meeting {
	const { hub, caller, conversationId } = ctx;
	const startsAt = parseTime(input.starts_at);
	const organizerId = input.organizer_handle === undefined ? caller.id : personId(hub, input.organizer_handle);
	const attendeeIds = [...new Set(input.attendee_handles.map((handle) => personId(hub, handle)))];
	const room = chooseRoom(ctx, {
		roomId: input.room_id,
		conversationId,
		title: input.title,
		memberIds: [organizerId, ...attendeeIds],
		createdBy: caller.id,
	});
	if (room.kind === 'room') for (const id of [organizerId, ...attendeeIds]) hub.conversations.addMember(room.id, id);
	const meeting = new Meetings(hub).schedule({
		title: input.title,
		agenda: input.agenda,
		startsAt,
		endsAt: startsAt + input.duration_minutes * MINUTE,
		roomId: room.id,
		organizerId,
		attendeeIds,
	});
	return changed(hub, meeting);
}

const scheduleInput = z.object({
	title: z.string().min(1).max(200),
	starts_at: z.string().describe('ISO 8601 with a UTC offset, like 2026-10-20T15:00:00Z'),
	duration_minutes: z
		.number()
		.int()
		.min(5)
		.max(24 * 60)
		.default(30),
	attendee_handles: z.array(z.string()).default([]),
	agenda: z.string().max(4000).optional(),
	room_id: z
		.string()
		.optional()
		.describe('Where reminders and the recap go. Defaults to this room, or a new room for the meeting.'),
	organizer_handle: z
		.string()
		.optional()
		.describe('Who runs it. Defaults to the caller; pass the asker when scheduling for someone.'),
});

export default defineApp({
	slug: 'meetings',
	name: 'Meetings',
	description: 'Schedule calls, get reminders, and turn recordings into recaps.',
	icon: '☎\uFE0E',
	briefing:
		'Schedule meetings with schedule_meeting when someone asks for a call: a clear title, the time in ISO 8601 with an offset (ask if the time zone is unclear), attendees by handle, and the asker as organizer_handle. Use list_meetings to answer "what is on my calendar". Reschedule or cancel with update_meeting. When someone shares notes or a transcript from a meeting, run recap_meeting: it posts the recap to the meeting room and files the action items as tasks, so do not file them again.',
	migrations,
	automations: [reminders],
	calls: ({ hub }, person) => ({ meetings: meetingsFor(hub, person.id) }),
	callTarget,
	isMeetingRoom: ({ hub }, conversationId) => new Meetings(hub).ownsRoom(conversationId),
	callRecap,
	tools: [
		defineTool({
			name: 'schedule_meeting',
			description: 'Schedule a meeting. Reminders and the recap are posted to its room.',
			input: scheduleInput,
			activity: 'Scheduling a meeting',
			run: (input, ctx) => present(ctx.hub, schedule(ctx, input)),
		}),
		defineTool({
			name: 'list_meetings',
			description: 'List meetings: upcoming (soonest first), past (latest first) or all. Optionally only those one person is in.',
			input: z.object({
				when: z.enum(['upcoming', 'past', 'all']).default('upcoming'),
				attendee_handle: z.string().optional(),
				limit: z.number().int().min(1).max(100).default(20),
			}),
			activity: 'Checking the calendar',
			run: ({ when, attendee_handle, limit }, { hub, caller, viewers = [] }) => {
				const attendee = attendee_handle === undefined ? undefined : personId(hub, attendee_handle);
				return presentAll(hub, new Meetings(hub).list({ when, personId: attendee, seenBy: [caller.id, ...viewers], limit }));
			},
		}),
		defineTool({
			name: 'update_meeting',
			description: 'Rename, reschedule, add attendees to, cancel or restore a meeting.',
			input: z.object({
				id: z.string(),
				title: z.string().min(1).max(200).optional(),
				starts_at: z.string().optional(),
				duration_minutes: z
					.number()
					.int()
					.min(5)
					.max(24 * 60)
					.optional(),
				add_attendee_handles: z.array(z.string()).optional(),
				status: z.enum(['scheduled', 'cancelled']).optional(),
			}),
			activity: 'Updating a meeting',
			run: (input, ctx) => {
				const { hub } = ctx;
				const store = new Meetings(hub);
				const meeting = store.get(input.id);
				if (meeting === null) throw new ToolError(`no meeting ${input.id}`);
				if (!canEdit(store, meeting, ctx))
					throw new ToolError('only the organizer, attendees or an admin can change this meeting');
				const startsAt = input.starts_at === undefined ? meeting.starts_at : parseTime(input.starts_at);
				const duration =
					input.duration_minutes === undefined ? meeting.ends_at - meeting.starts_at : input.duration_minutes * MINUTE;
				if (input.add_attendee_handles !== undefined) {
					const ids = input.add_attendee_handles.map((handle) => personId(hub, handle));
					store.addAttendees(meeting.id, ids);
					if (hub.conversations.get(meeting.room_id)?.kind === 'room')
						for (const id of ids) hub.conversations.addMember(meeting.room_id, id);
				}
				const updated = store.update(meeting, {
					...(input.title === undefined ? {} : { title: input.title }),
					...(input.status === undefined ? {} : { status: input.status }),
					starts_at: startsAt,
					ends_at: startsAt + duration,
				});
				return present(hub, changed(hub, updated));
			},
		}),
		defineTool({
			name: 'recap_meeting',
			description:
				'Summarize a meeting from its transcript or notes: posts decisions and action items to the meeting room and files the action items as tasks.',
			input: z.object({ id: z.string(), transcript: z.string().min(1).max(200_000) }),
			activity: 'Writing the meeting recap',
			run: async ({ id, transcript }, ctx) => {
				const { hub } = ctx;
				const app = contexts.get(hub);
				if (app === undefined) throw new ToolError('the meetings app is not running');
				const store = new Meetings(hub);
				const meeting = store.get(id);
				if (meeting === null) throw new ToolError(`no meeting ${id}`);
				if (!canEdit(store, meeting, ctx))
					throw new ToolError('only the organizer, attendees or an admin can recap this meeting');
				const result = await recapMeeting(app, meeting, transcript);
				return {
					posted_to: result.meeting.room_id,
					decisions: result.decisions,
					action_items: result.action_items,
					tasks_filed: result.tasks_filed,
				};
			},
		}),
	],
	setup(app) {
		contexts.set(app.hub, app);
		return () => contexts.delete(app.hub);
	},
	routes: [
		...v1Routes,
		{
			method: 'GET',
			path: 'meetings',
			handler: ({ hub, url, person }) => {
				const raw = url.searchParams.get('when');
				const when = raw === 'past' || raw === 'all' ? raw : 'upcoming';
				return presentAll(hub, new Meetings(hub).list({ when, seenBy: [person.id] }));
			},
		},
		{
			method: 'POST',
			path: 'meetings',
			handler: async ({ hub, req, person }) => {
				const body = await readBody(req, scheduleInput);
				return present(hub, schedule({ hub, caller: person }, body));
			},
		},
		{
			method: 'GET',
			path: 'meetings/:id',
			handler: ({ hub, params, person }) => {
				const meeting = new Meetings(hub).get(params.id ?? '');
				if (meeting === null || !hub.conversations.isMember(meeting.room_id, person.id))
					throw new HttpError(404, 'meeting not found');
				return present(hub, meeting);
			},
		},
		{
			method: 'POST',
			path: 'meetings/:id/transcript',
			handler: async ({ req, params, person, app }) => {
				const meeting = editable(app, params.id ?? '', person);
				const body = await readBody(req, z.object({ transcript: z.string().max(200_000) }));
				return recapOrHttpError(app, meeting, body.transcript);
			},
		},
		{
			method: 'POST',
			path: 'meetings/:id/recording',
			// A recording is audio, not JSON.
			maxBodyBytes: 100 * 1024 * 1024,
			handler: async ({ req, params, person, app }) => {
				const meeting = editable(app, params.id ?? '', person);
				if (!app.ai.has('transcribe')) throw new HttpError(503, 'speech-to-text is not configured (set HQ_STT_MODEL)');
				let audio: Blob;
				let filename: string | undefined;
				if ((req.headers.get('content-type') ?? '').startsWith('multipart/form-data')) {
					const form = await req.formData().catch((error: unknown) => {
						throw error instanceof HttpError ? error : new HttpError(400, 'the upload is not valid multipart form data');
					});
					const file = form.get('file');
					if (!(file instanceof Blob)) throw new HttpError(400, 'send the recording as a "file" field');
					audio = file;
					filename = file instanceof File ? file.name : undefined;
				} else {
					// The body is read through a size-counting stream, which does not carry the type over by itself.
					audio = new Blob([await req.arrayBuffer()], { type: req.headers.get('content-type') ?? '' });
					filename = new URL(req.url).searchParams.get('filename') ?? undefined;
				}
				if (audio.size === 0) throw new HttpError(400, 'the recording is empty');
				const { text } = await app.ai.transcribe(audio, { filename }).catch((error: unknown) => {
					throw error instanceof AudioTooLarge ? new HttpError(413, error.message) : error;
				});
				return recapOrHttpError(app, meeting, text);
			},
		},
		{
			method: 'GET',
			path: 'calendar/:handle',
			handler: ({ hub, params, person, url }) => {
				const handle = (params.handle ?? '').replace(/\.ics$/, '');
				const who = handle === 'me' ? person : hub.people.byHandle(handle);
				if (who === null) throw new HttpError(404, 'nobody has that handle');
				return icsResponse(hub, who, person, url.origin);
			},
		},
		{
			method: 'POST',
			path: 'feed',
			handler: ({ hub, person }) => {
				const path = `/apps/meetings/api/feed/${new Meetings(hub).rotateFeed(person.id)}.ics`;
				return { path, url: hub.link(path) };
			},
		},
		{
			method: 'GET',
			path: 'feed/:token',
			access: 'public',
			handler: ({ hub, params, url }) => {
				const feed = new Meetings(hub).feed((params.token ?? '').replace(/\.ics$/, ''));
				const who = feed === null ? null : hub.people.get(feed.person_id);
				if (feed === null || who === null || !keyedSince(hub, who.id, feed.created_at))
					throw new HttpError(404, 'unknown calendar feed');
				return icsResponse(hub, who, who, url.origin);
			},
		},
	],
});
