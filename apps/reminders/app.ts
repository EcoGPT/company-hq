import {
	defineApp,
	defineAutomation,
	defineTool,
	HttpError,
	type Hub,
	type Person,
	personByHandle,
	type ToolContext,
	ToolError,
	z,
} from '@hq/sdk';
import { migrations, parseWhen, Reminders, type Reminder } from './store';

const YEAR = 366 * 86_400_000;
const LATE_MS = 15 * 60_000;

function speaker(hub: Hub, conversationId: string | undefined): Person | null {
	if (conversationId === undefined) return null;
	const recent = hub.messages.list(conversationId, { limit: 20 }).reverse();
	const authors = hub.people.byIds(recent.map((m) => m.author_id));
	for (const message of recent) {
		const author = authors.get(message.author_id);
		if (author?.kind === 'human') return author;
	}
	return null;
}

const asker = (ctx: ToolContext) => (ctx.caller.kind === 'human' ? ctx.caller : speaker(ctx.hub, ctx.conversationId));

function target(ctx: ToolContext, handle: string | undefined, from: Person | null = asker(ctx)): Person {
	if (handle !== undefined && handle !== '') return personByHandle(ctx.hub, handle);
	if (from === null) throw new ToolError('say who the reminder is for with for_handle');
	return from;
}

function visible(hub: Hub, reminder: Reminder, audience: string[]): boolean {
	if (audience.every((id) => id === reminder.person_id || id === reminder.created_by)) return true;
	return [reminder.room_id, reminder.source_id].some(
		(where) => where !== null && audience.every((id) => hub.conversations.isMember(where, id)),
	);
}

const audience = (ctx: ToolContext) => [...(ctx.caller.kind === 'assistant' ? [] : [ctx.caller.id]), ...(ctx.viewers ?? [])];

const recipients = (hub: Hub, reminders: Reminder[]) => hub.people.byIds(reminders.map((r) => r.person_id));

function present(hub: Hub, reminder: Reminder, people: Map<string, Person> = recipients(hub, [reminder])) {
	const person = people.get(reminder.person_id);
	const room = reminder.room_id === null ? null : hub.conversations.get(reminder.room_id);
	return {
		id: reminder.id,
		for: person === undefined ? null : `@${person.handle}`,
		text: reminder.text,
		due: new Date(reminder.due_at).toISOString(),
		where: room === null ? 'DM' : room.title,
	};
}

function presentAll(hub: Hub, reminders: Reminder[]) {
	const people = recipients(hub, reminders);
	return reminders.map((reminder) => present(hub, reminder, people));
}

function changed(hub: Hub, id: string): void {
	hub.bus.emit({ type: 'app.event', app: 'reminders', name: 'changed', data: { id } });
}

export default defineApp({
	slug: 'reminders',
	name: 'Reminders',
	description: 'One-off reminders, delivered by the assistant as a DM or in a room.',
	icon: '◷',
	briefing:
		'When someone says "remind me…" or "remind @bo…", call set_reminder. For relative times pass "in 2h" or "in 3d". For clock times ("tomorrow 9am", "Friday at 4") convert to ISO 8601 with the person\'s UTC offset, using Now from this prompt; if you do not know their timezone, ask or say which one you assumed. Confirm the time back in plain words.',
	migrations,
	tools: [
		defineTool({
			name: 'set_reminder',
			description:
				'Schedule a reminder. Delivered as a DM from you, or in the current room when in_room is true. Defaults to the person who asked.',
			input: z.object({
				text: z.string().min(1).max(1000).describe('What to remind them about, phrased for them'),
				when: z
					.string()
					.describe('"in 30m", "in 2h", "in 3d", or an ISO 8601 time with offset such as 2026-11-02T09:00:00-05:00'),
				for_handle: z.string().optional().describe('Who to remind; defaults to whoever asked'),
				in_room: z.boolean().default(false).describe('Post in the current room instead of a DM'),
			}),
			activity: 'Setting a reminder',
			run: ({ text, when, for_handle, in_room }, ctx) => {
				const at = Date.now();
				const dueAt = parseWhen(when, at);
				if (dueAt === null) throw new ToolError(`could not read "${when}": use "in 2h" or an ISO 8601 time with an offset`);
				if (dueAt < at - 60_000) throw new ToolError(`${new Date(dueAt).toISOString()} is in the past`);
				if (dueAt > at + YEAR) throw new ToolError('reminders can be at most a year out');
				let roomId: string | null = null;
				if (in_room) {
					const room = ctx.conversationId === undefined ? null : ctx.hub.conversations.get(ctx.conversationId);
					if (room === null || room.kind !== 'room') throw new ToolError('in_room only works from a room');
					roomId = room.id;
				}
				const from = asker(ctx);
				const reminder = new Reminders(ctx.hub).add({
					personId: target(ctx, for_handle, from).id,
					roomId,
					text,
					dueAt,
					createdBy: (from ?? ctx.caller).id,
					sourceId: ctx.conversationId ?? null,
				});
				changed(ctx.hub, reminder.id);
				return present(ctx.hub, reminder);
			},
		}),
		defineTool({
			name: 'list_reminders',
			description: 'List reminders that have not gone off yet, for everyone or one person.',
			input: z.object({ for_handle: z.string().optional() }),
			activity: 'Checking reminders',
			run: ({ for_handle }, ctx) => {
				const person = for_handle === undefined ? undefined : target(ctx, for_handle);
				const seenBy = audience(ctx);
				return presentAll(
					ctx.hub,
					new Reminders(ctx.hub).pending(person?.id).filter((r) => visible(ctx.hub, r, seenBy)),
				);
			},
		}),
		defineTool({
			name: 'cancel_reminder',
			description: 'Cancel a reminder that has not gone off yet.',
			input: z.object({ id: z.string() }),
			activity: 'Cancelling a reminder',
			run: ({ id }, ctx) => {
				const store = new Reminders(ctx.hub);
				const reminder = store.get(id);
				if (reminder === null || !visible(ctx.hub, reminder, audience(ctx)) || !store.cancel(id))
					throw new ToolError(`no pending reminder ${id}`);
				changed(ctx.hub, id);
				return { cancelled: id };
			},
		}),
	],
	routes: [
		{
			method: 'GET',
			path: 'reminders',
			handler: ({ hub, person }) =>
				presentAll(
					hub,
					new Reminders(hub).pending().filter((r) => visible(hub, r, [person.id])),
				),
		},
		{
			method: 'DELETE',
			path: 'reminders/:id',
			handler: ({ hub, params, app, person }) => {
				const store = new Reminders(hub);
				const reminder = store.get(params.id ?? '');
				if (reminder === null || !visible(hub, reminder, [person.id]) || !store.cancel(reminder.id))
					throw new HttpError(404, 'no pending reminder');
				app.emit('changed', { id: reminder.id });
			},
		},
	],
	automations: [
		defineAutomation({
			slug: 'deliver',
			name: 'Deliver reminders',
			description: 'Every minute, sends reminders that are due.',
			schedule: '@every 1m',
			run({ hub, assistant, log }) {
				const store = new Reminders(hub);
				const at = Date.now();
				const due = store.due(at);
				const people = hub.people.byIds(due.flatMap((r) => [r.person_id, r.created_by]));
				for (const reminder of due) {
					const person = people.get(reminder.person_id);
					if (person === undefined) {
						store.cancel(reminder.id);
						continue;
					}
					const late =
						at - reminder.due_at > LATE_MS
							? ` (due ${new Date(reminder.due_at).toISOString().slice(0, 16).replace('T', ' ')} UTC)`
							: '';
					const by =
						reminder.created_by === person.id || reminder.created_by === assistant.self.id
							? ''
							: ` — from ${people.get(reminder.created_by)?.name ?? 'a teammate'}`;
					const metadata = { app: 'reminders', reminder: reminder.id };
					if (reminder.room_id !== null) {
						assistant.post(reminder.room_id, `⏰ @${person.handle} reminder: ${reminder.text}${late}${by}`, metadata);
					} else {
						const dm = hub.conversations.dm(assistant.self.id, person.id);
						assistant.post(dm.id, `⏰ Reminder: ${reminder.text}${late}${by}`, metadata);
					}
					store.delivered(reminder.id);
					changed(hub, reminder.id);
					log(`delivered ${reminder.id} to @${person.handle}`);
				}
				return due.length === 0 ? undefined : `delivered ${due.length}`;
			},
		}),
	],
});
