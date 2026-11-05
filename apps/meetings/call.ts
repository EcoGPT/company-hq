import { HttpError, type AppContext, type AppDefinition, type Person } from '@hq/sdk';
import { recapMeeting } from './recap';
import { Meetings, type ActionItem } from './store';
import { MAX_MEETINGS_AHEAD } from './v1';
import { sendMeetings } from './wire';

const QUICK_CALL = 'Quick call';
const LENGTH = 30 * 60_000;

/**
 * Where a meeting's call is held: its room. Joining puts the person in the room, as the invite list would; a meeting they
 * cannot see is as good as missing, and a cancelled one opens no call. With no meeting, a Quick Call: a meeting made now,
 * in a room of its own that the caller invites people to.
 */
export function callTarget({ hub }: AppContext, person: Person, meetingId: string | null) {
	const store = new Meetings(hub);
	if (meetingId === null) {
		const at = Date.now();
		if (store.countAhead(person.id, at) >= MAX_MEETINGS_AHEAD) throw new HttpError(429, 'too_many_meetings');
		const room = hub.conversations.createRoom({ title: QUICK_CALL, createdBy: person.id, memberIds: [person.id] });
		const meeting = store.schedule({
			title: QUICK_CALL,
			startsAt: at,
			endsAt: at + LENGTH,
			roomId: room.id,
			organizerId: person.id,
			attendeeIds: [],
			ownRoom: true,
		});
		sendMeetings(hub, [person.id]);
		return { meetingId: meeting.id, conversationId: room.id, title: meeting.title };
	}
	const meeting = store.get(meetingId);
	if (meeting === null || !store.canSee(meeting.id, person.id)) return null;
	if (meeting.status === 'cancelled') throw new HttpError(409, 'meeting_cancelled');
	const room = hub.conversations.get(meeting.room_id);
	if (room === null || room.archived_at !== null) return null;
	if (!hub.conversations.isMember(room.id, person.id)) {
		// A direct message stays between its two people.
		if (room.kind !== 'room') return null;
		hub.conversations.addMember(room.id, person.id);
		hub.bus.emit({ type: 'conversation.changed', conversationId: room.id, audience: hub.conversations.memberIds(room.id) });
	}
	return { meetingId: meeting.id, conversationId: room.id, title: meeting.title };
}

type CallRecapInput = Parameters<NonNullable<AppDefinition['callRecap']>>[1];

/**
 * A meeting's call, once its transcript is written down, is recapped like a transcript someone shared: the recap goes to the
 * meeting's room and its action items become tasks. Posting goes through the call, so a second recap of one call edits the
 * first message instead of posting again. A second recap files no tasks and keeps the action items the first one filed:
 * a reworded item is the same work.
 */
export async function callRecap(app: AppContext, input: CallRecapInput): Promise<string | null> {
	const store = new Meetings(app.hub);
	const meeting = store.get(input.meetingId);
	if (meeting === null) return null;
	const tools = input.again
		? { has: (name: string) => name !== 'add_task' && app.tools.has(name), call: app.tools.call.bind(app.tools) }
		: app.tools;
	const result = await recapMeeting(
		{ ...app, tools, assistant: { ...app.assistant, post: input.post } },
		meeting,
		input.transcript,
	);
	if (input.again && meeting.action_items !== null) {
		const kept = store.saveRecap(result.meeting, {
			transcript: input.transcript,
			summary: result.meeting.summary ?? '',
			actionItems: JSON.parse(meeting.action_items) as ActionItem[],
		});
		return kept.summary;
	}
	return result.meeting.summary;
}
