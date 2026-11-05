import { afterEach, describe, expect, setSystemTime, test } from 'bun:test';
import tasks from './app';
import { admin, client, createHq } from '@hq/sdk/testing';

type Out = { session_id: string; tasks: { id: string; title: string }[] };
type Row = {
	id: string;
	owner: { handle: string };
	title: string;
	intent: string;
	state: string;
	live: boolean;
	tasks: { id: string; title: string | null }[];
};

function team() {
	const hq = createHq({ apps: [tasks] });
	const ada = admin(hq);
	const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
	const as = (person: { id: string }) => ({ hub: hq.hub, caller: hq.hub.people.get(person.id)! });
	const call = async <T>(person: { id: string }, name: string, input: unknown): Promise<T> => {
		const result = await hq.registry.call(name, input, as(person));
		if (!result.ok) throw new Error(result.error);
		return result.value as T;
	};
	const sessions = async (person: { id: string }, minutes = 1440): Promise<Row[]> =>
		(await client(hq, hq.hub.keys.mint(person.id).secret)('GET', `/apps/tasks/api/sessions?since_minutes=${minutes}`)).body;
	return { hq, ada: ada.person, bo, as, call, sessions };
}

afterEach(() => setSystemTime());

describe('agent sessions', () => {
	test('start_session upserts by source id and check_session updates it', async () => {
		const { ada, call, sessions } = team();
		const first = await call<Out>(ada, 'start_session', {
			provider: 'Claude',
			source_id: 's1',
			title: 'Fix login',
			intent: 'reading',
		});
		const again = await call<Out>(ada, 'start_session', { provider: 'claude', source_id: 's1', intent: 'writing the fix' });
		expect(again.session_id).toBe(first.session_id);
		expect((await sessions(ada)).map((s) => [s.title, s.intent, s.state])).toEqual([['Fix login', 'writing the fix', 'active']]);

		await call(ada, 'check_session', { session_id: first.session_id, intent: 'testing', state: 'idle' });
		expect(await sessions(ada)).toMatchObject([{ title: 'Fix login', intent: 'testing', state: 'idle' }]);
		const other = await call<Out>(ada, 'start_session', { provider: 'codex', source_id: 's1', intent: '' });
		expect(other.session_id).not.toBe(first.session_id);
	});

	test("another key can't touch my session", async () => {
		const { hq, ada, bo, call } = team();
		const { session_id } = await call<Out>(ada, 'start_session', { provider: 'claude', source_id: 's1', intent: 'mine' });
		const rpc = async (name: string, args: unknown) => {
			const response = (await hq.fetch(
				new Request('http://hq.test/mcp', {
					method: 'POST',
					headers: { authorization: `Bearer ${hq.hub.keys.mint(bo.id).secret}` },
					body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
				}),
			)) as Response;
			return (await response.json()).result;
		};
		expect(await rpc('check_session', { session_id, state: 'ended' })).toMatchObject({ isError: true });
		expect(await rpc('link_session_tasks', { session_id, task_ids: [] })).toMatchObject({ isError: true });
		expect(await rpc('start_session', { provider: 'claude', source_id: 's1', intent: 'bo' })).toMatchObject({ isError: false });
		const listed = JSON.parse((await rpc('active_sessions', {})).content[0].text) as Row[];
		expect(listed.map((s) => [s.owner.handle, s.intent, s.state]).sort()).toEqual([
			['ada', 'mine', 'active'],
			['bo', 'bo', 'active'],
		]);
	});

	test('links respect task visibility, keep order and hide private titles from others', async () => {
		const { hq, ada, bo, call, sessions } = team();
		const room = hq.hub.conversations.createRoom({ title: 'Comp', createdBy: ada.id });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		const add = async (title: string, conversationId?: string) =>
			(
				(await hq.registry.call('add_task', { title }, { ...ctx, conversationId, viewers: [ada.id] })) as {
					value: { id: string };
				}
			).value.id;
		const secret = await add('Raise for Cy', room.id);
		const open = await add('Ship docs');

		const bos = await call<Out>(bo, 'start_session', {
			provider: 'claude',
			source_id: 'b',
			intent: '',
			task_ids: [secret, open, 'nope'],
		});
		expect(bos.tasks.map((t) => t.title)).toEqual(['Ship docs']);

		const adas = await call<Out>(ada, 'start_session', { provider: 'claude', source_id: 'a', intent: '', task_ids: [open] });
		const relinked = await call<Out>(ada, 'link_session_tasks', { session_id: adas.session_id, task_ids: [secret, open] });
		expect(relinked.tasks.map((t) => t.title)).toEqual(['Raise for Cy', 'Ship docs']);

		const byOwner = (rows: Row[]) => Object.fromEntries(rows.map((s) => [s.owner.handle, s.tasks.map((t) => t.title)]));
		expect(byOwner(await sessions(bo))).toEqual({ ada: [null, 'Ship docs'], bo: ['Ship docs'] });
		expect(byOwner(await sessions(ada))).toEqual({ ada: ['Raise for Cy', 'Ship docs'], bo: ['Ship docs'] });
	});

	test('new_task_title files a task owned by the caller and links it', async () => {
		const { hq, bo, call } = team();
		const out = await call<Out>(bo, 'start_session', {
			provider: 'cursor',
			source_id: 'x',
			intent: 'go',
			new_task_title: 'Speed up search',
		});
		expect(out.tasks.map((t) => t.title)).toEqual(['Speed up search']);
		const listed = await hq.registry.call('list_tasks', { owner_handle: 'bo' }, { hub: hq.hub, caller: hq.assistant.self });
		expect(listed).toMatchObject({ ok: true, value: [{ id: out.tasks[0]!.id, title: 'Speed up search', owner: '@bo' }] });
	});

	test('ended and stale sessions are not live; the window drops old ones', async () => {
		const { ada, bo, call, sessions } = team();
		const start = Date.parse('2026-10-31T09:00:00Z');
		setSystemTime(new Date(start));
		await call(ada, 'start_session', { provider: 'claude', source_id: 'stale', intent: '' });
		const done = await call<Out>(bo, 'start_session', { provider: 'claude', source_id: 'done', intent: '' });
		await call(bo, 'check_session', { session_id: done.session_id, state: 'ended' });
		setSystemTime(new Date(start + 2 * 3600_000));
		await call(bo, 'start_session', { provider: 'claude', source_id: 'fresh', intent: '' });
		const live = async () => Object.fromEntries((await sessions(ada)).map((s) => [`${s.owner.handle}:${s.state}`, s.live]));

		expect(await live()).toEqual({ 'bo:active': true, 'ada:active': true, 'bo:ended': false });
		setSystemTime(new Date(start + 3 * 3600_000 + 60_000));
		expect(await live()).toEqual({ 'bo:active': true, 'ada:active': false, 'bo:ended': false });
		expect((await sessions(ada, 120)).length).toBe(1);
	});

	test('every change tells open pages to refresh; a bare heartbeat does not', async () => {
		const { hq, ada, call } = team();
		const events: unknown[] = [];
		hq.hub.bus.on((e) => e.type === 'app.event' && e.app === 'tasks' && e.name === 'changed' && events.push(e.data));
		const { session_id } = await call<Out>(ada, 'start_session', { provider: 'claude', source_id: 's', intent: '' });
		await call(ada, 'check_session', { session_id });
		await call(ada, 'check_session', { session_id, intent: 'testing' });
		await call(ada, 'link_session_tasks', { session_id, task_ids: [] });
		await call(ada, 'active_sessions', {});
		expect(events).toEqual([{ session_id }, { session_id }, { session_id }]);
	});

	test('the assistant in chat cannot use the session tools', async () => {
		const { hq } = team();
		const self = { hub: hq.hub, caller: hq.assistant.self };
		const result = await hq.registry.call('start_session', { provider: 'claude', source_id: 's', intent: '' }, self);
		expect(result.ok).toBe(false);
		const names = hq.registry.specs('assistant', self).map((spec) => spec.name);
		expect(names).toContain('add_task');
		expect(names.filter((name) => name.includes('session'))).toEqual([]);
	});

	test("start_session's answer hides task titles the current viewers can't see", async () => {
		const { hq, ada, bo, as } = team();
		const room = hq.hub.conversations.createRoom({ title: 'Comp', createdBy: ada.id });
		const added = await hq.registry.call(
			'add_task',
			{ title: 'Raise for Cy' },
			{ hub: hq.hub, caller: hq.assistant.self, conversationId: room.id, viewers: [ada.id] },
		);
		const secret = (added as { value: { id: string } }).value.id;
		const input = { provider: 'claude', source_id: 's', intent: '' };
		await hq.registry.call('start_session', { ...input, task_ids: [secret] }, as(ada));
		const again = await hq.registry.call('start_session', input, { ...as(ada), viewers: [bo.id] });
		expect(again).toMatchObject({ ok: true, value: { tasks: [{ id: secret, title: null }] } });
	});

	test('resuming with new_task_title does not file the task again, even after unlinking', async () => {
		const { hq, bo, call } = team();
		const input = { provider: 'cursor', source_id: 'x', intent: 'go', new_task_title: 'Docs pass' };
		const { session_id } = await call<Out>(bo, 'start_session', input);
		await call<Out>(bo, 'start_session', input);
		await call(bo, 'link_session_tasks', { session_id, task_ids: [] });
		const resumed = await call<Out>(bo, 'start_session', input);
		const titles = async () =>
			(
				(await hq.registry.call('list_tasks', { owner_handle: 'bo' }, { hub: hq.hub, caller: hq.assistant.self })) as {
					value: { title: string }[];
				}
			).value.map((t) => t.title);
		expect(await titles()).toEqual(['Docs pass']);
		expect(resumed.tasks.map((t) => t.title)).toEqual(['Docs pass']);

		const other = await call<Out>(bo, 'start_session', { ...input, new_task_title: 'Review pass' });
		expect(other.tasks.map((t) => t.title)).toEqual(['Docs pass', 'Review pass']);
		expect((await titles()).sort()).toEqual(['Docs pass', 'Review pass']);
	});

	test("one person's many sessions can't push others off the board", async () => {
		const { ada, bo, call, sessions } = team();
		await call(ada, 'start_session', { provider: 'claude', source_id: 'mine', intent: '' });
		for (let i = 0; i < 60; i++) await call(bo, 'start_session', { provider: 'claude', source_id: `b${i}`, intent: '' });
		const rows = await sessions(ada);
		expect(rows.filter((s) => s.owner.handle === 'bo')).toHaveLength(50);
		expect(rows.filter((s) => s.owner.handle === 'ada')).toHaveLength(1);
	});

	test('lengths are validated', async () => {
		const { hq, as, ada } = team();
		const result = await hq.registry.call(
			'start_session',
			{ provider: 'claude', source_id: 's', intent: '', title: 'x'.repeat(121) },
			as(ada),
		);
		expect(result.ok).toBe(false);
	});
});
