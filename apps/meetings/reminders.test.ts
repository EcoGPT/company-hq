import { describe, expect, test } from 'bun:test';
import meetings from './app';
import { admin, createHq } from '@hq/sdk/testing';

const MINUTE = 60_000;

describe('meeting reminders', () => {
	test('pings the room once, shortly before the start', async () => {
		const hq = createHq({ apps: [meetings] });
		admin(hq);
		hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const ctx = { hub: hq.hub, caller: hq.assistant.self, conversationId: hq.hub.general().id };
		const at = (minutes: number) => new Date(Date.now() + minutes * MINUTE).toISOString();
		await hq.registry.call(
			'schedule_meeting',
			{ title: 'Standup', starts_at: at(10), attendee_handles: ['bo'], organizer_handle: 'ada' },
			ctx,
		);
		await hq.registry.call('schedule_meeting', { title: 'Later', starts_at: at(90) }, ctx);
		const cancelled = await hq.registry.call('schedule_meeting', { title: 'Cancelled', starts_at: at(5) }, ctx);
		await hq.registry.call('update_meeting', { id: (cancelled as { value: { id: string } }).value.id, status: 'cancelled' }, ctx);

		const run = await hq.scheduler.run('meetings', 'reminders');
		expect(run.output).toBe('reminded 1');
		const last = hq.hub.messages.list(hq.hub.general().id).at(-1)!;
		expect(last.body).toMatch(/^Starting in 10 min \(\d\d:\d\d UTC\): \*\*Standup\*\* with @ada, @bo\.$/);
		expect(last.metadata).toMatchObject({ app: 'meetings', reminder: true });

		expect((await hq.scheduler.run('meetings', 'reminders')).output).toBe('nothing starting soon');
	});

	test('rescheduling re-arms the reminder', async () => {
		const hq = createHq({ apps: [meetings] });
		const ctx = { hub: hq.hub, caller: hq.assistant.self, conversationId: hq.hub.general().id };
		const made = await hq.registry.call(
			'schedule_meeting',
			{ title: 'Sync', starts_at: new Date(Date.now() + 5 * MINUTE).toISOString() },
			ctx,
		);
		const id = (made as { value: { id: string } }).value.id;
		await hq.scheduler.run('meetings', 'reminders');
		await hq.registry.call('update_meeting', { id, starts_at: new Date(Date.now() + 12 * MINUTE).toISOString() }, ctx);
		expect((await hq.scheduler.run('meetings', 'reminders')).output).toBe('reminded 1');
	});
});
