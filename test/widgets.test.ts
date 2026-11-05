import { describe, expect, spyOn, test } from 'bun:test';
import { defineApp } from '@hq/sdk';
import tasks from '../apps/tasks/app';
import { widgetWork } from '../src/widgets';
import { client, pair } from './helpers';
import { wire } from './wire-fixture';

// The Mac widgets' routes: a widget key that reads one person's tasks and nothing else.

const KEY = /^hq_widget_[A-Za-z0-9_-]{12}_[A-Za-z0-9_-]{43}$/;
const DAY = 86_400_000;

// What the app decodes, as the fixture says it.
function shape(name: string, value: unknown, path = name): string[] {
	const spec = wire.structs[name]!;
	if (typeof value !== 'object' || value === null || Array.isArray(value)) return [`${path}: expected an object`];
	const object = value as Record<string, unknown>;
	const problems: string[] = [];
	for (const key of Object.keys(object)) if (!(key in spec)) problems.push(`${path}.${key}: the app does not decode this`);
	for (const [key, field] of Object.entries(spec)) {
		const present = object[key];
		if (present === undefined || present === null) {
			if (field.required) problems.push(`${path}.${key}: the app requires this`);
			continue;
		}
		if (key.endsWith('_at') && !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(String(present))) {
			problems.push(`${path}.${key}: not an ISO time with milliseconds`);
		}
		if (field.of === undefined) continue;
		if (!field.list) problems.push(...shape(field.of, present, `${path}.${key}`));
		else if (!Array.isArray(present)) problems.push(`${path}.${key}: expected a list`);
		else present.forEach((item, i) => problems.push(...shape(field.of!, item, `${path}.${key}[${i}]`)));
	}
	return problems;
}

async function setup() {
	const made = await pair({ apps: [tasks] });
	const mint = async (who: { as: ReturnType<typeof client> } = made.a) => {
		const response = await who.as('POST', '/v1/widgets/key');
		expect(response.status).toBe(201);
		return response.body.key as string;
	};
	const widget = (key: string) => client(made.hq, key);
	return { ...made, mint, widget };
}

type Setup = Awaited<ReturnType<typeof setup>>;

/** Files a task owned by `who` and (optionally) puts it on the board in a state, with a set touched time. */
async function file(s: Setup, who: Setup['a'], title: string, extra: Record<string, unknown> = {}, touched?: number) {
	const made = await who.as('POST', '/v1/tasks', { title, owner_person_id: who.person.id, ...extra });
	expect(made.status).toBe(201);
	const task = made.body.task;
	if (touched !== undefined)
		s.hq.hub.db.query('UPDATE tasks SET touched_at = $at WHERE id = $id').run({ at: touched, id: task.id });
	return task;
}

const titles = (list: { title: string }[]) => list.map((t) => t.title);

describe('minting a widget key', () => {
	test('a device bearer gets a key, shown once and kept only as a hash, outside api_keys', async () => {
		const s = await setup();
		const keysBefore = s.hq.hub.keys.list(s.a.person.id).length;
		const response = await s.a.as('POST', '/v1/widgets/key');
		expect(response.status).toBe(201);
		expect(shape('WidgetKey', response.body)).toEqual([]);
		const key: string = response.body.key;
		expect(key).toMatch(KEY);
		const secret = key.slice(-43);
		const rows = s.hq.hub.db.query<Record<string, unknown>, []>('SELECT * FROM widget_keys').all();
		expect(rows).toHaveLength(1);
		expect(JSON.stringify(rows)).not.toContain(secret);
		expect(rows[0]!.hash).toBe(new Bun.CryptoHasher('sha256').update(secret).digest('hex'));
		// It is no api key: the person holds the same keys as before, and the router's own sign-in refuses it.
		expect(s.hq.hub.keys.list(s.a.person.id)).toHaveLength(keysBefore);
		expect(s.hq.hub.keys.check(key)).toEqual({ ok: false, error: 'unauthorized' });
	});

	test('answers are never cached, errors included', async () => {
		const s = await setup();
		const request = (path: string, bearer?: string) =>
			s.hq.fetch(
				new Request(`http://hq.test${path}`, { headers: bearer === undefined ? {} : { authorization: `Bearer ${bearer}` } }),
			);
		expect((await request('/v1/widgets/summary', s.a.bearer))!.headers.get('cache-control')).toBe('no-store');
		expect((await request('/v1/widgets/summary'))!.headers.get('cache-control')).toBe('no-store');
		const minted = await s.a.as('POST', '/v1/widgets/key');
		expect(minted.status).toBe(201);
		const refused = await s.hq.fetch(
			new Request('http://hq.test/v1/widgets/key', { method: 'POST', headers: { authorization: `Bearer ${minted.body.key}` } }),
		);
		expect(refused!.status).toBe(403);
		expect(refused!.headers.get('cache-control')).toBe('no-store');
	});

	test('a widget key cannot mint another, and neither can a script key or no key', async () => {
		const s = await setup();
		const key = await s.mint();
		expect(await s.widget(key)('POST', '/v1/widgets/key')).toEqual({ status: 403, body: { error: 'device_bearer_required' } });
		// Ada's plain api key is a bearer but no device.
		expect(await client(s.hq, s.ada.key)('POST', '/v1/widgets/key')).toEqual({
			status: 403,
			body: { error: 'device_bearer_required' },
		});
		expect((await client(s.hq)('POST', '/v1/widgets/key')).status).toBe(401);
		expect((await client(s.hq, 'hq_nothing')('POST', '/v1/widgets/key')).status).toBe(401);
		expect(s.hq.hub.db.query('SELECT COUNT(*) AS n FROM widget_keys').get()).toEqual({ n: 1 });
	});

	test('minting again revokes that device’s earlier key and leaves other devices’ alone', async () => {
		const s = await setup();
		const first = await s.mint(s.a);
		const bos = await s.mint(s.b);
		const second = await s.mint(s.a);
		expect(second).not.toBe(first);
		expect((await s.widget(first)('GET', '/v1/widgets/summary')).status).toBe(401);
		expect((await s.widget(second)('GET', '/v1/widgets/summary')).status).toBe(200);
		expect((await s.widget(bos)('GET', '/v1/widgets/summary')).body.me.name).toBe('Bo');
		const live = s.hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM widget_keys WHERE revoked_at IS NULL').get()!.n;
		expect(live).toBe(2);
	});
});

describe('a widget key', () => {
	test('is refused with the wrong secret, a malformed key, and a key of someone else’s shape', async () => {
		const s = await setup();
		const key = await s.mint();
		const id = key.slice('hq_widget_'.length, 'hq_widget_'.length + 12);
		const wrong = `hq_widget_${id}_${'A'.repeat(43)}`;
		for (const bad of [wrong, key.slice(0, -1), `${key}x`, key.replace('hq_widget_', 'hq_'), 'hq_widget_', '']) {
			expect(await s.widget(bad)('GET', '/v1/widgets/summary')).toEqual({ status: 401, body: { error: 'unauthorized' } });
		}
		expect((await s.widget(key)('GET', '/v1/widgets/summary')).status).toBe(200);
	});

	test('works on no route but the summary', async () => {
		const s = await setup();
		const key = await s.mint();
		const as = s.widget(key);
		const refused = [
			['GET', '/v1/conversations'],
			['GET', '/v1/people'],
			['GET', '/v1/calls'],
			['GET', '/v1/tasks'],
			['POST', '/v1/tasks', { title: 'Sneak' }],
			['POST', `/v1/conversations/${s.room.id}/messages`, { client_msg_id: crypto.randomUUID(), content: 'hi' }],
			['GET', '/v1/apps'],
			['GET', '/apps/tasks/api/tasks'],
			['POST', '/v1/devices/apns-token', { status: 'unregistered' }],
			['POST', `/v1/people/${s.b.person.id}/remove`],
		] as const;
		for (const [method, path, body] of refused) {
			const response = await as(method, path, body);
			expect([method, path, response.status]).toEqual([method, path, 401]);
		}
		// Not MCP, not the socket, which sign in with a bearer too.
		const mcp = await s.hq.fetch(
			new Request('http://hq.test/mcp', { method: 'POST', headers: { authorization: `Bearer ${key}` } }),
		);
		expect(mcp!.status).toBe(401);
		const socket = await s.hq.fetch(
			new Request('http://hq.test/v1/ws', { headers: { upgrade: 'websocket', authorization: `Bearer ${key}` } }),
			{} as never,
		);
		expect(socket!.status).toBe(401);
		// And what it may do does show: the summary.
		expect((await as('GET', '/v1/widgets/summary')).status).toBe(200);
	});

	test('stops when its device is revoked', async () => {
		const s = await setup();
		const key = await s.mint();
		expect((await s.widget(key)('GET', '/v1/widgets/summary')).status).toBe(200);
		s.hq.hub.devices.revoke(s.a.deviceId);
		expect((await s.widget(key)('GET', '/v1/widgets/summary')).status).toBe(401);
	});

	test('stops when its person is removed, and returns only if they are restored', async () => {
		const s = await setup();
		const key = await s.mint(s.b);
		// Frozen only: the device's own bearer is left alone, so the widget key itself is what is checked.
		s.hq.hub.people.setRemoved(s.b.person.id, Date.now());
		expect((await s.widget(key)('GET', '/v1/widgets/summary')).status).toBe(401);
		s.hq.hub.people.setRemoved(s.b.person.id, null);
		expect((await s.widget(key)('GET', '/v1/widgets/summary')).status).toBe(200);
	});

	test('stops when an admin removes the person through the app’s route', async () => {
		const s = await setup();
		const key = await s.mint(s.b);
		expect((await s.a.as('POST', `/v1/people/${s.b.person.id}/remove`)).status).toBe(200);
		expect((await s.widget(key)('GET', '/v1/widgets/summary')).status).toBe(401);
	});
});

describe('revoking', () => {
	test('DELETE with the device bearer ends the key', async () => {
		const s = await setup();
		const key = await s.mint();
		expect((await s.a.as('DELETE', '/v1/widgets/key')).status).toBe(204);
		expect((await s.widget(key)('GET', '/v1/widgets/summary')).status).toBe(401);
		// Nothing to revoke is still fine, and the device can mint a new one.
		expect((await s.a.as('DELETE', '/v1/widgets/key')).status).toBe(204);
		expect((await s.widget(await s.mint())('GET', '/v1/widgets/summary')).status).toBe(200);
	});

	test('DELETE with the key itself ends it, and only that device’s', async () => {
		const s = await setup();
		const mine = await s.mint(s.a);
		const bos = await s.mint(s.b);
		expect((await s.widget(mine)('DELETE', '/v1/widgets/key')).status).toBe(204);
		expect((await s.widget(mine)('GET', '/v1/widgets/summary')).status).toBe(401);
		expect((await s.widget(bos)('GET', '/v1/widgets/summary')).status).toBe(200);
	});

	test('DELETE with no sign-in is refused', async () => {
		const s = await setup();
		await s.mint();
		expect((await client(s.hq)('DELETE', '/v1/widgets/key')).status).toBe(401);
	});
});

describe('the summary', () => {
	test('is the same for a device bearer and for the widget key, and is what the app decodes', async () => {
		const s = await setup();
		await file(s, s.a, 'Write the guide', { due_at: '2026-12-01T00:00:00.000Z' });
		const key = await s.mint();
		const byKey = await s.widget(key)('GET', '/v1/widgets/summary');
		const byDevice = await s.a.as('GET', '/v1/widgets/summary');
		expect(byKey.status).toBe(200);
		expect(shape('WidgetSummary', byKey.body)).toEqual([]);
		expect({ ...byDevice.body, generated_at: 0 }).toEqual({ ...byKey.body, generated_at: 0 });
		expect(byKey.body.version).toBe(1);
		expect(byKey.body.me).toEqual({ id: s.a.person.id, name: 'Ada', avatar_id: null });
		// Company analytics and the alert ladder are not here.
		expect(Object.keys(byKey.body).sort()).toEqual(['generated_at', 'me', 'version', 'work']);
		expect(Date.now() - Date.parse(byKey.body.generated_at)).toBeLessThan(5000);
	});

	test('counts the person’s own tasks by status and lists at most five of each', async () => {
		const s = await setup();
		const now = Date.now();
		for (let i = 1; i <= 7; i++) await file(s, s.a, `Todo ${i}`, {}, now - i * 1000);
		for (let i = 1; i <= 6; i++) {
			const task = await file(s, s.a, `Doing ${i}`);
			await s.a.as('PATCH', `/v1/tasks/${task.id}`, { status: 'in_progress' });
			s.hq.hub.db.query('UPDATE tasks SET touched_at = $at WHERE id = $id').run({ at: now - i * 1000, id: task.id });
		}
		const stuck = await file(s, s.a, 'Stuck');
		await s.a.as('PATCH', `/v1/tasks/${stuck.id}`, { status: 'blocked' });
		const done = await file(s, s.a, 'Finished');
		await s.a.as('PATCH', `/v1/tasks/${done.id}`, { status: 'done' });
		const old = await file(s, s.a, 'Finished long ago');
		await s.a.as('PATCH', `/v1/tasks/${old.id}`, { status: 'done' });
		s.hq.hub.db.query('UPDATE tasks SET completed_at = $at WHERE id = $id').run({ at: now - 8 * DAY, id: old.id });
		// Bo's tasks are Bo's.
		await file(s, s.b, 'Bo’s own');

		const { work } = (await s.a.as('GET', '/v1/widgets/summary')).body;
		expect([work.in_progress, work.blocked, work.open, work.done_week]).toEqual([6, 1, 7, 1]);
		// In progress, then blocked, then to do; newest touched first within a status.
		expect(titles(work.tasks)).toEqual([
			...[1, 2, 3, 4, 5].map((i) => `Doing ${i}`),
			'Stuck',
			...[1, 2, 3, 4, 5].map((i) => `Todo ${i}`),
		]);
		expect(work.tasks.map((t: { status: string }) => t.status)).toEqual([
			...Array<string>(5).fill('in_progress'),
			'blocked',
			...Array<string>(5).fill('open'),
		]);
		expect(titles(work.tasks)).not.toContain('Bo’s own');
		expect((await s.b.as('GET', '/v1/widgets/summary')).body.work).toMatchObject({ open: 1, in_progress: 0 });
	});

	test('a card carries what a task card shows, and the to-do list puts the soonest due date first', async () => {
		const s = await setup();
		const project = await s.a.as('POST', '/v1/projects', { name: 'Docs site' });
		expect(project.status).toBe(201);
		const later = await file(s, s.a, 'Later', { due_at: '2026-12-20T09:30:00.000Z' });
		const sooner = await file(s, s.a, 'Sooner', { due_at: '2026-12-02T00:00:00.000Z', project_id: project.body.project.id });
		const undated = await file(s, s.a, 'Undated');
		await s.a.as('POST', `/v1/tasks/${sooner.id}/comments`, { body: 'One' });
		await s.a.as('POST', `/v1/tasks/${sooner.id}/comments`, { body: 'Two' });
		const { work } = (await s.a.as('GET', '/v1/widgets/summary')).body;
		expect(titles(work.tasks)).toEqual(['Sooner', 'Later', 'Undated']);
		expect(work.tasks[0]).toEqual({
			id: sooner.id,
			number: sooner.number,
			ref: `HQ-${sooner.number}`,
			title: 'Sooner',
			status: 'open',
			project_name: 'Docs site',
			comment_count: 2,
			due_at: '2026-12-02T00:00:00.000Z',
			touched_at: expect.stringMatching(/Z$/),
		});
		expect(work.tasks[2]).toMatchObject({ id: undated.id, due_at: null, project_name: null, comment_count: 0 });
		expect(work.next_due).toEqual(work.tasks[0]);
		expect(later.id).not.toBe(sooner.id);
	});

	test('next due is the soonest of everything owed, even past the five listed', async () => {
		const s = await setup();
		for (let i = 1; i <= 6; i++)
			await file(s, s.a, `Dated ${i}`, { due_at: `2026-12-${String(10 + i).padStart(2, '0')}T00:00:00.000Z` });
		const blocked = await file(s, s.a, 'Blocked and due first', { due_at: '2026-11-30T00:00:00.000Z' });
		await s.a.as('PATCH', `/v1/tasks/${blocked.id}`, { status: 'blocked' });
		const done = await file(s, s.a, 'Done and earlier', { due_at: '2026-01-01T00:00:00.000Z' });
		await s.a.as('PATCH', `/v1/tasks/${done.id}`, { status: 'done' });
		const { work } = (await s.a.as('GET', '/v1/widgets/summary')).body;
		expect(work.next_due).toMatchObject({ title: 'Blocked and due first', status: 'blocked' });
		expect(
			shape('WidgetSummary', { version: 1, generated_at: new Date().toISOString(), me: { id: 'x', name: 'x' }, work }),
		).toEqual([]);
	});

	test('leaves out hidden tasks, and tasks in a room the person has left', async () => {
		const s = await setup();
		const hidden = await file(s, s.a, 'Deleted');
		expect((await s.a.as('DELETE', `/v1/tasks/${hidden.id}`)).status).toBe(200);
		const kept = await file(s, s.a, 'Kept');
		// A task nobody took belongs to whoever filed it, unless it came from a room they are not in.
		const room = s.hq.hub.conversations.createRoom({ title: 'Private', createdBy: s.b.person.id, memberIds: [s.b.person.id] });
		const insert = s.hq.hub.db.query(
			`INSERT INTO tasks (id, title, status, owner_id, created_by, conversation_id, created_at, touched_at, number, position)
			VALUES ($id, $title, 'open', NULL, $by, $room, $at, $at, $number, $number)`,
		);
		const base = { by: s.a.person.id, at: Date.now() };
		insert.run({ ...base, id: 'unowned-elsewhere', title: 'Unowned, from a room Ada is not in', room: room.id, number: 9001 });
		insert.run({ ...base, id: 'unowned-nowhere', title: 'Unowned, filed by Ada', room: null as never, number: 9002 });
		const { work } = (await s.a.as('GET', '/v1/widgets/summary')).body;
		expect(titles(work.tasks).sort()).toEqual(['Kept', 'Unowned, filed by Ada']);
		expect(work.open).toBe(2);
		expect(kept.title).toBe('Kept');
	});

	test('is empty, and still answers, with no tasks app', async () => {
		const made = await pair();
		const key = (await made.a.as('POST', '/v1/widgets/key')).body.key;
		const response = await client(made.hq, key)('GET', '/v1/widgets/summary');
		expect(response.status).toBe(200);
		expect(response.body.work).toEqual({ in_progress: 0, open: 0, blocked: 0, done_week: 0, next_due: null, tasks: [] });
	});

	test('is empty when the tasks hook fails, and the hook is the first app’s that has one', async () => {
		const fails = defineApp({
			slug: 'fails',
			name: 'Fails',
			description: 'Fails',
			widgetWork: () => {
				throw new Error('boom');
			},
		});
		const quiet = spyOn(console, 'error').mockImplementation(() => {});
		const made = await pair({ apps: [fails, tasks] });
		await made.a.as('POST', '/v1/tasks', { title: 'Hidden by the failure' });
		const response = await made.a.as('GET', '/v1/widgets/summary');
		quiet.mockRestore();
		expect(response.status).toBe(200);
		expect(response.body.work.tasks).toEqual([]);

		const empty = { in_progress: 0, open: 0, blocked: 0, done_week: 0, next_due: null, tasks: [] };
		const mine = { ...empty, open: 3 };
		const theirs = { ...empty, open: 9 };
		const mount = (slug: string, work?: typeof empty) => ({
			app: defineApp({ slug, name: slug, description: slug, ...(work === undefined ? {} : { widgetWork: () => work }) }),
			context: {} as never,
		});
		const person = made.ada.person;
		expect(widgetWork([mount('none'), mount('first', mine), mount('second', theirs)], person)).toEqual(mine);
		expect(widgetWork([mount('none')], person)).toEqual(empty);
	});
});
