import { describe, expect, test } from 'bun:test';
import reminders from './app';
import { parseWhen, Reminders } from './store';
import { admin, client, createHq } from '@hq/sdk/testing';

function setup() {
	const hq = createHq({ apps: [reminders] });
	const ada = admin(hq);
	const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
	const room = hq.hub.conversations.createRoom({ title: 'Ops', createdBy: ada.person.id, memberIds: [bo.id] });
	hq.hub.messages.send({
		conversationId: room.id,
		authorId: ada.person.id,
		body: '@assistant remind me in 2h to check the deploy',
	});
	const ctx = { hub: hq.hub, caller: hq.assistant.self, conversationId: room.id };
	return { hq, ada, bo, room, ctx };
}

const backdate = (hq: ReturnType<typeof createHq>) =>
	hq.hub.db.query('UPDATE reminders SET due_at = $at').run({ at: Date.now() - 1000 });

describe('reminders app', () => {
	test('parseWhen reads relative times and ISO times with an offset only', () => {
		const at = Date.parse('2026-10-18T12:00:00Z');
		expect(parseWhen('in 2h', at)).toBe(at + 2 * 3_600_000);
		expect(parseWhen('30 minutes', at)).toBe(at + 30 * 60_000);
		expect(parseWhen('in 1.5 days', at)).toBe(at + 36 * 3_600_000);
		expect(parseWhen('2026-10-19T09:00:00-04:00', at)).toBe(Date.parse('2026-10-19T13:00:00Z'));
		expect(parseWhen('2026-10-19T09:00', at)).toBeNull();
		expect(parseWhen('tomorrow 9am', at)).toBeNull();
	});

	test('"remind me" goes to whoever asked, as a DM from the assistant', async () => {
		const { hq, ada, ctx } = setup();
		const set = await hq.registry.call('set_reminder', { text: 'check the deploy', when: 'in 2h' }, ctx);
		expect(set).toMatchObject({ ok: true, value: { for: '@ada', text: 'check the deploy', where: 'DM' } });

		expect((await hq.scheduler.run('reminders', 'deliver')).output).toBeNull();
		backdate(hq);
		expect((await hq.scheduler.run('reminders', 'deliver')).output).toBe('delivered 1');
		const dm = hq.hub.conversations.dm(hq.assistant.self.id, ada.person.id);
		expect(hq.hub.messages.list(dm.id).map((m) => m.body)).toEqual(['⏰ Reminder: check the deploy']);
		expect((await hq.scheduler.run('reminders', 'deliver')).output).toBeNull();
	});

	test('reminding someone else, in the room, credits who asked', async () => {
		const { hq, room, ctx } = setup();
		await hq.assistant.runner.idle();
		await hq.registry.call('set_reminder', { text: 'send the invoice', when: 'in 1d', for_handle: '@bo', in_room: true }, ctx);
		backdate(hq);
		await hq.scheduler.run('reminders', 'deliver');
		expect(hq.hub.messages.list(room.id).at(-1)?.body).toBe('⏰ @bo reminder: send the invoice — from Ada');
	});

	test('unreadable or past times and unknown people are refused, and a reminder cancels once', async () => {
		const { hq, ada, ctx } = setup();
		expect(await hq.registry.call('set_reminder', { text: 'x', when: 'someday' }, ctx)).toMatchObject({
			ok: false,
			error: expect.stringContaining('could not read'),
		});
		expect(await hq.registry.call('set_reminder', { text: 'x', when: '2020-01-01T00:00:00Z' }, ctx)).toMatchObject({
			ok: false,
			error: expect.stringContaining('in the past'),
		});
		expect(await hq.registry.call('set_reminder', { text: 'x', when: 'in 2h', for_handle: 'ghost' }, ctx)).toEqual({
			ok: false,
			error: 'nobody has the handle ghost',
		});

		const set = await hq.registry.call('set_reminder', { text: 'standup notes', when: 'in 1h' }, ctx);
		const id = (set as { value: { id: string } }).value.id;
		expect(
			(await hq.registry.call('list_reminders', { for_handle: 'ada' }, ctx)).ok && new Reminders(hq.hub).pending().length,
		).toBe(1);
		expect((await client(hq, ada.key)('GET', '/apps/reminders/api/reminders')).body[0].text).toBe('standup notes');
		expect(await hq.registry.call('cancel_reminder', { id }, ctx)).toEqual({ ok: true, value: { cancelled: id } });
		expect((await client(hq, ada.key)('DELETE', `/apps/reminders/api/reminders/${id}`)).status).toBe(404);
		backdate(hq);
		expect((await hq.scheduler.run('reminders', 'deliver')).output).toBeNull();
	});

	test('setting, cancelling and delivering tell open pages to refresh', async () => {
		const { hq, ctx } = setup();
		const events: string[] = [];
		hq.hub.bus.on((e) => e.type === 'app.event' && e.app === 'reminders' && events.push(e.name));
		const first = await hq.registry.call('set_reminder', { text: 'a', when: 'in 1h' }, ctx);
		await hq.registry.call('cancel_reminder', { id: (first as { value: { id: string } }).value.id }, ctx);
		await hq.registry.call('set_reminder', { text: 'b', when: 'in 1h' }, ctx);
		await hq.registry.call('list_reminders', {}, ctx);
		backdate(hq);
		await hq.scheduler.run('reminders', 'deliver');
		expect(events).toEqual(['changed', 'changed', 'changed', 'changed']);
	});

	test('private reminders stay with the people they are for', async () => {
		const { hq, ada, bo } = setup();
		const adaDm = hq.hub.conversations.dm(ada.person.id, hq.assistant.self.id);
		const asAda = { hub: hq.hub, caller: hq.assistant.self, conversationId: adaDm.id, viewers: [ada.person.id] };
		const set = await hq.registry.call(
			'set_reminder',
			{ text: 'call the lawyer about Bo', when: 'in 1h', for_handle: 'ada' },
			asAda,
		);
		const id = (set as { value: { id: string } }).value.id;
		const boDm = hq.hub.conversations.dm(bo.id, hq.assistant.self.id);
		const asBo = { hub: hq.hub, caller: hq.assistant.self, conversationId: boDm.id, viewers: [bo.id] };
		expect(await hq.registry.call('list_reminders', {}, asBo)).toEqual({ ok: true, value: [] });
		expect(await hq.registry.call('cancel_reminder', { id }, asBo)).toMatchObject({ ok: false });
		const boKey = hq.hub.keys.mint(bo.id).secret;
		expect((await client(hq, boKey)('GET', '/apps/reminders/api/reminders')).body).toEqual([]);
		expect((await client(hq, boKey)('DELETE', `/apps/reminders/api/reminders/${id}`)).status).toBe(404);
		const mine = await hq.registry.call('list_reminders', {}, asAda);
		expect((mine as { value: { text: string }[] }).value.map((r) => r.text)).toEqual(['call the lawyer about Bo']);
	});
	test('a room reminder in an archived room is hidden from the rest of the room', async () => {
		const { hq, ada, room, ctx } = setup();
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		hq.hub.conversations.addMember(room.id, cy.id);
		const cyKey = hq.hub.keys.mint(cy.id).secret;
		await hq.registry.call('set_reminder', { text: 'check the deploy', when: 'in 2h', in_room: true }, ctx);
		const asCy = client(hq, cyKey);
		expect((await asCy('GET', '/apps/reminders/api/reminders')).body).toHaveLength(1);
		hq.hub.conversations.archive(room.id);
		expect((await asCy('GET', '/apps/reminders/api/reminders')).body).toEqual([]);
		const asAda = client(hq, ada.key);
		expect((await asAda('GET', '/apps/reminders/api/reminders')).body).toHaveLength(1);
	});
});
