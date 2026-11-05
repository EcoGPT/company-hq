import { describe, expect, setSystemTime, test } from 'bun:test';
import meetings from './app';
import { admin, client, createHq, scripted, type MockStep } from '@hq/sdk/testing';
import { Meetings } from './store';

const HOUR = 3_600_000;

function setup() {
	const hq = createHq({ apps: [meetings] });
	const ada = admin(hq);
	const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
	const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
	const ctx = { hub: hq.hub, caller: hq.assistant.self, conversationId: hq.hub.general().id };
	return { hq, ada, bo, cy, ctx };
}

const inHours = (n: number) => new Date(Date.now() + n * HOUR).toISOString();

describe('meetings app', () => {
	test('the assistant schedules, lists and reschedules', async () => {
		const { hq, ctx, bo } = setup();
		const scheduled = await hq.registry.call(
			'schedule_meeting',
			{ title: 'Launch sync', starts_at: inHours(2), attendee_handles: ['@bo', 'cy'], organizer_handle: 'ada' },
			ctx,
		);
		expect(scheduled).toMatchObject({
			ok: true,
			value: {
				title: 'Launch sync',
				organizer: '@ada',
				attendees: ['@bo', '@cy'],
				status: 'scheduled',
				room: { title: 'General' },
			},
		});
		const meeting = (scheduled as { value: { id: string; starts_at: string; ends_at: string } }).value;
		expect(Date.parse(meeting.ends_at) - Date.parse(meeting.starts_at)).toBe(30 * 60_000);

		await hq.registry.call('schedule_meeting', { title: 'Old retro', starts_at: inHours(-3) }, ctx);
		const upcoming = await hq.registry.call('list_meetings', { attendee_handle: 'bo' }, ctx);
		expect(upcoming.ok && (upcoming.value as { title: string }[]).map((m) => m.title)).toEqual(['Launch sync']);
		const past = await hq.registry.call('list_meetings', { when: 'past' }, ctx);
		expect(past.ok && (past.value as { title: string }[]).map((m) => m.title)).toEqual(['Old retro']);

		const moved = await hq.registry.call('update_meeting', { id: meeting.id, starts_at: inHours(5), duration_minutes: 60 }, ctx);
		expect(
			moved.ok &&
				Date.parse((moved.value as { ends_at: string }).ends_at) - Date.parse((moved.value as { starts_at: string }).starts_at),
		).toBe(HOUR);
		await hq.registry.call('update_meeting', { id: meeting.id, status: 'cancelled' }, ctx);
		expect(await hq.registry.call('list_meetings', { attendee_handle: 'bo' }, ctx)).toEqual({ ok: true, value: [] });
		expect(hq.hub.conversations.isMember(hq.hub.general().id, bo.id)).toBe(true);
	});

	test('from a DM it opens a room for the meeting', async () => {
		const { hq, ada, bo } = setup();
		const dm = hq.hub.conversations.dm(ada.person.id, hq.assistant.self.id);
		const result = await hq.registry.call(
			'schedule_meeting',
			{ title: '1:1', starts_at: inHours(1), attendee_handles: ['bo'], organizer_handle: 'ada' },
			{ hub: hq.hub, caller: hq.assistant.self, conversationId: dm.id },
		);
		const room = (result as { value: { room: { id: string; title: string } } }).value.room;
		expect(room.title).toBe('1:1');
		expect(hq.hub.conversations.isMember(room.id, bo.id)).toBe(true);
		expect(hq.hub.conversations.isMember(room.id, ada.person.id)).toBe(true);
	});

	test('scheduling into a room needs everyone asking to be in it', async () => {
		const { hq, ada, bo } = setup();
		const secret = hq.hub.conversations.createRoom({ title: 'Comp', createdBy: ada.person.id });
		const dm = hq.hub.conversations.dm(bo.id, hq.assistant.self.id);
		const fromDm = await hq.registry.call(
			'schedule_meeting',
			{ title: 'Sneak', starts_at: inHours(1), room_id: secret.id, organizer_handle: 'bo' },
			{ hub: hq.hub, caller: hq.assistant.self, conversationId: dm.id, viewers: [bo.id] },
		);
		expect(fromDm).toMatchObject({ ok: false, error: expect.stringContaining('that you are in') });
		const boKey = hq.hub.keys.mint(bo.id).secret;
		const overRest = await client(hq, boKey)('POST', '/apps/meetings/api/meetings', {
			title: 'Sneak',
			starts_at: inHours(1),
			room_id: secret.id,
		});
		expect(overRest.status).toBe(400);
		expect(hq.hub.conversations.isMember(secret.id, bo.id)).toBe(false);
		const own = await client(hq, ada.key)('POST', '/apps/meetings/api/meetings', {
			title: 'Comp sync',
			starts_at: inHours(1),
			room_id: secret.id,
		});
		expect(own.status).toBe(200);
	});

	test('through the assistant, only people in the meeting can change it', async () => {
		const { hq, ada, bo } = setup();
		const made = await client(hq, ada.key)('POST', '/apps/meetings/api/meetings', {
			title: 'Comp review',
			starts_at: inHours(1),
		});
		const id = made.body.id as string;
		const room = made.body.room.id as string;
		const turn = (person: string) => ({
			hub: hq.hub,
			caller: hq.assistant.self,
			conversationId: hq.hub.conversations.dm(person, hq.assistant.self.id).id,
			viewers: [person],
		});
		const sneak = await hq.registry.call('update_meeting', { id, add_attendee_handles: ['bo'] }, turn(bo.id));
		expect(sneak).toMatchObject({ ok: false, error: expect.stringContaining('only the organizer') });
		expect(hq.hub.conversations.isMember(room, bo.id)).toBe(false);
		expect(await hq.registry.call('recap_meeting', { id, transcript: 'nothing happened' }, turn(bo.id))).toMatchObject({
			ok: false,
		});
		const own = await hq.registry.call('update_meeting', { id, status: 'cancelled' }, turn(ada.person.id));
		expect(own).toMatchObject({ ok: true, value: { status: 'cancelled' } });
	});

	test('in a shared room, the assistant changes a meeting only for someone in it who asked', async () => {
		let id = '';
		const cancel: MockStep = () => ({ toolCalls: [{ id: 'c', name: 'update_meeting', arguments: { id, status: 'cancelled' } }] });
		const hq = createHq({ apps: [meetings], provider: scripted([cancel, { content: 'ok' }, cancel, { content: 'ok' }]) });
		const ada = admin(hq);
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const general = hq.hub.general();
		for (const person of [bo, cy]) hq.hub.conversations.addMember(general.id, person.id);
		const made = await client(hq, ada.key)('POST', '/apps/meetings/api/meetings', {
			title: 'Board prep',
			starts_at: inHours(1),
			room_id: general.id,
			attendee_handles: ['bo'],
		});
		id = made.body.id as string;
		const status = () => new Meetings(hq.hub).get(id)!.status;
		const ask = async (authorId: string) => {
			hq.hub.messages.send({ conversationId: general.id, authorId, body: `@${hq.assistant.self.handle} cancel board prep` });
			await hq.assistant.runner.idle();
		};
		await ask(cy.id);
		expect(status()).toBe('scheduled');
		await ask(bo.id);
		expect(status()).toBe('cancelled');
	});

	test('an attendee outside a DM-hosted meeting cannot post into that DM', async () => {
		const { hq, ada, bo, cy } = setup();
		const dm = hq.hub.conversations.dm(ada.person.id, bo.id);
		const made = await client(hq, ada.key)('POST', '/apps/meetings/api/meetings', {
			title: '1:1',
			starts_at: inHours(1),
			room_id: dm.id,
			attendee_handles: ['cy'],
		});
		expect(made.status).toBe(200);
		const asCy = client(hq, hq.hub.keys.mint(cy.id).secret);
		expect((await asCy('GET', `/apps/meetings/api/meetings/${made.body.id}`)).status).toBe(404);
		const posted = await asCy('POST', `/apps/meetings/api/meetings/${made.body.id}/transcript`, { transcript: 'from cy' });
		expect(posted.status).toBe(403);
		expect(hq.hub.messages.list(dm.id)).toEqual([]);
		const viaTool = await hq.registry.call(
			'update_meeting',
			{ id: made.body.id, status: 'cancelled' },
			{ hub: hq.hub, caller: cy },
		);
		expect(viaTool).toMatchObject({ ok: false });
	});

	test('meetings in rooms you are not in stay hidden', async () => {
		const { hq, ada, bo } = setup();
		const made = await client(hq, ada.key)('POST', '/apps/meetings/api/meetings', {
			title: 'Comp review',
			starts_at: inHours(1),
			agenda: 'Raises',
		});
		const asBo = client(hq, hq.hub.keys.mint(bo.id).secret);
		expect((await asBo('GET', '/apps/meetings/api/meetings?when=all')).body).toEqual([]);
		expect((await asBo('GET', `/apps/meetings/api/meetings/${made.body.id}`)).status).toBe(404);
		const dm = hq.hub.conversations.dm(bo.id, hq.assistant.self.id);
		const listed = await hq.registry.call(
			'list_meetings',
			{ when: 'all' },
			{ hub: hq.hub, caller: hq.assistant.self, conversationId: dm.id, viewers: [bo.id] },
		);
		expect(listed).toEqual({ ok: true, value: [] });
		const adas = await hq.registry.call('list_meetings', { when: 'all' }, { hub: hq.hub, caller: ada.person });
		expect(adas.ok && (adas.value as { title: string }[]).map((m) => m.title)).toEqual(['Comp review']);
	});

	test('bad times, unknown handles and outsiders are tool errors', async () => {
		const { hq, ctx, cy } = setup();
		expect(await hq.registry.call('schedule_meeting', { title: 'x', starts_at: 'next tuesday' }, ctx)).toMatchObject({
			ok: false,
			error: expect.stringContaining('ISO 8601'),
		});
		expect(await hq.registry.call('schedule_meeting', { title: 'x', starts_at: '2030-01-02T15:00:00' }, ctx)).toMatchObject({
			ok: false,
			error: expect.stringContaining('ISO 8601'),
		});
		for (const starts_at of ['2026-02-30T10:00:00Z', '2026-04-31T09:00:00-04:00', '2026-05-01T24:00Z', '2026-05-01T09:60Z']) {
			expect(await hq.registry.call('schedule_meeting', { title: 'x', starts_at }, ctx)).toMatchObject({ ok: false });
		}
		expect(
			await hq.registry.call('schedule_meeting', { title: 'x', starts_at: inHours(1), attendee_handles: ['ghost'] }, ctx),
		).toEqual({
			ok: false,
			error: 'nobody has the handle ghost',
		});
		const made = await hq.registry.call(
			'schedule_meeting',
			{ title: 'Private', starts_at: inHours(1), organizer_handle: 'bo' },
			ctx,
		);
		const id = (made as { value: { id: string } }).value.id;
		expect(
			await hq.registry.call('update_meeting', { id, title: 'Mine now' }, { hub: hq.hub, caller: cy }, 'everyone'),
		).toMatchObject({
			ok: false,
			error: expect.stringContaining('only the organizer'),
		});
	});

	test('the page API schedules and each person gets an ICS feed', async () => {
		const { hq, ada } = setup();
		const as = client(hq, ada.key);
		const created = await as('POST', '/apps/meetings/api/meetings', {
			title: 'Design review, part 2',
			starts_at: '2030-01-02T15:00:00Z',
			duration_minutes: 45,
			attendee_handles: ['bo'],
			agenda: 'Mockups; open questions',
		});
		expect(created.status).toBe(200);
		expect((await as('GET', '/apps/meetings/api/meetings')).body.map((m: { title: string }) => m.title)).toEqual([
			'Design review, part 2',
		]);
		expect((await as('POST', '/apps/meetings/api/meetings', { title: 'x', starts_at: 'soon' })).status).toBe(400);

		const feed = await hq.fetch(
			new Request('http://hq.test/apps/meetings/api/calendar/bo.ics', { headers: { authorization: `Bearer ${ada.key}` } }),
		);
		expect(feed?.headers.get('content-type')).toBe('text/calendar; charset=utf-8');
		const text = await feed!.text();
		expect(text).toContain('BEGIN:VCALENDAR\r\n');
		expect(text).toContain(`UID:${created.body.id}@hq\r\n`);
		expect(text).toContain('DTSTART:20300102T150000Z\r\nDTEND:20300102T154500Z\r\n');
		expect(text).toContain('SUMMARY:Design review\\, part 2\r\n');
		expect(text).toContain('Mockups\\; open questions');
		expect(text).toContain(`URL:http://hq.test/#/c/${created.body.room.id}`);
		const { path } = (await as('POST', '/apps/meetings/api/feed')).body;
		expect(path).toMatch(/^\/apps\/meetings\/api\/feed\/cal_[\w-]+\.ics$/);
		const mine = await (await hq.fetch(new Request(`http://hq.test${path}`)))!.text();
		expect(mine).toContain('Design review');
		const { path: rotated } = (await as('POST', '/apps/meetings/api/feed')).body;
		expect((await hq.fetch(new Request(`http://hq.test${path}`)))?.status).toBe(404);
		expect((await hq.fetch(new Request(`http://hq.test${rotated}`)))?.status).toBe(200);
		expect((await hq.fetch(new Request(`http://hq.test/apps/meetings/api/calendar/bo.ics?token=${ada.key}`)))?.status).toBe(401);
	});

	test('a feed link survives a key rollover but not revoking every key, even after a new key', async () => {
		const { hq, ada } = setup();
		await client(hq, ada.key)('POST', '/apps/meetings/api/meetings', { title: 'Comp review', starts_at: inHours(1) });
		const { path } = (await client(hq, ada.key)('POST', '/apps/meetings/api/feed')).body;
		const feed = async (p: string) => (await hq.fetch(new Request(`http://hq.test${p}`)))!.status;
		await Bun.sleep(2);
		const laptop = hq.hub.keys.mint(ada.person.id, 'key', { label: 'laptop' });
		await Bun.sleep(2);
		hq.hub.keys.revoke(hq.hub.keys.list(ada.person.id).find((k) => k.id !== laptop.key.id)!.id);
		expect(await feed(path)).toBe(200);
		hq.hub.keys.revokeAll(ada.person.id);
		expect(await feed(path)).toBe(404);
		await Bun.sleep(2);
		const fresh = hq.hub.keys.mint(ada.person.id, 'key', { label: 'new laptop' }).secret;
		expect(await feed(path)).toBe(404);
		const { path: rotated } = (await client(hq, fresh)('POST', '/apps/meetings/api/feed')).body;
		expect(await feed(rotated)).toBe(200);
	});

	test('a feed link survives a key rollover done within one millisecond', async () => {
		const { hq, ada } = setup();
		const { path } = (await client(hq, ada.key)('POST', '/apps/meetings/api/feed')).body;
		setSystemTime(new Date(Date.now() + HOUR));
		try {
			const fresh = (await client(hq, ada.key)('POST', '/v1/mcp-keys', { label: 'laptop', scopes: ['read', 'send'] })).body;
			const old = hq.hub.keys.list(ada.person.id).find((k) => k.id !== fresh.id)!;
			hq.hub.keys.revoke(old.id);
			expect((await hq.fetch(new Request(`http://hq.test${path}`)))!.status).toBe(200);
		} finally {
			setSystemTime();
		}
	});

	test('calendar feeds link to HQ_PUBLIC_URL when it is set', async () => {
		const hq = createHq({ apps: [meetings], publicUrl: 'https://hq.example.test/' });
		const ada = admin(hq);
		const as = client(hq, ada.key);
		const created = await as('POST', '/apps/meetings/api/meetings', { title: 'Comp review', starts_at: inHours(1) });
		const { path, url } = (await as('POST', '/apps/meetings/api/feed')).body;
		expect(url).toBe(`https://hq.example.test${path}`);
		const feed = await (await hq.fetch(new Request(`http://127.0.0.1:8787${path}`)))!.text();
		expect(feed).toContain(`URL:https://hq.example.test/#/c/${created.body.room.id}\r\n`);
		expect(feed).not.toContain('127.0.0.1');
	});

	test('calendar feeds only show meetings in rooms the reader is in', async () => {
		const { hq, ada } = setup();
		const as = client(hq, ada.key);
		await as('POST', '/apps/meetings/api/meetings', { title: 'Comp review', starts_at: '2030-01-03T15:00:00Z' });
		const boKey = hq.hub.keys.mint(hq.hub.people.byHandle('bo')!.id).secret;
		const feed = await hq.fetch(
			new Request('http://hq.test/apps/meetings/api/calendar/ada.ics', { headers: { authorization: `Bearer ${boKey}` } }),
		);
		expect(await feed!.text()).not.toContain('Comp review');
	});

	test("a calendar link dies with its owner's last key", async () => {
		const { hq, ada } = setup();
		const as = client(hq, ada.key);
		const { path } = (await as('POST', '/apps/meetings/api/feed')).body;
		expect((await hq.fetch(new Request(`http://hq.test${path}`)))?.status).toBe(200);
		for (const key of hq.hub.keys.list(ada.person.id)) hq.hub.keys.revoke(key.id);
		expect((await hq.fetch(new Request(`http://hq.test${path}`)))?.status).toBe(404);
	});

	test('scheduling and updating through the assistant tell open pages to refresh', async () => {
		const { hq, ctx } = setup();
		const events: string[] = [];
		hq.hub.bus.on((e) => e.type === 'app.event' && e.app === 'meetings' && events.push(e.name));
		const made = await hq.registry.call('schedule_meeting', { title: 'Sync', starts_at: inHours(1) }, ctx);
		await hq.registry.call('update_meeting', { id: (made as { value: { id: string } }).value.id, title: 'Weekly sync' }, ctx);
		await hq.registry.call('list_meetings', {}, ctx);
		expect(events).toEqual(['changed', 'changed']);
	});

	test('a meeting whose room is archived is hidden and locked, even from admins', async () => {
		const { hq, ada, bo, ctx } = setup();
		const room = hq.hub.conversations.createRoom({ title: 'Launch', createdBy: ada.person.id, memberIds: [bo.id] });
		const made = await hq.registry.call(
			'schedule_meeting',
			{ title: 'Launch sync', starts_at: inHours(2), attendee_handles: ['bo'], organizer_handle: 'ada', room_id: room.id },
			ctx,
		);
		const id = (made as { value: { id: string } }).value.id;
		hq.hub.conversations.archive(room.id);
		expect(await hq.registry.call('list_meetings', {}, ctx)).toEqual({ ok: true, value: [] });
		const asAda = client(hq, ada.key);
		expect((await asAda('GET', '/apps/meetings/api/meetings')).body).toEqual([]);
		expect((await asAda('GET', `/apps/meetings/api/meetings/${id}`)).status).toBe(404);
		expect((await asAda('POST', `/apps/meetings/api/meetings/${id}/transcript`, { transcript: 'notes' })).status).toBe(403);
		expect(await hq.registry.call('update_meeting', { id, title: 'Revived' }, ctx)).toMatchObject({ ok: false });
		expect(hq.hub.messages.list(room.id)).toEqual([]);
	});
});
