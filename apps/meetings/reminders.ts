import { defineAutomation } from '@hq/sdk';
import { Meetings } from './store';
import { affected, sendMeetings } from './wire';

const LEAD_MS = 15 * 60_000;

export default defineAutomation({
	slug: 'reminders',
	name: 'Meeting reminders',
	description: 'Pings each meeting room up to 15 minutes before the meeting starts.',
	schedule: '*/5 * * * *',
	run({ hub, assistant, log }) {
		const store = new Meetings(hub);
		const at = Date.now();
		// A repeating meeting whose next occurrence has passed gets the one after it.
		const added = store.advanceAll(at);
		if (added.length > 0) sendMeetings(hub, affected(hub, added));
		const due = store.dueForReminder(at, LEAD_MS);
		for (const meeting of due) {
			const humans = store.participants(meeting).filter((p) => p.kind === 'human');
			const minutes = Math.max(1, Math.round((meeting.starts_at - at) / 60_000));
			const time = new Date(meeting.starts_at).toISOString().slice(11, 16);
			const who = humans.length > 0 ? ` with ${humans.map((p) => `@${p.handle}`).join(', ')}` : '';
			assistant.post(meeting.room_id, `Starting in ${minutes} min (${time} UTC): **${meeting.title}**${who}.`, {
				app: 'meetings',
				meeting: meeting.id,
				reminder: true,
			});
			store.update(meeting, { reminded_at: at });
			log(`reminded ${meeting.title}`);
		}
		return due.length === 0 ? 'nothing starting soon' : `reminded ${due.length}`;
	},
});
