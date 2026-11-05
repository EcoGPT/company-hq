import { afterEach, describe, expect, test } from 'bun:test';
import type { Server } from 'bun';
import { migrate, openDatabase } from '../../src/db/database';
import type { SocketData } from '../../src/realtime/socket';
import { client, connect, enrolled, pair, serve, type Connection } from '../../test/helpers';
import { wire } from '../../test/wire-fixture';
import tasks from './app';
import { withinFrame } from './planning';
import { Sessions } from './sessions';
import { migrations } from './store';

// What the app decodes, as the fixture says it: every key the server sends is one the app reads, and every key the app
// requires is there.
function shape(name: string, value: unknown, path = name): string[] {
	const spec = wire.structs[name]!;
	if (typeof value !== 'object' || value === null || Array.isArray(value)) return [`${path}: expected an object`];
	const object = value as Record<string, unknown>;
	const problems: string[] = [];
	for (const key of Object.keys(object))
		if (key !== 'type' && !(key in spec)) problems.push(`${path}.${key}: the app does not decode this`);
	for (const [key, field] of Object.entries(spec)) {
		const present = object[key];
		if (present === undefined || present === null) {
			if (field.required) problems.push(`${path}.${key}: the app requires this`);
			continue;
		}
		if (key.endsWith('_at') && Number.isNaN(Date.parse(String(present)))) problems.push(`${path}.${key}: not an ISO time`);
		if (field.of === undefined) continue;
		if (!field.list) problems.push(...shape(field.of, present, `${path}.${key}`));
		else if (!Array.isArray(present)) problems.push(`${path}.${key}: expected a list`);
		else present.forEach((item, i) => problems.push(...shape(field.of!, item, `${path}.${key}[${i}]`)));
	}
	return problems;
}

const decodes = (name: string, value: unknown) => expect(shape(name, value)).toEqual([]);

async function team() {
	const made = await pair({ apps: [tasks] });
	const cy = made.hq.hub.people.create({ name: 'Cy', handle: 'cy' });
	made.hq.hub.conversations.addMember(made.hq.hub.general().id, cy.id);
	return { ...made, cy };
}

type Wire = { id: string; number: number; title: string; status: string; project_ids: string[]; [key: string]: any };
const titles = (body: { tasks: Wire[] }) => body.tasks.map((t) => t.title);

describe('the board', () => {
	test('a member files a task, and everyone sees it as the app decodes it', async () => {
		const { a, b } = await team();
		const made = await b.as('POST', '/v1/tasks', {
			title: '  Write the guide ',
			body: 'Start with install',
			owner_person_id: a.person.id,
		});
		expect(made.status).toBe(201);
		decodes('TaskEnvelope', made.body);
		expect(made.body.task).toMatchObject({
			title: 'Write the guide',
			body: 'Start with install',
			status: 'open',
			owner_person_id: a.person.id,
			owner_name: 'Ada',
			created_by_person_id: b.person.id,
			number: 1,
			project_id: null,
			project_ids: [],
			comment_count: 0,
			due_at: null,
			resolved_at: null,
		});
		for (const as of [a.as, b.as]) {
			const list = await as('GET', '/v1/tasks');
			decodes('TasksEnvelope', list.body);
			expect(titles(list.body)).toEqual(['Write the guide']);
		}
	});

	test('numbers are one more than the last and never come back, even after a delete', async () => {
		const { a } = await team();
		const first = (await a.as('POST', '/v1/tasks', { title: 'one' })).body.task;
		const second = (await a.as('POST', '/v1/tasks', { title: 'two' })).body.task;
		expect([first.number, second.number]).toEqual([1, 2]);
		await a.as('DELETE', `/v1/tasks/${second.id}`);
		expect((await a.as('POST', '/v1/tasks', { title: 'three' })).body.task.number).toBe(3);
	});

	test('an unowned task is its filer’s on the board, an owner who is gone cannot be given a task', async () => {
		const { hq, a, b } = await team();
		const made = (await a.as('POST', '/v1/tasks', { title: 'mine' })).body.task;
		expect(made).toMatchObject({ owner_person_id: a.person.id, owner_name: 'Ada' });
		const bad = await a.as('POST', '/v1/tasks', { title: 'x', owner_person_id: 'nobody' });
		expect(bad).toEqual({ status: 400, body: { error: 'no such person' } });
		hq.hub.people.setRemoved(b.person.id, Date.now());
		expect((await a.as('PATCH', `/v1/tasks/${made.id}`, { owner_person_id: b.person.id })).status).toBe(400);
		// A task the assistant filed with nobody on it belongs to whoever filed it.
		const filed = await hq.registry.call('add_task', { title: 'follow up' }, { hub: hq.hub, caller: hq.assistant.self });
		expect(filed.ok).toBe(true);
		const row = (await a.as('GET', '/v1/tasks')).body.tasks.find((t: Wire) => t.title === 'follow up');
		expect(row).toMatchObject({ owner_person_id: hq.assistant.self.id, created_by_person_id: hq.assistant.self.id });
		decodes('TasksEnvelope', { tasks: [row] });
	});

	test('status moves through the four lists, and done keeps who finished it', async () => {
		const { hq, a, b } = await team();
		const { id } = (await a.as('POST', '/v1/tasks', { title: 'ship', owner_person_id: a.person.id })).body.task;
		const set = async (as: typeof a.as, status: string) => (await as('PATCH', `/v1/tasks/${id}`, { status })).body.task as Wire;
		expect((await set(a.as, 'in_progress')).status).toBe('in_progress');
		expect((await set(a.as, 'blocked')).status).toBe('blocked');
		// The assistant's lists know only open and done: in progress and blocked are both open to it.
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		const open = await hq.registry.call('list_tasks', {}, ctx);
		expect(open.ok && (open.value as { title: string }[]).map((t) => t.title)).toEqual(['ship']);
		const done = await set(b.as, 'done');
		expect(done).toMatchObject({ status: 'done', resolved_by_person_id: b.person.id });
		expect(done.resolved_at).toBeTruthy();
		decodes('TaskEnvelope', { task: done });
		expect((await hq.registry.call('list_tasks', {}, ctx)) as unknown).toEqual({ ok: true, value: [] });
		const reopened = await set(a.as, 'in_progress');
		expect(reopened).toMatchObject({ status: 'in_progress', resolved_at: null, resolved_by_person_id: null });
		expect((await a.as('PATCH', `/v1/tasks/${id}`, { status: 'later' })).status).toBe(400);
	});

	test('edits: title, body, owner, due date and clearing them', async () => {
		const { a, b } = await team();
		const { id } = (await a.as('POST', '/v1/tasks', { title: 'plan', body: 'old', due_at: '2026-11-03T10:00:00Z' })).body.task;
		const edited = (
			await b.as('PATCH', `/v1/tasks/${id}`, { title: 'plan v2', body: null, owner_person_id: b.person.id, due_at: null })
		).body.task;
		expect(edited).toMatchObject({ title: 'plan v2', body: null, owner_person_id: b.person.id, owner_name: 'Bo', due_at: null });
		const dated = (await a.as('PATCH', `/v1/tasks/${id}`, { due_at: '2026-12-01T09:30:00Z' })).body.task;
		expect(dated.due_at).toBe('2026-12-01T09:30:00.000Z');
		expect(Date.parse(dated.touched_at)).toBeGreaterThanOrEqual(Date.parse(edited.created_at));
		expect((await a.as('PATCH', `/v1/tasks/${id}`, { due_at: 'tomorrow-ish' })).status).toBe(400);
		expect((await a.as('PATCH', `/v1/tasks/${id}`, { title: '   ' })).status).toBe(400);
		expect((await a.as('PATCH', `/v1/tasks/${id}`, { recurrence: { freq: 'daily', timezone: 'UTC' } })).status).toBe(400);
		expect((await a.as('PATCH', `/v1/tasks/nope`, { title: 'x' })).status).toBe(404);
	});

	test('sizes are capped', async () => {
		const { a } = await team();
		expect((await a.as('POST', '/v1/tasks', { title: 'x'.repeat(401) })).status).toBe(400);
		expect((await a.as('POST', '/v1/tasks', { title: 'ok', body: 'x'.repeat(16_001) })).status).toBe(400);
		expect((await a.as('POST', '/v1/tasks', { title: 'ok', body: 'x'.repeat(300 * 1024) })).status).toBe(413);
		expect((await a.as('POST', '/v1/tasks', { title: 'ok', body: 'x'.repeat(16_000) })).status).toBe(201);
		expect((await a.as('POST', '/v1/tasks/x/order', { before_task_id: 'y'.repeat(5000) })).status).toBe(413);
	});

	test('no sign-in, no board', async () => {
		const { hq } = await team();
		for (const [method, path] of [
			['GET', '/v1/tasks'],
			['POST', '/v1/tasks'],
			['GET', '/v1/projects'],
			['POST', '/v1/projects'],
			['GET', '/v1/tasks/x/comments'],
		] as const) {
			expect((await client(hq)(method, path, method === 'POST' ? { title: 'x', name: 'x' } : undefined)).status).toBe(401);
		}
	});
});

describe('deleting hides', () => {
	test('the row stays, the board and the assistant stop listing it, and only its people may', async () => {
		const { hq, a, b, cy } = await team();
		const mine = (await a.as('POST', '/v1/tasks', { title: 'mine', owner_person_id: a.person.id })).body.task;
		const theirs = (await b.as('POST', '/v1/tasks', { title: 'theirs', owner_person_id: b.person.id })).body.task;
		const asCy = client(hq, hq.hub.keys.mint(cy.id).secret);
		expect((await asCy('DELETE', `/v1/tasks/${mine.id}`)).status).toBe(403);
		expect((await b.as('DELETE', `/v1/tasks/${mine.id}`)).status).toBe(403);
		expect((await a.as('DELETE', `/v1/tasks/${mine.id}`)).body).toEqual({ ok: true });
		decodes('OkEnvelope', { ok: true });
		// An admin may delete anyone's.
		expect((await a.as('DELETE', `/v1/tasks/${theirs.id}`)).status).toBe(200);
		expect((await a.as('DELETE', `/v1/tasks/${theirs.id}`)).status).toBe(404);
		expect((await a.as('GET', '/v1/tasks')).body.tasks).toEqual([]);
		expect((await a.as('GET', '/apps/tasks/api/tasks?status=all')).body).toEqual([]);
		expect((await a.as('PATCH', `/v1/tasks/${mine.id}`, { title: 'back' })).status).toBe(404);
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM tasks WHERE hidden_at IS NOT NULL').get()).toEqual({ n: 2 });
	});

	test('a deleted task leaves the coding sessions it was linked to', async () => {
		const { hq, a } = await team();
		const kept = (await a.as('POST', '/v1/tasks', { title: 'kept' })).body.task;
		const gone = (await a.as('POST', '/v1/tasks', { title: 'gone' })).body.task;
		const sessions = new Sessions(hq.hub);
		const session = sessions.start(a.person.id, { provider: 'test', source_id: 'one', title: 'work' });
		sessions.link(session.id, [kept.id, gone.id], true);
		await a.as('DELETE', `/v1/tasks/${gone.id}`);
		expect(
			sessions
				.links([session.id])
				.get(session.id)
				?.map((t) => t.title),
		).toEqual(['kept']);
	});
});

describe('order', () => {
	const make = async (as: (m: string, p: string, b?: unknown) => Promise<{ status: number; body: any }>, ...names: string[]) => {
		const out: Wire[] = [];
		for (const title of names) out.push((await as('POST', '/v1/tasks', { title })).body.task);
		return out;
	};

	test('a task lands before or after another, and the answer is the whole board in that order', async () => {
		const { a, b } = await team();
		const [one, two, three, four] = await make(a.as, 'one', 'two', 'three', 'four');
		expect(titles((await a.as('GET', '/v1/tasks')).body)).toEqual(['one', 'two', 'three', 'four']);
		const up = await b.as('POST', `/v1/tasks/${four!.id}/order`, { before_task_id: two!.id });
		expect(up.status).toBe(200);
		decodes('TasksEnvelope', up.body);
		expect(titles(up.body)).toEqual(['one', 'four', 'two', 'three']);
		expect(titles((await a.as('POST', `/v1/tasks/${one!.id}/order`, { after_task_id: three!.id })).body)).toEqual([
			'four',
			'two',
			'three',
			'one',
		]);
		expect(titles((await a.as('POST', `/v1/tasks/${one!.id}/order`, { before_task_id: four!.id })).body)).toEqual([
			'one',
			'four',
			'two',
			'three',
		]);
		// It sticks.
		expect(titles((await b.as('GET', '/v1/tasks')).body)).toEqual(['one', 'four', 'two', 'three']);
	});

	test('many moves into one gap still order, because the board is numbered again when a gap gets too small', async () => {
		const { a } = await team();
		const [first, last, ...movers] = await make(a.as, 'first', 'last', ...Array.from({ length: 60 }, (_, i) => `m${i}`));
		await a.as('POST', `/v1/tasks/${last!.id}/order`, { after_task_id: movers[movers.length - 1]!.id });
		for (const mover of movers) await a.as('POST', `/v1/tasks/${mover.id}/order`, { after_task_id: first!.id });
		const order = titles((await a.as('GET', '/v1/tasks')).body);
		expect(order).toEqual(['first', ...movers.map((m) => m.title).reverse(), 'last']);
	});

	test('the moved task and its neighbour must both be there for the mover', async () => {
		const { a } = await team();
		const [one, two] = await make(a.as, 'one', 'two');
		const at = (id: string, body: unknown) => a.as('POST', `/v1/tasks/${id}/order`, body);
		expect((await at(one!.id, { before_task_id: one!.id })).status).toBe(400);
		expect((await at(one!.id, { before_task_id: 'ghost' })).status).toBe(404);
		expect((await at('ghost', { before_task_id: two!.id })).status).toBe(404);
		expect((await at(one!.id, {})).status).toBe(400);
		expect((await at(one!.id, { before_task_id: two!.id, after_task_id: two!.id })).status).toBe(400);
	});
});

describe('comments', () => {
	test('are plain text with an author, oldest first, and counted on the task', async () => {
		const { a, b } = await team();
		const task = (await a.as('POST', '/v1/tasks', { title: 'talk' })).body.task;
		const first = await a.as('POST', `/v1/tasks/${task.id}/comments`, { body: '  first <b>note</b> ' });
		expect(first.status).toBe(201);
		decodes('CommentEnvelope', first.body);
		expect(first.body.comment).toMatchObject({ body: 'first <b>note</b>', author_name: 'Ada', author_person_id: a.person.id });
		await b.as('POST', `/v1/tasks/${task.id}/comments`, { body: 'second' });
		const listed = await a.as('GET', `/v1/tasks/${task.id}/comments`);
		decodes('CommentsEnvelope', listed.body);
		expect(listed.body.comments.map((c: { body: string; author_name: string }) => [c.author_name, c.body])).toEqual([
			['Ada', 'first <b>note</b>'],
			['Bo', 'second'],
		]);
		expect((await b.as('GET', '/v1/tasks')).body.tasks[0].comment_count).toBe(2);
	});

	test('have a length cap, cannot be empty, and a thread holds a thousand', async () => {
		const { hq, a } = await team();
		const task = (await a.as('POST', '/v1/tasks', { title: 'talk' })).body.task;
		const post = (body: unknown) => a.as('POST', `/v1/tasks/${task.id}/comments`, body);
		expect((await post({ body: 'x'.repeat(4001) })).status).toBe(400);
		expect((await post({ body: '   ' })).status).toBe(400);
		expect((await post({})).status).toBe(400);
		expect((await post({ body: 'x'.repeat(4000) })).status).toBe(201);
		const insert = hq.hub.db.query(
			"INSERT INTO planning_comments (id, target_kind, target_id, author_id, body, created_at) VALUES ($id, 'task', $task, $author, 'filler', 1)",
		);
		for (let i = 0; i < 999; i++) insert.run({ id: `filler-${i}`, task: task.id, author: a.person.id });
		expect(await post({ body: 'one too many' })).toEqual({ status: 409, body: { error: 'this thread is full' } });
	});

	test('on a task or project that is not there are a 404', async () => {
		const { a } = await team();
		expect((await a.as('GET', '/v1/tasks/ghost/comments')).status).toBe(404);
		expect((await a.as('POST', '/v1/tasks/ghost/comments', { body: 'hi' })).status).toBe(404);
		expect((await a.as('GET', '/v1/projects/ghost/comments')).status).toBe(404);
		expect((await a.as('POST', '/v1/projects/ghost/comments', { body: 'hi' })).status).toBe(404);
	});
});

describe('projects', () => {
	test('the list carries the flags the app checks, and a new project decodes', async () => {
		const { a, b } = await team();
		const empty = await a.as('GET', '/v1/projects');
		expect(empty.body).toEqual({ projects: [], planning: true, project_task_links: true, open_transcripts: true });
		const made = await a.as('POST', '/v1/projects', {
			name: 'Launch',
			body: 'Ship it',
			owner_person_id: b.person.id,
			planning_category: 'Product',
			planning_state: 'Now',
			tags: ['Eng', 'eng', 'Q4'],
		});
		expect(made.status).toBe(201);
		decodes('ProjectEnvelope', made.body);
		expect(made.body.project).toMatchObject({
			name: 'Launch',
			body: 'Ship it',
			owner_person_id: b.person.id,
			owner_name: 'Bo',
			status: 'active',
			open_tasks: 0,
			total_tasks: 0,
			planning_state: 'Now',
			planning_category: 'Product',
			tags: ['Eng', 'Q4'],
			comment_count: 0,
			closed_at: null,
			archived_at: null,
		});
		const plain = await b.as('POST', '/v1/projects', { name: 'Idea', body: null, owner_person_id: b.person.id });
		expect(plain.body.project).toMatchObject({ body: null, planning_state: 'Next', tags: [] });
		const listed = await b.as('GET', '/v1/projects');
		decodes('ProjectsEnvelope', listed.body);
		expect(listed.body.projects.map((p: { name: string }) => p.name)).toEqual(['Launch', 'Idea']);
	});

	test('the category alone files a project under that tag, and a name and sizes are checked', async () => {
		const { a } = await team();
		const made = await a.as('POST', '/v1/projects', {
			name: 'Docs',
			owner_person_id: a.person.id,
			planning_category: 'Marketing',
		});
		expect(made.body.project.tags).toEqual(['Marketing']);
		for (const bad of [
			{ name: '' },
			{ name: 'x'.repeat(121) },
			{ name: 'ok', body: 'x'.repeat(4001) },
			{ name: 'ok', planning_state: 'Soon' },
		]) {
			expect((await a.as('POST', '/v1/projects', { owner_person_id: a.person.id, ...bad })).status).toBe(400);
		}
		expect((await a.as('POST', '/v1/projects', { name: 'ok', owner_person_id: 'ghost' })).status).toBe(400);
		expect((await a.as('POST', '/v1/projects', { name: 'ok', tags: Array.from({ length: 21 }, (_, i) => `t${i}`) })).status).toBe(
			400,
		);
	});

	test('edits: name, description, owner, state, tags, archive and restore', async () => {
		const { a, b } = await team();
		const { id } = (await a.as('POST', '/v1/projects', { name: 'Old', owner_person_id: a.person.id })).body.project;
		const patch = async (body: unknown) => (await b.as('PATCH', `/v1/projects/${id}`, body)).body.project;
		expect(await patch({ name: 'New', body: 'About' })).toMatchObject({ name: 'New', body: 'About' });
		expect(await patch({ owner_person_id: b.person.id, planning_state: 'Backlog' })).toMatchObject({
			owner_person_id: b.person.id,
			owner_name: 'Bo',
			planning_state: 'Backlog',
		});
		expect((await patch({ tags: ['Ops', 'urgent'] })).tags).toEqual(['Ops', 'urgent']);
		const archived = await patch({ archived: true });
		expect(archived.archived_at).toBeTruthy();
		decodes('ProjectEnvelope', { project: archived });
		expect((await patch({ archived: false })).archived_at).toBeNull();
		expect((await b.as('PATCH', `/v1/projects/${id}`, { name: '' })).status).toBe(400);
		expect((await b.as('PATCH', '/v1/projects/ghost', { name: 'x' })).status).toBe(404);
	});

	test('a board with open work cannot be completed; a finished one can, and reopens', async () => {
		const { a } = await team();
		const project = (await a.as('POST', '/v1/projects', { name: 'Ship', owner_person_id: a.person.id })).body.project;
		const task = (await a.as('POST', '/v1/tasks', { title: 'do', project_id: project.id })).body.task;
		const close = () => a.as('PATCH', `/v1/projects/${project.id}`, { status: 'done' });
		expect(await close()).toEqual({ status: 409, body: { error: 'finish or move its open tasks first' } });
		await a.as('PATCH', `/v1/tasks/${task.id}`, { status: 'done' });
		const closed = await close();
		expect(closed.body.project).toMatchObject({ status: 'done', open_tasks: 0, total_tasks: 1 });
		expect(closed.body.project.closed_at).toBeTruthy();
		expect(closed.body.project.last_task_resolved_at).toBeTruthy();
		const reopened = await a.as('PATCH', `/v1/projects/${project.id}`, { status: 'active' });
		expect(reopened.body.project).toMatchObject({ status: 'active', closed_at: null });
	});

	test('a server holds five hundred', async () => {
		const { hq, a } = await team();
		const insert = hq.hub.db.query(
			"INSERT INTO projects (id, name, owner_id, created_by, created_at) VALUES ($id, 'filler', $owner, $owner, 1)",
		);
		for (let i = 0; i < 500; i++) insert.run({ id: `filler-${i}`, owner: a.person.id });
		expect((await a.as('POST', '/v1/projects', { name: 'one more', owner_person_id: a.person.id })).status).toBe(409);

		// Archiving frees a place, and restoring needs one.
		expect((await a.as('PATCH', '/v1/projects/filler-0', { archived: true })).status).toBe(200);
		expect((await a.as('POST', '/v1/projects', { name: 'one more', owner_person_id: a.person.id })).status).toBe(201);
		expect((await a.as('PATCH', '/v1/projects/filler-0', { archived: false })).status).toBe(409);
	});

	test('comments work as they do on a task, and the count rides on the project', async () => {
		const { a, b } = await team();
		const project = (await a.as('POST', '/v1/projects', { name: 'Talk', owner_person_id: a.person.id })).body.project;
		await b.as('POST', `/v1/projects/${project.id}/comments`, { body: 'on the board' });
		const listed = await a.as('GET', `/v1/projects/${project.id}/comments`);
		decodes('CommentsEnvelope', listed.body);
		expect(listed.body.comments).toMatchObject([{ body: 'on the board', author_name: 'Bo' }]);
		expect((await a.as('GET', '/v1/projects')).body.projects[0].comment_count).toBe(1);
	});
});

describe('tasks on projects', () => {
	test('a task joins one board or several, leaves, and the counts follow', async () => {
		const { a } = await team();
		const ids: string[] = [];
		for (const name of ['One', 'Two'])
			ids.push((await a.as('POST', '/v1/projects', { name, owner_person_id: a.person.id })).body.project.id);
		const [one, two] = ids as [string, string];
		const task = (await a.as('POST', '/v1/tasks', { title: 'both', project_id: one })).body.task;
		expect(task).toMatchObject({ project_id: one, project_ids: [one] });
		const both = (await a.as('PATCH', `/v1/tasks/${task.id}`, { project_ids: [two, one] })).body.task;
		expect(both).toMatchObject({ project_id: two, project_ids: [two, one] });
		const counts = async () =>
			(await a.as('GET', '/v1/projects')).body.projects.map((p: { name: string; open_tasks: number; total_tasks: number }) => [
				p.name,
				p.open_tasks,
				p.total_tasks,
			]);
		expect(await counts()).toEqual([
			['One', 1, 1],
			['Two', 1, 1],
		]);
		const moved = (await a.as('PATCH', `/v1/tasks/${task.id}`, { project_id: one })).body.task;
		expect(moved).toMatchObject({ project_id: one, project_ids: [one] });
		expect(await counts()).toEqual([
			['One', 1, 1],
			['Two', 0, 0],
		]);
		await a.as('PATCH', `/v1/tasks/${task.id}`, { status: 'done' });
		expect((await counts())[0]).toEqual(['One', 0, 1]);
		const left = (await a.as('PATCH', `/v1/tasks/${task.id}`, { project_id: null })).body.task;
		expect(left).toMatchObject({ project_id: null, project_ids: [] });
		expect((await a.as('PATCH', `/v1/tasks/${task.id}`, { project_ids: ['ghost'] })).status).toBe(400);
		expect((await a.as('POST', '/v1/tasks', { title: 'x', project_id: 'ghost' })).status).toBe(400);
		// The refused create left no task behind.
		expect((await a.as('GET', '/v1/tasks')).body.tasks).toHaveLength(1);
		expect(
			(await a.as('PATCH', `/v1/tasks/${task.id}`, { project_ids: Array.from({ length: 21 }, (_, i) => `p${i}`) })).status,
		).toBe(400);
	});
});

describe('tasks filed in a room', () => {
	async function filed() {
		const made = await team();
		const { hq, a, b, cy } = made;
		// Ada and Bo are in this room; Cy is not. The assistant files a task there for Bo.
		const secret = hq.hub.conversations.createRoom({ title: 'Comp', createdBy: a.person.id, memberIds: [b.person.id] });
		const ctx = { hub: hq.hub, caller: hq.assistant.self, conversationId: secret.id, viewers: [a.person.id] };
		const added = await hq.registry.call('add_task', { title: 'Raise for Cy', owner_handle: 'bo' }, ctx);
		const id = (added as { value: { id: string } }).value.id;
		await hq.registry.call('add_task', { title: 'Team lunch' }, { hub: hq.hub, caller: hq.assistant.self });
		const asCy = client(hq, hq.hub.keys.mint(cy.id).secret);
		return { ...made, secret, id, asCy };
	}

	test('stay in that room: the others do not see the task, its comments, or a way to reach it', async () => {
		const { a, b, asCy, id, secret } = await filed();
		expect(titles((await a.as('GET', '/v1/tasks')).body)).toEqual(['Raise for Cy', 'Team lunch']);
		expect(titles((await b.as('GET', '/v1/tasks')).body)).toEqual(['Raise for Cy', 'Team lunch']);
		expect(titles((await asCy('GET', '/v1/tasks')).body)).toEqual(['Team lunch']);
		const lunch = (await asCy('GET', '/v1/tasks')).body.tasks[0].id;
		expect((await a.as('POST', `/v1/tasks/${id}/comments`, { body: 'secret raise' })).status).toBe(201);
		expect((await asCy('GET', `/v1/tasks/${id}/comments`)).status).toBe(404);
		expect((await asCy('POST', `/v1/tasks/${id}/comments`, { body: 'hi' })).status).toBe(404);
		expect((await asCy('PATCH', `/v1/tasks/${id}`, { title: 'mine now' })).status).toBe(404);
		expect((await asCy('DELETE', `/v1/tasks/${id}`)).status).toBe(404);
		expect((await asCy('POST', `/v1/tasks/${id}/order`, { before_task_id: lunch })).status).toBe(404);
		expect((await asCy('POST', `/v1/tasks/${lunch}/order`, { before_task_id: id })).status).toBe(404);
		expect((await asCy('PATCH', `/v1/tasks/${lunch}`, { project_ids: [] })).status).toBe(200);
		// Members of the room see where it came from.
		expect((await a.as('GET', '/v1/tasks')).body.tasks[0].origin_conversation_id).toBe(secret.id);
	});

	test('keep their project counts to what the viewer can see', async () => {
		const { hq, a, asCy, id } = await filed();
		const project = (await a.as('POST', '/v1/projects', { name: 'Pay', owner_person_id: a.person.id })).body.project;
		await a.as('PATCH', `/v1/tasks/${id}`, { project_id: project.id });
		const open = async (as: typeof a.as) => (await as('GET', '/v1/projects')).body.projects[0].open_tasks;
		expect(await open(a.as)).toBe(1);
		expect(await open(asCy)).toBe(0);
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM task_projects').get()).toEqual({ n: 1 });
	});

	test('show the owner the task but not the room it came from, and nobody once the room is archived', async () => {
		const { hq, a, b, cy, asCy, id, secret } = await filed();
		// Hand it to Cy, who is not in the room: Cy owns it, so Cy sees it, but not where it came from.
		await a.as('PATCH', `/v1/tasks/${id}`, { owner_person_id: cy.id });
		const seen = (await asCy('GET', '/v1/tasks')).body.tasks.find((t: Wire) => t.id === id);
		expect(seen).toMatchObject({ title: 'Raise for Cy', origin_conversation_id: null });
		decodes('TasksEnvelope', { tasks: [seen] });
		hq.hub.conversations.archive(secret.id);
		expect(titles((await b.as('GET', '/v1/tasks')).body)).toEqual(['Team lunch']);
		expect(titles((await a.as('GET', '/v1/tasks')).body)).toEqual(['Team lunch']);
		expect(titles((await asCy('GET', '/v1/tasks')).body)).toEqual(['Raise for Cy', 'Team lunch']);
	});
});

describe('existing rows', () => {
	test('keep their ids and status and get numbers in the order they were filed', () => {
		const db = openDatabase();
		db.exec('CREATE TABLE people (id TEXT PRIMARY KEY); CREATE TABLE conversations (id TEXT PRIMARY KEY);');
		db.exec("INSERT INTO people (id) VALUES ('ada')");
		migrate(db, migrations.slice(0, 2));
		const insert = db.query(
			`INSERT INTO tasks (id, title, notes, status, owner_id, created_by, due_at, created_at, completed_at)
			VALUES ($id, $id, 'n', $status, $owner, 'ada', NULL, $at, $done)`,
		);
		insert.run({ id: 'late', status: 'open', owner: null, at: 300, done: null });
		insert.run({ id: 'early', status: 'done', owner: 'ada', at: 100, done: 150 });
		insert.run({ id: 'tie-a', status: 'open', owner: null, at: 200, done: null });
		insert.run({ id: 'tie-b', status: 'open', owner: null, at: 200, done: null });
		expect(migrate(db, migrations).length).toBe(migrations.length - 2);
		const rows = db
			.query<Record<string, unknown>, []>(
				'SELECT id, status, owner_id, notes, number, position, progress, hidden_at, touched_at FROM tasks ORDER BY number',
			)
			.all();
		expect(rows).toEqual([
			{
				id: 'early',
				status: 'done',
				owner_id: 'ada',
				notes: 'n',
				number: 1,
				position: 1,
				progress: null,
				hidden_at: null,
				touched_at: 150,
			},
			{
				id: 'tie-a',
				status: 'open',
				owner_id: null,
				notes: 'n',
				number: 2,
				position: 2,
				progress: null,
				hidden_at: null,
				touched_at: 200,
			},
			{
				id: 'tie-b',
				status: 'open',
				owner_id: null,
				notes: 'n',
				number: 3,
				position: 3,
				progress: null,
				hidden_at: null,
				touched_at: 200,
			},
			{
				id: 'late',
				status: 'open',
				owner_id: null,
				notes: 'n',
				number: 4,
				position: 4,
				progress: null,
				hidden_at: null,
				touched_at: 300,
			},
		]);
		// The old rule still holds: only open and done.
		expect(() => db.exec("UPDATE tasks SET status = 'blocked' WHERE id = 'late'")).toThrow();
	});
});

describe('live updates', () => {
	let server: Server<SocketData> | undefined;
	let open: Connection[] = [];
	afterEach(() => {
		for (const connection of open) connection.ws.close();
		open = [];
		void server?.stop(true);
	});

	test('every change sends the whole board, to each person as they may read it', async () => {
		const { hq, a, b, cy } = await team();
		server = serve(hq);
		const [left, right] = [await connect(server, a.bearer), await connect(server, b.bearer)];
		const third = await connect(server, (await enrolled(hq, hq.hub.keys.mint(cy.id).secret, 'Cy Mac')).bearer);
		open.push(left, right, third);

		const made = (await a.as('POST', '/v1/tasks', { title: 'shared' })).body.task;
		for (const connection of [left, right, third]) {
			const frame = await connection.take('tasks', (f) => f.tasks.length === 1);
			expect(shape('TasksPayload', frame)).toEqual([]);
			expect(frame.tasks[0].title).toBe('shared');
		}

		// A task filed in a room reaches the room's members and no one else.
		const room = hq.hub.conversations.createRoom({ title: 'Comp', createdBy: a.person.id, memberIds: [b.person.id] });
		await hq.registry.call(
			'add_task',
			{ title: 'private' },
			{ hub: hq.hub, caller: hq.assistant.self, conversationId: room.id, viewers: [a.person.id, b.person.id] },
		);
		await left.take('tasks', (f) => f.tasks.length === 2);
		const seenByB = await right.take('tasks', (f) => f.tasks.length === 2);
		expect(seenByB.tasks.map((t: Wire) => t.title)).toEqual(['shared', 'private']);
		await third.settle();
		await Bun.sleep(250);
		await third.settle();
		expect(third.frames.filter((f) => f.type === 'tasks').every((f) => f.tasks.length === 1)).toBe(true);

		// A comment, a project and a move are changes too (the count and the project list ride on the frame).
		await b.as('POST', `/v1/tasks/${made.id}/comments`, { body: 'hello' });
		expect((await left.take('tasks', (f) => f.tasks.some((t: Wire) => t.comment_count === 1))).type).toBe('tasks');
		const before = left.frames.filter((f) => f.type === 'tasks').length;
		await a.as('POST', '/v1/projects', { name: 'New board', owner_person_id: a.person.id });
		await left.take('tasks', () => left.frames.filter((f) => f.type === 'tasks').length > before);
	});

	test('a burst of changes is one frame', async () => {
		const { hq, a } = await team();
		server = serve(hq);
		const left = await connect(server, a.bearer);
		open.push(left);
		for (let i = 0; i < 5; i++) hq.hub.bus.emit({ type: 'app.event', app: 'tasks', name: 'changed', data: {} });
		await left.take('tasks');
		await Bun.sleep(250);
		await left.settle();
		expect(left.frames.filter((f) => f.type === 'tasks')).toHaveLength(1);
	});

	test('a coding session checking in changes no task and sends no board', async () => {
		const { hq, a } = await team();
		server = serve(hq);
		const left = await connect(server, a.bearer);
		open.push(left);
		hq.hub.bus.emit({ type: 'app.event', app: 'tasks', name: 'changed', data: { session_id: 'some-session' } });
		await Bun.sleep(250);
		await left.settle();
		expect(left.frames.some((f) => f.type === 'tasks')).toBe(false);
	});

	test('a board frame stops short of what the app can read, cutting the tail', () => {
		const tasks = Array.from({ length: 10 }, (_, i) => ({ id: `t${i}`, body: 'x'.repeat(100) }));
		const kept = withinFrame(tasks, 500);
		expect(kept.map((t) => t.id)).toEqual(['t0', 't1', 't2', 't3']);
		expect(Buffer.byteLength(JSON.stringify(kept))).toBeLessThanOrEqual(500);
		expect(withinFrame(tasks)).toHaveLength(10);
	});

	test('a removed person is sent nothing', async () => {
		const { hq, a, b } = await team();
		server = serve(hq);
		const [left, right] = [await connect(server, a.bearer), await connect(server, b.bearer)];
		open.push(left, right);
		hq.hub.people.setRemoved(b.person.id, Date.now());
		await a.as('POST', '/v1/tasks', { title: 'after' });
		await left.take('tasks');
		await Bun.sleep(250);
		await right.settle();
		expect(right.frames.some((f) => f.type === 'tasks')).toBe(false);
	});
});
