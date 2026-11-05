import { HttpError, newId, now, z, type AppRequestContext, type AppRoute, type Hub } from '@hq/sdk';
import { redactDeep } from './redact';
import { Sessions } from './sessions';
import { Tasks, type Task } from './store';

// Coding conversations synced from people's Macs: the helper app puts the latest snapshot of each one here, teammates read
// it from the Agents board. A synced conversation and a session an agent reported over MCP are one row of `agent_sessions`,
// found by (owner, provider, source id). What came from the conversation (its title, working folder, text) is kept apart
// from what the MCP tools read and write, so no tool can return any of it. See docs/sessions.md.

/**
 * The largest request body a snapshot PUT takes, envelope included: 1 MiB, core's limit for a `/v1` body (an app route may
 * only lower it, `src/apps/mount.ts`). The helper builds every snapshot to fit.
 */
export const SNAPSHOT_MAX_BYTES = 1024 * 1024;
const ACTIVITY_BODY = 64 * 1024;
const ARCHIVE_BODY = 1024;
const PAGE = 50;
/** The most sessions of one person the board shows, as `active_sessions` and `GET /apps/tasks/api/sessions` do. */
const PER_PERSON = 50;
/** Sessions one person may have, MCP-reported or synced. */
export const MAX_SESSIONS = 5000;
const DEFAULT_QUOTA_MB = 512;
const FUTURE_SLACK_MS = 60_000;
const MAX_MESSAGES = 10_000;
const MAX_TEXT = 500_000;

export const provider = z.enum(['codex', 'claude']);
export const sourceId = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);

const snapshotSchema = z
	.object({
		projection: z.literal('conversation-text-v1'),
		title: z.string().max(200),
		cwd: z.string().min(1).max(2048),
		git_branch: z.string().max(256).nullable(),
		task_ref: z
			.string()
			.regex(/^HQ-\d{1,9}$/)
			.nullable(),
		messages: z
			.array(
				z
					.object({
						id: z.string().min(1).max(256),
						role: z.enum(['user', 'assistant']),
						text: z.string().max(MAX_TEXT),
						timestamp: z.string().max(64).nullable(),
					})
					.strict(),
			)
			.max(MAX_MESSAGES),
	})
	.strict()
	.refine((value) => new Set(value.messages.map((message) => message.id)).size === value.messages.length);
type Snapshot = z.infer<typeof snapshotSchema>;

// Workspace-relative paths only: never absolute, never climbing out.
const filesTouched = z
	.array(
		z
			.string()
			.min(1)
			.max(512)
			.refine((path) => !path.startsWith('/') && !path.split('/').includes('..')),
	)
	.max(50);
const activityAt = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);

const putSchema = z
	.object({
		base_revision: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
		activity_at: activityAt.optional(),
		files_touched: filesTouched.optional(),
		snapshot: snapshotSchema,
	})
	.strict();
const activitySchema = z
	.object({
		sha256: z.string().regex(/^[a-f0-9]{64}$/),
		activity_at: activityAt.optional(),
		files_touched: filesTouched.optional(),
	})
	.strict();
const archiveSchema = z.object({ archived: z.boolean() }).strict();
const pageSchema = z.object({
	before: z.string().max(128).optional(),
	task_id: z.string().max(64).optional(),
	include_archived: z.string().optional(),
});
const activeSchema = z.object({
	cursor: z.string().max(128).optional(),
	limit: z.coerce.number().int().min(1).max(PAGE).default(PAGE),
	since_minutes: z.coerce.number().int().min(1).max(1440).default(10),
});

type Row = {
	id: string;
	owner_id: string;
	provider: string;
	source_id: string;
	title: string;
	intent: string;
	repo: string | null;
	branch: string | null;
	state: 'active' | 'idle' | 'ended';
	last_seen_at: number;
	created_at: number;
	updated_at: number;
	cwd: string;
	synced_title: string;
	revision: number;
	sha256: string;
	bytes: number;
	message_count: number;
	activity_at: number | null;
	archived_at: number | null;
	files_touched: string | null;
	synced_branch: string | null;
};

const iso = (ms: number) => new Date(ms).toISOString();
const sha256Hex = (text: string) => new Bun.CryptoHasher('sha256').update(text).digest('hex');
const sessionTitle = (row: Row) => (row.synced_title === '' ? row.title : row.synced_title);

/** What the snapshot is hashed as: the helper hashes the same array, which fixes key order in both. */
function snapshotText(snapshot: Snapshot): string {
	return JSON.stringify([
		snapshot.projection,
		snapshot.title,
		snapshot.cwd,
		snapshot.git_branch,
		snapshot.task_ref,
		snapshot.messages.map((m) => [m.id, m.role, m.text, m.timestamp]),
	]);
}

/** The newest message time, so an import of old history is not taken for work happening now. */
function snapshotActivity(snapshot: Snapshot, at = now()): number | null {
	let latest = 0;
	for (const { timestamp } of snapshot.messages) {
		if (!timestamp) continue;
		const parsed = /^\d+$/.test(timestamp) ? Number(timestamp) : Date.parse(timestamp);
		if (Number.isFinite(parsed) && parsed > 0 && parsed <= at + FUTURE_SLACK_MS) latest = Math.max(latest, Math.min(parsed, at));
	}
	return latest || null;
}

/** The most one person's stored conversations may hold, in bytes (`HQ_TRANSCRIPT_QUOTA_MB`, default 512). */
export function transcriptQuotaBytes(env: Record<string, string | undefined> = process.env): number {
	const mb = Number(env.HQ_TRANSCRIPT_QUOTA_MB?.trim());
	return Math.floor((Number.isFinite(mb) && mb > 0 ? mb : DEFAULT_QUOTA_MB) * 1024 * 1024);
}

class Synced {
	constructor(private readonly hub: Hub) {}

	own(owner: string, providerName: string, source: string): Row | null {
		return this.hub.db
			.query<Row, { owner: string; provider: string; source: string }>(
				'SELECT * FROM agent_sessions WHERE owner_id = $owner AND provider = $provider AND source_id = $source',
			)
			.get({ owner, provider: providerName, source });
	}

	/** Anyone's session by its id. An archived one is its owner's alone. A removed person's stay, as their messages do. */
	byId(id: string, caller: string): Row | null {
		const row = this.hub.db.query<Row, { id: string }>('SELECT * FROM agent_sessions WHERE id = $id').get({ id });
		return row === null || (row.archived_at !== null && row.owner_id !== caller) ? null : row;
	}

	mine(owner: string, query: { before?: string; task_id?: string; include_archived?: string }): Row[] {
		return this.hub.db
			.query<Row, Record<string, string | number>>(
				`SELECT * FROM agent_sessions WHERE owner_id = $owner AND ($archived = 1 OR archived_at IS NULL)
				AND ($before = '' OR id < $before)
				AND ($task = '' OR EXISTS (SELECT 1 FROM agent_session_tasks l WHERE l.session_id = agent_sessions.id AND l.task_id = $task))
				ORDER BY id DESC LIMIT $limit`,
			)
			.all({
				owner,
				archived: query.include_archived === '1' ? 1 : 0,
				before: query.before ?? '',
				task: query.task_id ?? '',
				limit: PAGE + 1,
			});
	}

	/**
	 * Not archived, with a check-in or message newer than the window, in id order from the cursor. Each person's newest
	 * `PER_PERSON` are chosen before the cursor applies, so one member's thousands cannot make every board walk hundreds of
	 * pages.
	 */
	active(cursor: string, limit: number, sinceMinutes: number): Row[] {
		const since = now() - sinceMinutes * 60_000;
		return this.hub.db
			.query<Row, Record<string, string | number>>(
				`SELECT * FROM (
					SELECT *, ROW_NUMBER() OVER (PARTITION BY owner_id ORDER BY MAX(last_seen_at, COALESCE(activity_at, 0)) DESC, id DESC) AS n
					FROM agent_sessions WHERE (last_seen_at > $since OR activity_at > $since) AND archived_at IS NULL
				) WHERE n <= $perPerson AND id > $cursor ORDER BY id LIMIT $limit`,
			)
			.all({ since, cursor, limit: limit + 1, perPerson: PER_PERSON });
	}

	body(id: string): string | null {
		return (
			this.hub.db
				.query<{ body: string }, { id: string }>('SELECT body FROM agent_session_transcripts WHERE session_id = $id')
				.get({ id })?.body ?? null
		);
	}

	/** What the person's other sessions already hold. */
	used(owner: string, except: string): number {
		return this.hub.db
			.query<{ n: number }, { owner: string; except: string }>(
				'SELECT COALESCE(SUM(bytes), 0) AS n FROM agent_sessions WHERE owner_id = $owner AND id != $except',
			)
			.get({ owner, except })!.n;
	}

	count(owner: string): number {
		return this.hub.db
			.query<{ n: number }, { owner: string }>('SELECT COUNT(*) AS n FROM agent_sessions WHERE owner_id = $owner')
			.get({ owner })!.n;
	}

	/** Time and files only: the effect of an upload of text the server already holds. */
	touch(id: string, activity: number | null, files: string[] | undefined): void {
		this.hub.db
			.query(
				`UPDATE agent_sessions SET activity_at = CASE WHEN $activity IS NULL THEN activity_at ELSE MAX(COALESCE(activity_at, 0), $activity) END,
				files_touched = COALESCE($files, files_touched) WHERE id = $id`,
			)
			.run({ id, activity, files: files === undefined ? null : JSON.stringify(files) });
	}

	/**
	 * Writes the snapshot as the session's next revision, new or not. A synced session never moves `state` or `last_seen_at`
	 * (those are the agent's own check-ins), so importing old history cannot make it look active; a row first made here starts
	 * idle and never seen.
	 */
	commit(input: {
		owner: string;
		provider: string;
		source: string;
		revision: number;
		snapshot: Snapshot;
		sha256: string;
		body: string;
		bytes: number;
		activity: number | null;
		files: string[] | undefined;
	}): Row {
		const at = now();
		const { snapshot } = input;
		return this.hub.db.transaction(() => {
			const row = this.hub.db
				.query<Row, Record<string, string | number | null>>(
					`INSERT INTO agent_sessions (id, owner_id, provider, source_id, title, intent, state, last_seen_at, created_at, updated_at,
						cwd, synced_title, synced_branch, revision, sha256, bytes, message_count, activity_at, files_touched)
					VALUES ($id, $owner, $provider, $source, '', '', 'idle', 0, $at, $at, $cwd, $title, $branch, $revision, $sha256, $bytes, $count,
						$activity, $files)
					ON CONFLICT (owner_id, provider, source_id) DO UPDATE SET
						synced_branch = $branch, cwd = $cwd,
						synced_title = CASE WHEN $title = '' THEN synced_title ELSE $title END,
						revision = $revision, sha256 = $sha256, bytes = $bytes, message_count = $count,
						activity_at = CASE WHEN $activity IS NULL THEN activity_at ELSE MAX(COALESCE(activity_at, 0), $activity) END,
						files_touched = COALESCE($files, files_touched), updated_at = $at
					RETURNING *`,
				)
				.get({
					id: newId(),
					owner: input.owner,
					provider: input.provider,
					source: input.source,
					branch: snapshot.git_branch,
					at,
					cwd: snapshot.cwd,
					title: snapshot.title,
					revision: input.revision,
					sha256: input.sha256,
					bytes: input.bytes,
					count: snapshot.messages.length,
					activity: input.activity,
					files: input.files === undefined ? null : JSON.stringify(input.files),
				})!;
			this.hub.db
				.query(
					`INSERT INTO agent_session_transcripts (session_id, body) VALUES ($id, $body)
					ON CONFLICT (session_id) DO UPDATE SET body = $body`,
				)
				.run({ id: row.id, body: input.body });
			return row;
		})();
	}

	archive(row: Row, archived: boolean): Row {
		return this.hub.db
			.query<Row, { id: string; at: number | null }>(
				`UPDATE agent_sessions SET archived_at = $at,
				state = CASE WHEN $at IS NOT NULL THEN 'ended' WHEN archived_at IS NOT NULL THEN 'idle' ELSE state END
				WHERE id = $id RETURNING *`,
			)
			.get({ id: row.id, at: archived ? (row.archived_at ?? now()) : null })!;
	}
}

type Links = { tasks: Map<string, Task[]>; projects: Map<string, { id: string; name: string }[]> };

/** The tasks each session is linked to that `viewer` may see, and those tasks' projects. A task they cannot see is not mentioned. */
function links(hub: Hub, rows: Row[], viewer: string): Links {
	const store = new Tasks(hub);
	const all = new Sessions(hub).links(rows.map((row) => row.id));
	const tasks = new Map<string, Task[]>();
	for (const [id, list] of all)
		tasks.set(
			id,
			list.filter((task) => task.number !== null && store.visibleTo(task, [viewer])),
		);
	const ids = [...new Set([...tasks.values()].flatMap((list) => list.map((task) => task.id)))];
	const byTask = new Map<string, { id: string; name: string }[]>();
	if (ids.length > 0) {
		const found = hub.db
			.query<{ task_id: string; id: string; name: string }, { ids: string }>(
				`SELECT tp.task_id, p.id, p.name FROM task_projects tp JOIN projects p ON p.id = tp.project_id AND p.archived_at IS NULL
				WHERE tp.task_id IN (SELECT value FROM json_each($ids)) ORDER BY tp.ordinal`,
			)
			.all({ ids: JSON.stringify(ids) });
		for (const { task_id, ...project } of found) byTask.set(task_id, [...(byTask.get(task_id) ?? []), project]);
	}
	return { tasks, projects: byTask };
}

/** One row as the Agents board lists it. Another member's title and branch have secret-looking strings hidden. */
function thread(hub: Hub, rows: Row[], viewer: string) {
	const { tasks, projects } = links(hub, rows, viewer);
	const owners = hub.people.byIds(rows.map((row) => row.owner_id));
	return rows.map((row) => {
		const own = row.owner_id === viewer;
		const hide = <T>(value: T): T => (own ? value : redactDeep(value));
		const mine = tasks.get(row.id) ?? [];
		const title = sessionTitle(row);
		return {
			session_id: row.id,
			intent: hide(row.intent === '' ? title : row.intent),
			state: row.state,
			last_seen_at: row.last_seen_at,
			last_activity_at: Math.max(row.last_seen_at, row.activity_at ?? 0),
			title: hide(title),
			owner_person_id: row.owner_id,
			owner_name: owners.get(row.owner_id)?.name ?? 'Someone',
			provider: row.provider,
			git_branch: hide(row.synced_branch ?? row.branch),
			tasks: mine.map((task) => ({ id: task.id, ref: `HQ-${task.number}`, title: task.title })),
			projects: [
				...new Map(mine.flatMap((task) => projects.get(task.id) ?? []).map((project) => [project.id, project])).values(),
			],
		};
	});
}

function files(row: Row): string[] | null {
	if (row.files_touched === null) return null;
	const parsed = filesTouched.safeParse(JSON.parse(row.files_touched));
	return parsed.success ? parsed.data : null;
}

/**
 * A session as the helper and the app read it. The owner gets all of it. Anyone else gets no working folder, no touched files
 * and no hash (the hash covers the unredacted text, so it would let a reader check a guess at a hidden value), and has
 * secret-looking strings hidden.
 */
function session(hub: Hub, rows: Row[], viewer: string) {
	const { tasks } = links(hub, rows, viewer);
	return rows.map((row) => {
		const own = row.owner_id === viewer;
		const ids = (tasks.get(row.id) ?? []).map((task) => task.id);
		const shared = {
			id: row.id,
			owner_person_id: row.owner_id,
			provider: row.provider,
			source_id: row.source_id,
			title: sessionTitle(row),
			git_branch: row.synced_branch ?? row.branch,
			task_id: ids[0] ?? null,
			task_ids: ids,
			revision: row.revision,
			message_count: row.message_count,
			created_at: iso(row.created_at),
			updated_at: iso(row.updated_at),
			activity_at: row.activity_at,
			archived_at: row.archived_at === null ? null : iso(row.archived_at),
			// The tool history is not kept by this server; the helper reads this to know not to send it.
			tool_history: false,
		};
		return own
			? { ...shared, cwd: row.cwd, sha256: row.sha256, bytes: row.bytes, files_touched: files(row), repo: row.repo }
			: redactDeep({ ...shared, sha256: null });
	});
}

/** The stored snapshot a member other than the owner reads: no working folder, secret-looking strings hidden. */
function forPeer(body: string): string {
	const { cwd: _cwd, ...rest } = JSON.parse(body) as Snapshot;
	return JSON.stringify(redactDeep(rest));
}

const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

function reply(data: unknown, status = 200, extra: Record<string, string> = {}): Response {
	return Response.json(data, { status, headers: { ...headers, ...extra } });
}

/**
 * Every answer from here is `no-store`, errors included. Only a device's bearer is a person at their own app: a script key or
 * an MCP key is refused, so an agent holding one cannot read other people's conversations.
 */
const guarded = (run: (ctx: AppRequestContext) => unknown | Promise<unknown>) => async (ctx: AppRequestContext) => {
	try {
		if (ctx.keyKind !== 'device') throw new HttpError(403, 'device_only');
		const result = await run(ctx);
		return result instanceof Response ? result : reply(result);
	} catch (error) {
		if (error instanceof HttpError) return reply({ error: error.message }, error.status);
		throw error;
	}
};

/** The body as JSON checked against `schema`; a body cut off for being too large stays a 413. */
async function parse<S extends z.ZodType>(req: Request, schema: S, error: string): Promise<z.infer<S>> {
	let raw: unknown;
	try {
		raw = await req.json();
	} catch (failure) {
		throw failure instanceof HttpError ? failure : new HttpError(400, error);
	}
	const value = schema.safeParse(raw);
	if (!value.success) throw new HttpError(400, error);
	return value.data;
}

function identity(first: string | undefined, second: string | undefined) {
	const kind = provider.safeParse(first);
	const source = sourceId.safeParse(second);
	if (!kind.success || !source.success) throw new HttpError(400, 'invalid_identity');
	return { provider: kind.data, source: source.data };
}

function mineOr404(ctx: AppRequestContext, first: string | undefined, second: string | undefined): Row {
	const id = identity(first, second);
	const row = new Synced(ctx.hub).own(ctx.person.id, id.provider, id.source);
	if (row === null) throw new HttpError(404, 'not_found');
	return row;
}

const changed = (hub: Hub, sessionId: string) =>
	hub.bus.emit({ type: 'app.event', app: 'tasks', name: 'changed', data: { session_id: sessionId } });

function transcriptReply(row: Row, body: string, viewer: string): Response {
	const base = { 'Content-Type': 'application/json; charset=utf-8', 'X-HQ-Revision': String(row.revision) };
	if (row.owner_id === viewer)
		return new Response(body, { headers: { ...headers, ...base, 'X-HQ-Snapshot-Sha256': row.sha256 } });
	// No hash for anyone else: it covers the text before secrets were hidden.
	return new Response(forPeer(body), { headers: { ...headers, ...base } });
}

function readTranscript(ctx: AppRequestContext, row: Row | null): Response {
	if (row === null) throw new HttpError(404, 'not_found');
	if (row.revision === 0) throw new HttpError(409, 'not_synced_yet');
	const body = new Synced(ctx.hub).body(row.id);
	if (body === null) throw new HttpError(503, 'snapshot_unavailable');
	return transcriptReply(row, body, ctx.person.id);
}

const v1 = { mount: 'v1' } as const;
const base = '/v1/agent-sessions';

// `by-id` and a provider are both one path segment, and core refuses two routes that could take the same request, so the
// shapes they share are one route that tells them apart.
export const transcriptRoutes: AppRoute[] = [
	{
		...v1,
		method: 'GET',
		path: base,
		handler: guarded(({ hub, url, person }) => {
			const query = pageSchema.safeParse(Object.fromEntries(url.searchParams));
			if (!query.success) throw new HttpError(400, 'invalid_page');
			const rows = new Synced(hub).mine(person.id, query.data);
			const page = rows.slice(0, PAGE);
			return { sessions: session(hub, page, person.id), next_before: rows.length > PAGE ? page[PAGE - 1]!.id : null };
		}),
	},
	{
		...v1,
		method: 'GET',
		path: `${base}/active`,
		handler: guarded(({ hub, url, person }) => {
			const query = activeSchema.safeParse(Object.fromEntries(url.searchParams));
			if (!query.success) throw new HttpError(400, 'invalid_page');
			const rows = new Synced(hub).active(query.data.cursor ?? '', query.data.limit, query.data.since_minutes);
			const page = rows.slice(0, query.data.limit);
			return { sessions: thread(hub, page, person.id), next_cursor: rows.length > query.data.limit ? page.at(-1)!.id : null };
		}),
	},
	{
		...v1,
		method: 'GET',
		path: `${base}/:first/:second`,
		handler: guarded((ctx) => {
			const { hub, params, person } = ctx;
			if (params.first === 'by-id') {
				const row = new Synced(hub).byId(params.second ?? '', person.id);
				if (row === null) throw new HttpError(404, 'not_found');
				// Any member may open any session (`open_transcripts`), so the app's `?open=1` changes nothing here.
				return { thread: thread(hub, [row], person.id)[0], session: session(hub, [row], person.id)[0] };
			}
			return { session: session(hub, [mineOr404(ctx, params.first, params.second)], person.id)[0] };
		}),
	},
	{
		...v1,
		method: 'GET',
		path: `${base}/:first/:second/transcript`,
		handler: guarded((ctx) => {
			const { hub, params, person } = ctx;
			if (params.first !== 'by-id') return readTranscript(ctx, mineOr404(ctx, params.first, params.second));
			return readTranscript(ctx, new Synced(hub).byId(params.second ?? '', person.id));
		}),
	},
	{
		...v1,
		method: 'PUT',
		path: `${base}/:provider/:source`,
		maxBodyBytes: SNAPSHOT_MAX_BYTES,
		handler: guarded(async (ctx) => {
			const { hub, req, params, person } = ctx;
			const id = identity(params.provider, params.source);
			const input = await parse(req, putSchema, 'invalid_snapshot');
			const { snapshot } = input;
			const at = now();
			if ((input.activity_at ?? 0) > at + FUTURE_SLACK_MS) throw new HttpError(400, 'invalid_activity_time');
			const activity = Math.max(snapshotActivity(snapshot, at) ?? 0, Math.min(input.activity_at ?? 0, at)) || null;

			// A task the person can no longer see (hidden, or its room archived or left) is not linked, and is not a reason to
			// refuse their conversation: the snapshot is still stored.
			let task: Task | null = null;
			if (snapshot.task_ref !== null) {
				const found = hub.db
					.query<Task, { number: number }>('SELECT * FROM tasks WHERE number = $number AND hidden_at IS NULL')
					.get({ number: Number(snapshot.task_ref.slice(3)) });
				if (found !== null && new Tasks(hub).visibleTo(found, [person.id])) task = found;
			}

			const store = new Synced(hub);
			const hash = sha256Hex(snapshotText(snapshot));
			const current = store.own(person.id, id.provider, id.source);
			if (current !== null && current.revision > 0 && current.sha256 === hash) {
				store.touch(current.id, activity, input.files_touched);
				// Nothing was written, so there is no body hash to give.
				return {
					status: 'unchanged',
					session: session(hub, [store.own(person.id, id.provider, id.source)!], person.id)[0],
					stored_verbatim: true,
					body_sha256: null,
				};
			}
			if ((current?.revision ?? 0) !== input.base_revision) throw new HttpError(409, 'revision_conflict');
			const body = JSON.stringify(snapshot);
			const bytes = new TextEncoder().encode(body).byteLength;
			// A smaller replacement is always allowed, so lowering the limit never locks a person out of their own sessions.
			if (bytes > (current?.bytes ?? 0) && store.used(person.id, current?.id ?? '') + bytes > transcriptQuotaBytes()) {
				throw new HttpError(413, 'quota_exceeded');
			}
			if (current === null && store.count(person.id) >= MAX_SESSIONS) throw new HttpError(413, 'session_limit');
			const row = store.commit({
				owner: person.id,
				provider: id.provider,
				source: id.source,
				revision: (current?.revision ?? 0) + 1,
				snapshot,
				sha256: hash,
				body,
				bytes,
				activity,
				files: input.files_touched,
			});
			if (task !== null) new Sessions(hub).link(row.id, [task.id], false);
			changed(hub, row.id);
			return {
				status: 'synced',
				session: session(hub, [row], person.id)[0],
				stored_verbatim: true,
				body_sha256: sha256Hex(body),
			};
		}),
	},
	{
		...v1,
		method: 'PUT',
		path: `${base}/:provider/:source/activity`,
		maxBodyBytes: ACTIVITY_BODY,
		handler: guarded(async (ctx) => {
			const { hub, req, params, person } = ctx;
			const input = await parse(req, activitySchema, 'invalid_activity');
			const at = now();
			if ((input.activity_at ?? 0) > at + FUTURE_SLACK_MS) throw new HttpError(400, 'invalid_activity_time');
			const current = mineOr404(ctx, params.provider, params.source);
			if (current.sha256 !== input.sha256) throw new HttpError(409, 'snapshot_changed');
			const store = new Synced(hub);
			store.touch(current.id, Math.min(input.activity_at ?? 0, at) || null, input.files_touched);
			return {
				status: 'unchanged',
				session: session(hub, [store.own(person.id, current.provider, current.source_id)!], person.id)[0],
			};
		}),
	},
	{
		...v1,
		method: 'PUT',
		path: `${base}/:provider/:source/archive`,
		maxBodyBytes: ARCHIVE_BODY,
		handler: guarded(async (ctx) => {
			const { hub, req, params, person } = ctx;
			const input = await parse(req, archiveSchema, 'invalid_archive');
			const row = new Synced(hub).archive(mineOr404(ctx, params.provider, params.source), input.archived);
			changed(hub, row.id);
			return { session: session(hub, [row], person.id)[0] };
		}),
	},
];
