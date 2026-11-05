import { HttpError, json, newId, now, readBody, z, type AppRoute, type Hub, type Person } from '@hq/sdk';
import { Tasks, VISIBLE, type Task } from './store';

// The board the native app draws: tasks, projects and their comments, under `/v1`. Everything is a team board, so any member
// reads and edits any of it, except a task filed in a room the member is not in (see `VISIBLE`).

/** What one board answer or socket frame holds: every open task, and the newest finished ones. */
const MAX_OPEN = 2000;
const MAX_DONE = 300;
const MAX_PROJECTS = 500;
const MAX_COMMENTS = 1000;
const LISTED_COMMENTS = 500;

const TASK_BODY = 256 * 1024;
const COMMENT_BODY = 64 * 1024;

type Status = 'open' | 'in_progress' | 'blocked' | 'done';

type Project = {
	id: string;
	name: string;
	body: string | null;
	owner_id: string;
	status: 'active' | 'done';
	planning_state: 'Now' | 'Next' | 'Backlog';
	planning_category: string | null;
	tags: string;
	created_by: string;
	created_at: number;
	closed_at: number | null;
	archived_at: number | null;
};

type Comment = { id: string; author_id: string; body: string; created_at: number };

const iso = (ms: number) => new Date(ms).toISOString();
const optionalIso = (ms: number | null) => (ms === null ? null : iso(ms));
const statusOf = (task: Task): Status => (task.status === 'done' ? 'done' : (task.progress ?? 'open'));

// Limits are twice what the app lets a person type: the app counts characters and these count UTF-16 units.
const text = (max: number) => z.string().max(max);
const id = z.string().min(1).max(64);
const tags = z
	.array(z.string().trim().min(1).max(80))
	.max(20)
	// The same tag in another case is the first one.
	.transform((list) => list.filter((tag, i) => list.findIndex((other) => other.toLowerCase() === tag.toLowerCase()) === i));
const dueAt = z
	.string()
	.max(40)
	.refine((value) => Number.isFinite(Date.parse(value)), 'must be an ISO date and time');
const noRecurrence = z.null().optional().describe('Repeating tasks are not supported by this server.');

const createTask = z.object({
	title: z.string().trim().min(1).max(400),
	body: text(16_000).nullish(),
	owner_person_id: id.optional(),
	project_id: id.nullish(),
	due_at: dueAt.nullish(),
	recurrence: noRecurrence,
});

const patchTask = z.object({
	title: z.string().trim().min(1).max(400).optional(),
	body: text(16_000).nullable().optional(),
	status: z.enum(['open', 'in_progress', 'blocked', 'done']).optional(),
	owner_person_id: id.optional(),
	due_at: dueAt.nullable().optional(),
	project_id: id.nullable().optional(),
	project_ids: z.array(id).max(20).optional(),
	recurrence: noRecurrence,
});

const projectState = z.enum(['Now', 'Next', 'Backlog']);

const createProject = z.object({
	name: z.string().trim().min(1).max(120),
	body: text(4000).nullish(),
	owner_person_id: id.optional(),
	planning_category: text(80).nullish(),
	planning_state: projectState.optional(),
	tags: tags.optional(),
});

const patchProject = z.object({
	name: z.string().trim().min(1).max(120).optional(),
	body: text(4000).nullable().optional(),
	status: z.enum(['active', 'done']).optional(),
	owner_person_id: id.optional(),
	planning_category: text(80).nullable().optional(),
	planning_state: projectState.optional(),
	tags: tags.optional(),
	archived: z.boolean().optional(),
});

const order = z
	.object({ before_task_id: id.optional(), after_task_id: id.optional() })
	.refine(
		(value) => (value.before_task_id === undefined) !== (value.after_task_id === undefined),
		'give before_task_id or after_task_id',
	);

const commentBody = z.object({ body: z.string().trim().min(1).max(4000) });

// People

function member(hub: Hub, personId: string): Person {
	const person = hub.people.get(personId);
	if (person === null || person.removed_at !== null) throw new HttpError(400, 'no such person');
	return person;
}

// Tasks

function find(hub: Hub, taskId: string | undefined, viewer: string): Task {
	const store = new Tasks(hub);
	const task = store.get(taskId ?? '');
	if (task === null || !store.visibleTo(task, [viewer])) throw new HttpError(404, 'task not found');
	return task;
}

/** What `viewer` can see of the board, in board order: every open task and the newest finished ones. */
function boardRows(hub: Hub, viewer: string): Task[] {
	const seen = JSON.stringify([viewer]);
	const base = `SELECT * FROM tasks WHERE hidden_at IS NULL AND ${VISIBLE}`;
	const open = hub.db
		.query<Task, { seen: string }>(`${base} AND status != 'done' ORDER BY position, number LIMIT ${MAX_OPEN}`)
		.all({ seen });
	const done = hub.db
		.query<Task, { seen: string }>(`${base} AND status = 'done' ORDER BY completed_at DESC LIMIT ${MAX_DONE}`)
		.all({ seen });
	return [...open, ...done].sort((a, b) => a.position - b.position || (a.number ?? 0) - (b.number ?? 0));
}

/** Projects that count toward the cap: archiving one frees its place. */
function liveProjects(hub: Hub): number {
	return hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM projects WHERE archived_at IS NULL').get()!.n;
}

function counts(hub: Hub, kind: 'task' | 'project', ids: string[]): Map<string, number> {
	if (ids.length === 0) return new Map();
	return new Map(
		hub.db
			.query<{ target_id: string; n: number }, { kind: string; ids: string }>(
				`SELECT target_id, COUNT(*) AS n FROM planning_comments
				WHERE target_kind = $kind AND target_id IN (SELECT value FROM json_each($ids)) GROUP BY target_id`,
			)
			.all({ kind, ids: JSON.stringify(ids) })
			.map((row) => [row.target_id, row.n]),
	);
}

function present(hub: Hub, viewer: string, tasks: Task[]) {
	const people = hub.people.byIds(
		tasks.flatMap((t) => [t.created_by, t.owner_id ?? t.created_by, ...(t.completed_by ? [t.completed_by] : [])]),
	);
	const ids = tasks.map((t) => t.id);
	const links = new Map<string, string[]>();
	const rows =
		ids.length === 0
			? []
			: hub.db
					.query<{ task_id: string; project_id: string }, { ids: string }>(
						`SELECT task_id, project_id FROM task_projects WHERE task_id IN (SELECT value FROM json_each($ids)) ORDER BY ordinal`,
					)
					.all({ ids: JSON.stringify(ids) });
	for (const row of rows) links.set(row.task_id, [...(links.get(row.task_id) ?? []), row.project_id]);
	const comments = counts(hub, 'task', ids);
	const rooms = new Map<string, boolean>();
	const inRoom = (room: string) => {
		if (!rooms.has(room)) rooms.set(room, hub.conversations.isMember(room, viewer));
		return rooms.get(room)!;
	};
	return tasks.map((task) => {
		// The app needs an owner on every task; one nobody took belongs, on the board, to whoever filed it.
		const ownerId = task.owner_id ?? task.created_by;
		const projects = links.get(task.id) ?? [];
		return {
			id: task.id,
			number: task.number,
			title: task.title,
			body: task.notes === '' ? null : task.notes,
			status: statusOf(task),
			owner_person_id: ownerId,
			owner_name: people.get(ownerId)?.name ?? 'Someone',
			due_at: optionalIso(task.due_at),
			// Only someone who can see the room sees that the task came from it.
			origin_conversation_id: task.conversation_id !== null && inRoom(task.conversation_id) ? task.conversation_id : null,
			created_by_person_id: task.created_by,
			created_at: iso(task.created_at),
			resolved_by_person_id: task.status === 'done' ? (task.completed_by ?? ownerId) : null,
			resolved_at: optionalIso(task.completed_at),
			project_id: projects[0] ?? null,
			project_ids: projects,
			touched_at: iso(task.touched_at),
			comment_count: comments.get(task.id) ?? 0,
		};
	});
}

const board = (hub: Hub, viewer: string) => present(hub, viewer, boardRows(hub, viewer));

/** Replaces a task's boards. The first is its main one. */
function link(hub: Hub, taskId: string, projectIds: string[]): void {
	const unique = [...new Set(projectIds)];
	for (const projectId of unique) if (project(hub, projectId) === null) throw new HttpError(400, 'no such project');
	hub.db.query('DELETE FROM task_projects WHERE task_id = $task').run({ task: taskId });
	const insert = hub.db.query('INSERT INTO task_projects (task_id, project_id, ordinal) VALUES ($task, $project, $ordinal)');
	unique.forEach((projectId, ordinal) => insert.run({ task: taskId, project: projectId, ordinal }));
}

function linked(hub: Hub, taskId: string): string[] {
	return hub.db
		.query<{ project_id: string }, { task: string }>(
			'SELECT project_id FROM task_projects WHERE task_id = $task ORDER BY ordinal',
		)
		.all({ task: taskId })
		.map((row) => row.project_id);
}

/** Puts `taskId` next to `anchorId` in board order, between that task and its neighbour. */
function place(hub: Hub, taskId: string, anchorId: string, after: boolean): void {
	const rest = hub.db
		.query<{ id: string; position: number }, []>(
			'SELECT id, position FROM tasks WHERE hidden_at IS NULL ORDER BY position, number',
		)
		.all()
		.filter((row) => row.id !== taskId);
	const at = rest.findIndex((row) => row.id === anchorId);
	const anchor = rest[at]!;
	const neighbour = rest[after ? at + 1 : at - 1];
	const write = (target: string, position: number): void => {
		hub.db.query('UPDATE tasks SET position = $position WHERE id = $id').run({ id: target, position });
	};
	if (neighbour === undefined) write(taskId, anchor.position + (after ? 1 : -1));
	else if (Math.abs(neighbour.position - anchor.position) > 1e-6) write(taskId, (anchor.position + neighbour.position) / 2);
	else {
		// Halving runs out of precision after a long run of moves into one gap: number the whole board again.
		rest.splice(after ? at + 1 : at, 0, { id: taskId, position: 0 });
		rest.forEach((row, index) => write(row.id, index + 1));
	}
}

// Projects

const PROJECT_COLUMNS =
	'id, name, body, owner_id, status, planning_state, planning_category, tags, created_by, created_at, closed_at, archived_at';

function project(hub: Hub, projectId: string | undefined): Project | null {
	return hub.db
		.query<Project, { id: string }>(`SELECT ${PROJECT_COLUMNS} FROM projects WHERE id = $id`)
		.get({ id: projectId ?? '' });
}

/** The projects as `viewer` sees them: the counts leave out tasks they cannot see. */
function presentProjects(hub: Hub, viewer: string, projects: Project[]) {
	const stats = new Map(
		hub.db
			.query<{ id: string; total: number; open: number; last: number | null }, { seen: string }>(
				`SELECT task_projects.project_id AS id, COUNT(*) AS total, SUM(tasks.status != 'done') AS open, MAX(tasks.completed_at) AS last
				FROM task_projects JOIN tasks ON tasks.id = task_projects.task_id
				WHERE tasks.hidden_at IS NULL AND ${VISIBLE} GROUP BY task_projects.project_id`,
			)
			.all({ seen: JSON.stringify([viewer]) })
			.map((row) => [row.id, row]),
	);
	const people = hub.people.byIds(projects.map((p) => p.owner_id));
	const comments = counts(
		hub,
		'project',
		projects.map((p) => p.id),
	);
	return projects.map((p) => ({
		id: p.id,
		name: p.name,
		body: p.body,
		owner_person_id: p.owner_id,
		owner_name: people.get(p.owner_id)?.name ?? 'Someone',
		status: p.status,
		open_tasks: stats.get(p.id)?.open ?? 0,
		total_tasks: stats.get(p.id)?.total ?? 0,
		last_task_resolved_at: optionalIso(stats.get(p.id)?.last ?? null),
		created_at: iso(p.created_at),
		closed_at: optionalIso(p.closed_at),
		archived_at: optionalIso(p.archived_at),
		planning_category: p.planning_category,
		planning_state: p.planning_state,
		tags: JSON.parse(p.tags) as string[],
		comment_count: comments.get(p.id) ?? 0,
	}));
}

const projectsFor = (hub: Hub, viewer: string) =>
	presentProjects(
		hub,
		viewer,
		hub.db.query<Project, []>(`SELECT ${PROJECT_COLUMNS} FROM projects ORDER BY created_at, id`).all(),
	);

function foundProject(hub: Hub, projectId: string | undefined): Project {
	const found = project(hub, projectId);
	if (found === null) throw new HttpError(404, 'project not found');
	return found;
}

// Comments

function commentsOf(hub: Hub, kind: 'task' | 'project', targetId: string) {
	const rows = hub.db
		.query<Comment, { kind: string; target: string }>(
			`SELECT id, author_id, body, created_at FROM planning_comments WHERE target_kind = $kind AND target_id = $target
			ORDER BY created_at DESC, rowid DESC LIMIT ${LISTED_COMMENTS}`,
		)
		.all({ kind, target: targetId })
		.reverse();
	return presentComments(hub, rows);
}

function presentComments(hub: Hub, rows: Comment[]) {
	const people = hub.people.byIds(rows.map((row) => row.author_id));
	return rows.map((row) => ({
		id: row.id,
		author_person_id: row.author_id,
		author_name: people.get(row.author_id)?.name ?? 'Someone',
		body: row.body,
		created_at: iso(row.created_at),
	}));
}

function addComment(hub: Hub, kind: 'task' | 'project', targetId: string, author: Person, body: string) {
	const held = hub.db
		.query<{ n: number }, { kind: string; target: string }>(
			'SELECT COUNT(*) AS n FROM planning_comments WHERE target_kind = $kind AND target_id = $target',
		)
		.get({ kind, target: targetId })!.n;
	if (held >= MAX_COMMENTS) throw new HttpError(409, 'this thread is full');
	const row: Comment = { id: newId(), author_id: author.id, body, created_at: now() };
	hub.db
		.query(
			`INSERT INTO planning_comments (id, target_kind, target_id, author_id, body, created_at)
			VALUES ($id, $kind, $target, $author, $body, $at)`,
		)
		.run({ id: row.id, kind, target: targetId, author: author.id, body, at: row.created_at });
	return presentComments(hub, [row])[0]!;
}

// Live updates. The app keeps the board it last heard in a `tasks` frame (the whole board) and reads the projects again when
// one arrives, so every change to a task, a project or a comment sends it.

const waiting = new WeakMap<Hub, ReturnType<typeof setTimeout>>();

/** Tells everyone connected that the board changed. A burst of changes (a drag, an import) is one frame each. */
export function boardChanged(hub: Hub): void {
	if (waiting.has(hub)) return;
	const timer = setTimeout(() => {
		waiting.delete(hub);
		try {
			sendBoards(hub);
		} catch (error) {
			console.error('[tasks] could not send the board', error);
		}
	}, 100);
	timer.unref?.();
	waiting.set(hub, timer);
}

/**
 * Each person gets the board they could read. Only tasks filed in a room differ between people, so people who see the same
 * of those (and the same room links) share one frame.
 */
function sendBoards(hub: Hub): void {
	const people = hub.db
		.query<{ id: string }, []>("SELECT id FROM people WHERE kind = 'human' AND removed_at IS NULL ORDER BY created_at")
		.all();
	const rooms = hub.db
		.query<{ id: string; owner_id: string | null; conversation_id: string }, []>(
			'SELECT id, owner_id, conversation_id FROM tasks WHERE hidden_at IS NULL AND conversation_id IS NOT NULL',
		)
		.all();
	const members = new Map<string, Set<string>>();
	for (const { conversation_id } of rooms)
		if (!members.has(conversation_id)) members.set(conversation_id, new Set(hub.conversations.memberIds(conversation_id)));
	const groups = new Map<string, string[]>();
	for (const { id: personId } of people) {
		const view = rooms
			.flatMap((task) => {
				const inRoom = members.get(task.conversation_id)!.has(personId);
				return inRoom || task.owner_id === personId ? [`${task.id}${inRoom ? 'm' : 'o'}`] : [];
			})
			.join(',');
		groups.set(view, [...(groups.get(view) ?? []), personId]);
	}
	for (const audience of groups.values()) {
		hub.bus.emit({ type: 'frame', audience, frame: { type: 'tasks', tasks: withinFrame(board(hub, audience[0]!)) } });
	}
}

/** The app drops any socket message over 16 MiB and reconnects, so a board frame stops at half that, cutting its tail. */
const MAX_FRAME_BYTES = 8 * 1024 * 1024;

export function withinFrame<T>(tasks: T[], limit = MAX_FRAME_BYTES): T[] {
	let bytes = 2;
	const kept: T[] = [];
	for (const task of tasks) {
		bytes += Buffer.byteLength(JSON.stringify(task)) + 1;
		if (bytes > limit) break;
		kept.push(task);
	}
	return kept;
}

// Routes

const v1 = { mount: 'v1' } as const;

export const planningRoutes: AppRoute[] = [
	{
		...v1,
		method: 'GET',
		path: '/v1/tasks',
		handler: ({ hub, person }) => ({ tasks: board(hub, person.id) }),
	},
	{
		...v1,
		method: 'POST',
		path: '/v1/tasks',
		maxBodyBytes: TASK_BODY,
		handler: async ({ hub, req, person }) => {
			const body = await readBody(req, createTask);
			const owner = body.owner_person_id === undefined ? person : member(hub, body.owner_person_id);
			const created = hub.db.transaction(() => {
				const task = new Tasks(hub).add({
					title: body.title,
					notes: body.body ?? '',
					ownerId: owner.id,
					createdBy: person.id,
					dueAt: body.due_at == null ? null : Date.parse(body.due_at),
				});
				if (body.project_id != null) link(hub, task.id, [body.project_id]);
				return task;
			})();
			boardChanged(hub);
			return json({ task: present(hub, person.id, [created])[0] }, 201);
		},
	},
	{
		...v1,
		method: 'PATCH',
		path: '/v1/tasks/:id',
		maxBodyBytes: TASK_BODY,
		handler: async ({ hub, req, params, person }) => {
			const body = await readBody(req, patchTask);
			const task = find(hub, params.id, person.id);
			const owner = body.owner_person_id === undefined ? null : member(hub, body.owner_person_id);
			const updated = hub.db.transaction(() => {
				const status = body.status;
				const next = new Tasks(hub).update(
					task.id,
					{
						...(body.title === undefined ? {} : { title: body.title }),
						...(body.body === undefined ? {} : { notes: body.body ?? '' }),
						...(owner === null ? {} : { owner_id: owner.id }),
						...(body.due_at === undefined ? {} : { due_at: body.due_at === null ? null : Date.parse(body.due_at) }),
						...(status === undefined
							? {}
							: {
									status: status === 'done' ? ('done' as const) : ('open' as const),
									progress: status === 'in_progress' || status === 'blocked' ? status : null,
								}),
					},
					person.id,
				)!;
				const boards =
					body.project_ids ?? (body.project_id === undefined ? undefined : body.project_id === null ? [] : [body.project_id]);
				if (boards !== undefined && boards.join() !== linked(hub, task.id).join()) {
					link(hub, task.id, boards);
					hub.db.query('UPDATE tasks SET touched_at = $at WHERE id = $id').run({ id: task.id, at: now() });
				}
				return new Tasks(hub).get(next.id)!;
			})();
			boardChanged(hub);
			return { task: present(hub, person.id, [updated])[0] };
		},
	},
	{
		...v1,
		method: 'DELETE',
		path: '/v1/tasks/:id',
		handler: ({ hub, params, person }) => {
			const task = find(hub, params.id, person.id);
			// What the app offers: the person it is for, whoever filed it, or an admin. The row stays (and keeps its number).
			if (person.role !== 'admin' && person.id !== task.owner_id && person.id !== task.created_by) {
				throw new HttpError(403, 'only its owner, whoever filed it or an admin can delete a task');
			}
			hub.db.query('UPDATE tasks SET hidden_at = $at WHERE id = $id').run({ id: task.id, at: now() });
			boardChanged(hub);
			return { ok: true };
		},
	},
	{
		...v1,
		method: 'POST',
		path: '/v1/tasks/:id/order',
		maxBodyBytes: 4096,
		handler: async ({ hub, req, params, person }) => {
			const body = await readBody(req, order);
			const task = find(hub, params.id, person.id);
			const anchorId = body.before_task_id ?? body.after_task_id!;
			if (anchorId === task.id) throw new HttpError(400, 'a task cannot be placed next to itself');
			find(hub, anchorId, person.id);
			hub.db.transaction(() => place(hub, task.id, anchorId, body.after_task_id !== undefined))();
			boardChanged(hub);
			return { tasks: board(hub, person.id) };
		},
	},
	{
		...v1,
		method: 'GET',
		path: '/v1/tasks/:id/comments',
		handler: ({ hub, params, person }) => ({ comments: commentsOf(hub, 'task', find(hub, params.id, person.id).id) }),
	},
	{
		...v1,
		method: 'POST',
		path: '/v1/tasks/:id/comments',
		maxBodyBytes: COMMENT_BODY,
		handler: async ({ hub, req, params, person }) => {
			const { body } = await readBody(req, commentBody);
			const task = find(hub, params.id, person.id);
			const comment = addComment(hub, 'task', task.id, person, body);
			boardChanged(hub);
			return json({ comment }, 201);
		},
	},
	{
		...v1,
		method: 'GET',
		path: '/v1/projects',
		// The flags are what the app checks before it writes: planning fields, tasks on several projects, and whether any member
		// may open a synced coding session (they may: see docs/sessions.md).
		handler: ({ hub, person }) => ({
			projects: projectsFor(hub, person.id),
			planning: true,
			project_task_links: true,
			open_transcripts: true,
		}),
	},
	{
		...v1,
		method: 'POST',
		path: '/v1/projects',
		maxBodyBytes: TASK_BODY,
		handler: async ({ hub, req, person }) => {
			const body = await readBody(req, createProject);
			const owner = body.owner_person_id === undefined ? person : member(hub, body.owner_person_id);
			if (liveProjects(hub) >= MAX_PROJECTS) throw new HttpError(409, 'this server holds as many projects as it allows');
			const row: Project = {
				id: newId(),
				name: body.name,
				body: body.body ?? null,
				owner_id: owner.id,
				status: 'active',
				planning_state: body.planning_state ?? 'Next',
				planning_category: body.planning_category ?? null,
				tags: JSON.stringify(body.tags ?? (body.planning_category ? [body.planning_category] : [])),
				created_by: person.id,
				created_at: now(),
				closed_at: null,
				archived_at: null,
			};
			hub.db
				.query(
					`INSERT INTO projects (${PROJECT_COLUMNS}) VALUES ($id, $name, $body, $owner_id, $status, $planning_state,
					$planning_category, $tags, $created_by, $created_at, $closed_at, $archived_at)`,
				)
				.run({ ...row });
			boardChanged(hub);
			return json({ project: presentProjects(hub, person.id, [row])[0] }, 201);
		},
	},
	{
		...v1,
		method: 'PATCH',
		path: '/v1/projects/:id',
		maxBodyBytes: TASK_BODY,
		handler: async ({ hub, req, params, person }) => {
			const body = await readBody(req, patchProject);
			const current = foundProject(hub, params.id);
			const owner = body.owner_person_id === undefined ? null : member(hub, body.owner_person_id);
			const at = now();
			const next: Project = {
				...current,
				...(body.name === undefined ? {} : { name: body.name }),
				...(body.body === undefined ? {} : { body: body.body }),
				...(owner === null ? {} : { owner_id: owner.id }),
				...(body.planning_category === undefined ? {} : { planning_category: body.planning_category }),
				...(body.planning_state === undefined ? {} : { planning_state: body.planning_state }),
				...(body.tags === undefined ? {} : { tags: JSON.stringify(body.tags) }),
			};
			if (body.status !== undefined && body.status !== current.status) {
				if (body.status === 'done') {
					// Counts every open task, seen or not: a board with work left on it is not finished.
					const open = hub.db
						.query<{ n: number }, { id: string }>(
							`SELECT COUNT(*) AS n FROM task_projects JOIN tasks ON tasks.id = task_projects.task_id
							WHERE task_projects.project_id = $id AND tasks.hidden_at IS NULL AND tasks.status != 'done'`,
						)
						.get({ id: current.id })!.n;
					if (open > 0) throw new HttpError(409, 'finish or move its open tasks first');
				}
				next.status = body.status;
				next.closed_at = body.status === 'done' ? at : null;
			}
			if (body.archived !== undefined) next.archived_at = body.archived ? (current.archived_at ?? at) : null;
			if (current.archived_at !== null && next.archived_at === null && liveProjects(hub) >= MAX_PROJECTS)
				throw new HttpError(409, 'this server holds as many projects as it allows');
			hub.db
				.query(
					`UPDATE projects SET name = $name, body = $body, owner_id = $owner_id, status = $status, planning_state = $planning_state,
					planning_category = $planning_category, tags = $tags, closed_at = $closed_at, archived_at = $archived_at WHERE id = $id`,
				)
				.run({
					id: next.id,
					name: next.name,
					body: next.body,
					owner_id: next.owner_id,
					status: next.status,
					planning_state: next.planning_state,
					planning_category: next.planning_category,
					tags: next.tags,
					closed_at: next.closed_at,
					archived_at: next.archived_at,
				});
			boardChanged(hub);
			return { project: presentProjects(hub, person.id, [next])[0] };
		},
	},
	{
		...v1,
		method: 'GET',
		path: '/v1/projects/:id/comments',
		handler: ({ hub, params }) => ({ comments: commentsOf(hub, 'project', foundProject(hub, params.id).id) }),
	},
	{
		...v1,
		method: 'POST',
		path: '/v1/projects/:id/comments',
		maxBodyBytes: COMMENT_BODY,
		handler: async ({ hub, req, params, person }) => {
			const { body } = await readBody(req, commentBody);
			const found = foundProject(hub, params.id);
			const comment = addComment(hub, 'project', found.id, person, body);
			boardChanged(hub);
			return json({ comment }, 201);
		},
	},
];
