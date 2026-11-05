import { describe, expect, test } from 'bun:test';
import { defineAssistant, resolveDay } from '@hq/sdk';
import tasks from './app';
import { admin, client, createHq } from '@hq/sdk/testing';

describe('tasks app', () => {
	test('the assistant files, lists and completes tasks', async () => {
		const hq = createHq({ apps: [tasks] });
		const ada = admin(hq);
		const ctx = { hub: hq.hub, caller: hq.assistant.self, conversationId: hq.hub.general().id };
		const added = await hq.registry.call('add_task', { title: 'Ship v1', owner_handle: '@ada', due: '2026-11-01' }, ctx);
		expect(added).toMatchObject({ ok: true, value: { title: 'Ship v1', owner: '@ada', due: '2026-11-01', status: 'open' } });
		const id = (added as { value: { id: string } }).value.id;

		const mine = await hq.registry.call('list_tasks', { owner_handle: 'ada' }, ctx);
		expect(mine.ok && (mine.value as unknown[]).length).toBe(1);

		await hq.registry.call('update_task', { id, status: 'done' }, ctx);
		expect(await hq.registry.call('list_tasks', {}, ctx)).toEqual({ ok: true, value: [] });

		const as = client(hq, ada.key);
		expect((await as('GET', '/apps/tasks/api/tasks?status=done')).body.map((t: { title: string }) => t.title)).toEqual([
			'Ship v1',
		]);
	});

	test("lists show each task's owner", async () => {
		const hq = createHq({ apps: [tasks] });
		const ada = admin(hq);
		hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		for (const [title, owner_handle] of [
			['a', 'ada'],
			['b', 'bo'],
			['c', undefined],
			['d', 'ada'],
		]) {
			await hq.registry.call('add_task', { title, owner_handle }, ctx);
		}
		const listed = await hq.registry.call('list_tasks', {}, ctx);
		expect(listed.ok && (listed.value as { title: string; owner: string | null }[]).map((t) => [t.title, t.owner])).toEqual([
			['a', '@ada'],
			['b', '@bo'],
			['c', null],
			['d', '@ada'],
		]);
		const page = await client(hq, ada.key)('GET', '/apps/tasks/api/tasks');
		expect(page.body.map((t: { owner: string | null }) => t.owner)).toEqual(['@ada', '@bo', null, '@ada']);
	});

	test('the page adds tasks and checks them off', async () => {
		const hq = createHq({ apps: [tasks] });
		const as = client(hq, admin(hq).key);
		const task = await as('POST', '/apps/tasks/api/tasks', { title: 'Write docs' });
		expect((await as('PATCH', `/apps/tasks/api/tasks/${task.body.id}`, { status: 'done' })).body.status).toBe('done');
		expect((await as('PATCH', '/apps/tasks/api/tasks/nope', { status: 'done' })).status).toBe(404);
	});

	test('the page gets a 400, not a 500, for an unknown owner', async () => {
		const hq = createHq({ apps: [tasks] });
		const as = client(hq, admin(hq).key);
		expect(await as('POST', '/apps/tasks/api/tasks', { title: 'x', owner_handle: 'ghost' })).toEqual({
			status: 400,
			body: { error: 'nobody has the handle ghost' },
		});
	});

	test('an unknown owner is a tool error', async () => {
		const hq = createHq({ apps: [tasks] });
		const result = await hq.registry.call(
			'add_task',
			{ title: 'x', owner_handle: 'ghost' },
			{ hub: hq.hub, caller: hq.assistant.self },
		);
		expect(result).toEqual({ ok: false, error: 'nobody has the handle ghost' });
	});
});

describe('live refresh', () => {
	test('tasks the assistant files or updates tell open pages to refresh', async () => {
		const hq = createHq({ apps: [tasks] });
		const events: string[] = [];
		hq.hub.bus.on((e) => e.type === 'app.event' && e.app === 'tasks' && events.push(e.name));
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		const added = await hq.registry.call('add_task', { title: 'Ship it' }, ctx);
		await hq.registry.call('update_task', { id: (added as { value: { id: string } }).value.id, status: 'done' }, ctx);
		await hq.registry.call('list_tasks', {}, ctx);
		expect(events).toEqual(['changed', 'changed']);
	});
});

describe('visibility', () => {
	test('tasks filed in a private room stay in that room, except for their owner', async () => {
		const hq = createHq({ apps: [tasks] });
		const ada = admin(hq);
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const secret = hq.hub.conversations.createRoom({ title: 'Comp', createdBy: ada.person.id });
		const inRoom = { hub: hq.hub, caller: hq.assistant.self, conversationId: secret.id, viewers: [ada.person.id] };
		const filed = await hq.registry.call('add_task', { title: 'Raise for Cy', owner_handle: 'bo' }, inRoom);
		await hq.registry.call('add_task', { title: 'Team lunch' }, { hub: hq.hub, caller: hq.assistant.self });
		const id = (filed as { value: { id: string } }).value.id;

		const titles = async (viewer: { id: string }) => {
			const r = await hq.registry.call('list_tasks', {}, { hub: hq.hub, caller: hq.assistant.self, viewers: [viewer.id] });
			return (r as { value: { title: string }[] }).value.map((t) => t.title);
		};
		expect(await titles(ada.person)).toEqual(['Raise for Cy', 'Team lunch']);
		expect(await titles(bo)).toEqual(['Raise for Cy', 'Team lunch']);
		expect(await titles(cy)).toEqual(['Team lunch']);
		expect(
			(
				await hq.registry.call(
					'update_task',
					{ id, status: 'done' },
					{ hub: hq.hub, caller: hq.assistant.self, viewers: [cy.id] },
				)
			).ok,
		).toBe(false);

		const asCy = client(hq, hq.hub.keys.mint(cy.id).secret);
		expect((await asCy('GET', '/apps/tasks/api/tasks?status=all')).body.map((t: { title: string }) => t.title)).toEqual([
			'Team lunch',
		]);
		expect((await asCy('PATCH', `/apps/tasks/api/tasks/${id}`, { status: 'done' })).status).toBe(404);
	});
});

describe('due dates', () => {
	test("relative days resolve in the assistant's time zone, not HQ_TIMEZONE", async () => {
		const prior = process.env.HQ_TIMEZONE;
		process.env.HQ_TIMEZONE = 'Etc/GMT+12';
		try {
			const hq = createHq({
				apps: [tasks],
				assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', timezone: 'Pacific/Kiritimati' }),
			});
			const ctx = { hub: hq.hub, caller: hq.assistant.self };
			const added = await hq.registry.call('add_task', { title: 'Ship', due: 'tomorrow' }, ctx);
			expect(added).toMatchObject({ ok: true, value: { due: resolveDay('tomorrow', 'Pacific/Kiritimati') } });
		} finally {
			if (prior === undefined) delete process.env.HQ_TIMEZONE;
			else process.env.HQ_TIMEZONE = prior;
		}
	});
	test('a task filed in an archived room is hidden from everyone but its owner', async () => {
		const hq = createHq({ apps: [tasks] });
		const ada = admin(hq);
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const boKey = hq.hub.keys.mint(bo.id).secret;
		const room = hq.hub.conversations.createRoom({ title: 'Launch', createdBy: ada.person.id, memberIds: [bo.id] });
		const ctx = { hub: hq.hub, caller: hq.assistant.self, conversationId: room.id, viewers: [ada.person.id, bo.id] };
		const added = await hq.registry.call('add_task', { title: 'Ship v1', owner_handle: 'ada' }, ctx);
		const id = (added as { value: { id: string } }).value.id;
		hq.hub.conversations.archive(room.id);
		const asBo = client(hq, boKey);
		expect((await asBo('GET', '/apps/tasks/api/tasks')).body).toEqual([]);
		expect((await asBo('PATCH', `/apps/tasks/api/tasks/${id}`, { status: 'done' })).status).toBe(404);
		const asAda = client(hq, ada.key);
		expect((await asAda('GET', '/apps/tasks/api/tasks')).body.map((t: { title: string }) => t.title)).toEqual(['Ship v1']);
	});
});
