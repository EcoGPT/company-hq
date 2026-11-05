import type { Hub } from '@hq/sdk';
import { describe } from './recurrence';
import { Meetings, ruleOf, type Meeting } from './store';

/** The meeting as the app decodes it. The organizer is on the invite list, as the app expects. */
export function presentWire(hub: Hub, meetings: Meeting[]) {
	const store = new Meetings(hub);
	const attendees = store.attendeesOf(meetings.map((m) => m.id));
	const series = new Map(
		meetings.flatMap((m) => (m.series_id === null ? [] : [[m.series_id, store.series(m.series_id)] as const])),
	);
	return meetings.map((meeting) => {
		const row = series.get(meeting.series_id ?? '');
		return {
			id: meeting.id,
			title: meeting.title,
			scheduled_at: new Date(meeting.starts_at).toISOString(),
			created_by_person_id: meeting.organizer_id,
			created_at: new Date(meeting.created_at).toISOString(),
			conversation_id: meeting.room_id,
			invitee_person_ids: [...new Set([meeting.organizer_id, ...(attendees.get(meeting.id) ?? [])])],
			recurrence: row == null ? null : describe(ruleOf(row), row.anchor_at),
			series_id: meeting.series_id,
		};
	});
}

/** What `person` sees of meetings: their own, those they are invited to and those in rooms they are in. */
export function meetingsFor(hub: Hub, personId: string) {
	return presentWire(hub, new Meetings(hub).visibleTo(personId));
}

/** Tells each of these people, on their own sockets, their whole list again: the app replaces its list with a `meetings` frame. */
export function sendMeetings(hub: Hub, personIds: Iterable<string>): void {
	for (const id of new Set(personIds)) {
		const person = hub.people.get(id);
		if (person === null || person.kind !== 'human' || person.removed_at !== null) continue;
		hub.bus.emit({ type: 'frame', audience: [id], frame: { type: 'meetings', meetings: meetingsFor(hub, id) } });
	}
}

/** Everyone a change to these meetings can change the list of: who runs them, who is invited, and who is in the room. */
export function affected(hub: Hub, meetings: Meeting[], extra: string[] = []): string[] {
	const store = new Meetings(hub);
	const people = new Set(extra);
	for (const meeting of meetings) {
		people.add(meeting.organizer_id);
		for (const id of store.attendeeIds(meeting.id)) people.add(id);
		for (const id of hub.conversations.memberIds(meeting.room_id)) people.add(id);
	}
	return [...people];
}
