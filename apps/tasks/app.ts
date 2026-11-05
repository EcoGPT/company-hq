import {
	defaultTimezone,
	defineApp,
	defineTool,
	HttpError,
	type Hub,
	type Person,
	personByHandle,
	readBody,
	resolveDay,
	ToolError,
	z,
} from '@hq/sdk';
import { boardChanged, planningRoutes } from './planning';
import { sessionRoutes, sessionTools } from './sessions';
import { migrations, Tasks, VISIBLE, type Task } from './store';
import { transcriptRoutes } from './transcripts';

const personId = (hub: Hub, handle: string | null | undefined): string | null =>
	handle === undefined || handle === null || handle === '' ? null : personByHandle(hub, handle).id;

const owners = (hub: Hub, tasks: Task[]) => hub.people.byIds(tasks.flatMap((t) => (t.owner_id === null ? [] : [t.owner_id])));

function present(hub: Hub, task: Task, people: Map<string, Person> = owners(hub, [task])) {
	const owner = task.owner_id === null ? undefined : people.get(task.owner_id);
	return {
		id: task.id,
		title: task.title,
		notes: task.notes,
		status: task.status,
		owner: owner === undefined ? null : `@${owner.handle}`,
		due: task.due_at === null ? null : new Date(task.due_at).toISOString().slice(0, 10),
	};
}

function presentAll(hub: Hub, tasks: Task[]) {
	const people = owners(hub, tasks);
	return tasks.map((task) => present(hub, task, people));
}

function changed(hub: Hub, task: Task): Task {
	hub.bus.emit({ type: 'app.event', app: 'tasks', name: 'changed', data: { id: task.id } });
	return task;
}

const due = z
	.string()
	.optional()
	.describe('Due date: YYYY-MM-DD, or today, tomorrow, a weekday like "friday", or "in 3 days". Pass the words the person used.');

function dueAt(text: string, timezone = defaultTimezone()): number {
	const day = resolveDay(text, timezone);
	if (day === null) throw new ToolError(`could not read the due date "${text}": use YYYY-MM-DD`);
	return Date.parse(`${day}T00:00:00Z`);
}

// What the Mac widgets show: the person's own tasks, with a task nobody took counted as its filer's (as the board does), and
// only those they may see (`VISIBLE`). Capped at five per status.
const WIDGET_ROWS = 5;
const WEEK_MS = 7 * 86_400_000;

function widgetWork(hub: Hub, person: Person) {
	const iso = (ms: number) => new Date(ms).toISOString();
	const mine = `tasks.hidden_at IS NULL AND COALESCE(tasks.owner_id, tasks.created_by) = $me AND ${VISIBLE}`;
	const args = { me: person.id, seen: JSON.stringify([person.id]) };
	const state = "COALESCE(tasks.progress, 'open')";
	const owed = `${mine} AND tasks.status != 'done'`;
	const count = (where: string, extra: Record<string, string | number> = {}) =>
		hub.db
			.query<{ n: number }, Record<string, string | number>>(`SELECT COUNT(*) AS n FROM tasks WHERE ${where}`)
			.get({ ...args, ...extra })!.n;
	const rows = (where: string, order: string, extra: Record<string, string | number> = {}) =>
		hub.db
			.query<Task, Record<string, string | number>>(`SELECT * FROM tasks WHERE ${where} ORDER BY ${order} LIMIT ${WIDGET_ROWS}`)
			.all({ ...args, ...extra });
	const stateOf = (task: Task): 'open' | 'in_progress' | 'blocked' => task.progress ?? 'open';
	const picked = (['in_progress', 'blocked', 'open'] as const).flatMap((status) =>
		rows(
			`${owed} AND ${state} = $state`,
			status === 'open' ? 'COALESCE(tasks.due_at, 9e15), tasks.touched_at DESC' : 'tasks.touched_at DESC',
			{ state: status },
		),
	);
	const nextDue = rows(`${owed} AND tasks.due_at IS NOT NULL`, 'tasks.due_at, tasks.number')[0];
	const ids = JSON.stringify([...new Set([...picked, ...(nextDue === undefined ? [] : [nextDue])].map((task) => task.id))]);
	// A task's first board labels its card: the map keeps the last row per task, so the rows run last board first.
	const projects = new Map(
		hub.db
			.query<{ task_id: string; name: string }, { ids: string }>(
				`SELECT task_projects.task_id, projects.name FROM task_projects JOIN projects ON projects.id = task_projects.project_id
				WHERE task_projects.task_id IN (SELECT value FROM json_each($ids)) ORDER BY task_projects.ordinal DESC`,
			)
			.all({ ids })
			.map((row) => [row.task_id, row.name]),
	);
	const comments = new Map(
		hub.db
			.query<{ target_id: string; n: number }, { ids: string }>(
				`SELECT target_id, COUNT(*) AS n FROM planning_comments
				WHERE target_kind = 'task' AND target_id IN (SELECT value FROM json_each($ids)) GROUP BY target_id`,
			)
			.all({ ids })
			.map((row) => [row.target_id, row.n]),
	);
	const card = (task: Task) => ({
		id: task.id,
		number: task.number,
		ref: task.number === null ? null : `HQ-${task.number}`,
		title: task.title,
		status: stateOf(task),
		project_name: projects.get(task.id) ?? null,
		comment_count: comments.get(task.id) ?? 0,
		due_at: task.due_at === null ? null : iso(task.due_at),
		touched_at: iso(task.touched_at),
	});
	return {
		in_progress: count(`${owed} AND ${state} = 'in_progress'`),
		open: count(`${owed} AND ${state} = 'open'`),
		blocked: count(`${owed} AND ${state} = 'blocked'`),
		done_week: count(`${mine} AND tasks.status = 'done' AND tasks.completed_at >= $since`, { since: Date.now() - WEEK_MS }),
		next_due: nextDue === undefined ? null : card(nextDue),
		tasks: picked.map(card),
	};
}

export default defineApp({
	slug: 'tasks',
	name: 'Tasks',
	description: "The team's shared to-do list.",
	icon: '✓',
	briefing:
		'Tasks are the durable handoff. When someone asks you to track a follow-up, or a thread ends with work owed, file it with add_task: a tight title and the right owner. Complete or reassign when asked.',
	migrations,
	widgetWork: (app, person) => widgetWork(app.hub, person),
	// Whoever changes a task (the assistant, an agent, the page) tells the app's board, which keeps the last one it was sent.
	// A coding session's check-in changes no task, so it sends no board.
	setup: (app) =>
		app.hub.bus.on((event) => {
			if (event.type !== 'app.event' || event.app !== 'tasks' || event.name !== 'changed') return;
			if (typeof event.data === 'object' && event.data !== null && 'session_id' in event.data) return;
			boardChanged(app.hub);
		}),
	tools: [
		defineTool({
			name: 'add_task',
			description: 'File a task. Links it to the current conversation.',
			input: z.object({
				title: z.string().min(1).max(200),
				notes: z.string().max(4000).optional(),
				owner_handle: z.string().optional(),
				due,
			}),
			activity: 'Filing a task',
			run: (input, { hub, caller, conversationId, timezone }) => {
				const task = new Tasks(hub).add({
					title: input.title,
					notes: input.notes,
					ownerId: personId(hub, input.owner_handle),
					createdBy: caller.id,
					conversationId,
					dueAt: input.due === undefined ? null : dueAt(input.due, timezone),
				});
				return present(hub, changed(hub, task));
			},
		}),
		defineTool({
			name: 'list_tasks',
			description: 'List tasks, open by default, optionally for one owner.',
			input: z.object({ status: z.enum(['open', 'done', 'all']).default('open'), owner_handle: z.string().optional() }),
			activity: 'Checking the task list',
			run: ({ status, owner_handle }, { hub, caller, viewers = [] }) => {
				const ownerId = personId(hub, owner_handle) ?? undefined;
				return presentAll(hub, new Tasks(hub).list({ status, ownerId, seenBy: [caller.id, ...viewers] }));
			},
		}),
		defineTool({
			name: 'update_task',
			description: 'Complete, reopen, rename, reassign or reschedule a task.',
			input: z.object({
				id: z.string(),
				status: z.enum(['open', 'done']).optional(),
				title: z.string().min(1).max(200).optional(),
				owner_handle: z.string().nullable().optional(),
				due,
			}),
			activity: 'Updating a task',
			run: ({ id, status, title, owner_handle, due: dueDate }, { hub, caller, viewers = [], timezone }) => {
				const store = new Tasks(hub);
				const existing = store.get(id);
				if (existing === null || !store.visibleTo(existing, [caller.id, ...viewers])) throw new ToolError(`no task ${id}`);
				const task = store.update(
					id,
					{
						...(status === undefined ? {} : { status }),
						...(title === undefined ? {} : { title }),
						...(owner_handle === undefined ? {} : { owner_id: personId(hub, owner_handle) }),
						...(dueDate === undefined ? {} : { due_at: dueAt(dueDate, timezone) }),
					},
					caller.id,
				);
				if (task === null) throw new ToolError(`no task ${id}`);
				return present(hub, changed(hub, task));
			},
		}),
		...sessionTools,
	],
	routes: [
		{
			method: 'GET',
			path: 'tasks',
			handler: ({ hub, url, person }) => {
				const status = url.searchParams.get('status');
				return presentAll(
					hub,
					new Tasks(hub).list({ status: status === 'done' || status === 'all' ? status : 'open', seenBy: [person.id] }),
				);
			},
		},
		{
			method: 'POST',
			path: 'tasks',
			handler: async ({ hub, req, person, app }) => {
				const body = await readBody(req, z.object({ title: z.string().min(1).max(200), owner_handle: z.string().optional() }));
				const ownerId = personId(hub, body.owner_handle);
				const task = new Tasks(hub).add({ title: body.title, createdBy: person.id, ownerId });
				app.emit('changed', { id: task.id });
				return present(hub, task);
			},
		},
		{
			method: 'PATCH',
			path: 'tasks/:id',
			handler: async ({ hub, req, params, app, person }) => {
				const body = await readBody(req, z.object({ status: z.enum(['open', 'done']) }));
				const store = new Tasks(hub);
				const existing = store.get(params.id ?? '');
				if (existing === null || !store.visibleTo(existing, [person.id])) throw new HttpError(404, 'task not found');
				const task = store.update(existing.id, { status: body.status }, person.id);
				if (task === null) throw new HttpError(404, 'task not found');
				app.emit('changed', { id: task.id });
				return present(hub, task);
			},
		},
		...sessionRoutes,
		...transcriptRoutes,
		...planningRoutes,
	],
});
