import type { Hub, Migration } from '@hq/sdk';
import { newId, now } from '@hq/sdk';

/** What the list and the assistant's tools know: a task is open or done. The board's in-progress and blocked are `progress`. */
export type TaskStatus = 'open' | 'done';
export type Progress = 'in_progress' | 'blocked';

export type Task = {
	id: string;
	title: string;
	notes: string;
	status: TaskStatus;
	owner_id: string | null;
	created_by: string;
	conversation_id: string | null;
	due_at: number | null;
	created_at: number;
	completed_at: number | null;
	/** `#<number>` on the board; never reused. Null only for a row from before numbering, until the migration numbers it. */
	number: number | null;
	/** Board order, low first. */
	position: number;
	/** While `status` is open: null (to do), in progress or blocked. Always null once done. */
	progress: Progress | null;
	/** Deleting hides: the row, its number and its comments stay. */
	hidden_at: number | null;
	completed_by: string | null;
	/** The last time its status, owner, due date or board changed. */
	touched_at: number;
};

export const migrations: Migration[] = [
	{
		id: '001_tasks',
		up: `CREATE TABLE tasks (
			id TEXT PRIMARY KEY,
			title TEXT NOT NULL,
			notes TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL CHECK (status IN ('open', 'done')),
			owner_id TEXT REFERENCES people(id),
			created_by TEXT NOT NULL REFERENCES people(id),
			conversation_id TEXT REFERENCES conversations(id),
			due_at INTEGER,
			created_at INTEGER NOT NULL,
			completed_at INTEGER
		);
		CREATE INDEX tasks_status ON tasks(status, created_at);`,
	},
	{
		id: '002_agent_sessions',
		up: `CREATE TABLE agent_sessions (
			id TEXT PRIMARY KEY,
			owner_id TEXT NOT NULL REFERENCES people(id),
			provider TEXT NOT NULL,
			source_id TEXT NOT NULL,
			title TEXT NOT NULL DEFAULT '',
			intent TEXT NOT NULL DEFAULT '',
			repo TEXT,
			branch TEXT,
			state TEXT NOT NULL CHECK (state IN ('active', 'idle', 'ended')),
			last_seen_at INTEGER NOT NULL,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			UNIQUE (owner_id, provider, source_id)
		);
		CREATE INDEX agent_sessions_seen ON agent_sessions(last_seen_at);
		CREATE TABLE agent_session_tasks (
			session_id TEXT NOT NULL REFERENCES agent_sessions(id),
			task_id TEXT NOT NULL REFERENCES tasks(id),
			linked_at INTEGER NOT NULL,
			PRIMARY KEY (session_id, task_id)
		);`,
	},
	// Planning (003-009 are this feature's). Nothing is rebuilt: the CHECK on `status` stays, and the board's two extra
	// states live in `progress`, so every existing row, id and tool keeps working.
	{
		id: '003_task_planning',
		up: `ALTER TABLE tasks ADD COLUMN number INTEGER;
			ALTER TABLE tasks ADD COLUMN position REAL NOT NULL DEFAULT 0;
			ALTER TABLE tasks ADD COLUMN progress TEXT CHECK (progress IN ('in_progress', 'blocked'));
			ALTER TABLE tasks ADD COLUMN hidden_at INTEGER;
			ALTER TABLE tasks ADD COLUMN completed_by TEXT REFERENCES people(id);
			ALTER TABLE tasks ADD COLUMN touched_at INTEGER NOT NULL DEFAULT 0;
			UPDATE tasks SET number = filed.n
				FROM (SELECT rowid AS rid, ROW_NUMBER() OVER (ORDER BY created_at, rowid) AS n FROM tasks) AS filed
				WHERE tasks.rowid = filed.rid;
			UPDATE tasks SET position = number, touched_at = COALESCE(completed_at, created_at);
			CREATE UNIQUE INDEX tasks_number ON tasks(number);
			CREATE INDEX tasks_board ON tasks(hidden_at, position);`,
	},
	{
		id: '004_projects',
		up: `CREATE TABLE projects (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			body TEXT,
			owner_id TEXT NOT NULL REFERENCES people(id),
			status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'done')),
			planning_state TEXT NOT NULL DEFAULT 'Next' CHECK (planning_state IN ('Now', 'Next', 'Backlog')),
			planning_category TEXT,
			tags TEXT NOT NULL DEFAULT '[]',
			created_by TEXT NOT NULL REFERENCES people(id),
			created_at INTEGER NOT NULL,
			closed_at INTEGER,
			archived_at INTEGER
		);
		CREATE INDEX projects_created ON projects(created_at, id);`,
	},
	{
		id: '005_task_projects',
		up: `CREATE TABLE task_projects (
			task_id TEXT NOT NULL REFERENCES tasks(id),
			project_id TEXT NOT NULL REFERENCES projects(id),
			ordinal INTEGER NOT NULL,
			PRIMARY KEY (task_id, project_id)
		);
		CREATE INDEX task_projects_project ON task_projects(project_id);`,
	},
	{
		id: '006_planning_comments',
		up: `CREATE TABLE planning_comments (
			id TEXT PRIMARY KEY,
			target_kind TEXT NOT NULL CHECK (target_kind IN ('task', 'project')),
			target_id TEXT NOT NULL,
			author_id TEXT NOT NULL REFERENCES people(id),
			body TEXT NOT NULL,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX planning_comments_target ON planning_comments(target_kind, target_id, created_at, id);`,
	},
	// Synced conversations (010-019 are this feature's). A synced session and one an agent reported over MCP are the same
	// row, found by (owner, provider, source id): the new columns are empty until a sync fills them, so every existing row
	// and tool keeps working. `synced_title`, `synced_branch` and the transcript table hold what came from the conversation,
	// kept apart from the `title` and `branch` the MCP tools read and write.
	{
		id: '010_synced_sessions',
		up: `ALTER TABLE agent_sessions ADD COLUMN cwd TEXT NOT NULL DEFAULT '';
			ALTER TABLE agent_sessions ADD COLUMN synced_title TEXT NOT NULL DEFAULT '';
			ALTER TABLE agent_sessions ADD COLUMN synced_branch TEXT;
			ALTER TABLE agent_sessions ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
			ALTER TABLE agent_sessions ADD COLUMN sha256 TEXT NOT NULL DEFAULT '';
			ALTER TABLE agent_sessions ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0;
			ALTER TABLE agent_sessions ADD COLUMN message_count INTEGER NOT NULL DEFAULT 0;
			ALTER TABLE agent_sessions ADD COLUMN activity_at INTEGER;
			ALTER TABLE agent_sessions ADD COLUMN archived_at INTEGER;
			ALTER TABLE agent_sessions ADD COLUMN files_touched TEXT;
			CREATE INDEX agent_sessions_owner ON agent_sessions(owner_id, id);
			CREATE INDEX agent_sessions_activity ON agent_sessions(activity_at);`,
	},
	{
		id: '011_session_transcripts',
		up: `CREATE TABLE agent_session_transcripts (
			session_id TEXT PRIMARY KEY REFERENCES agent_sessions(id),
			body TEXT NOT NULL
		);`,
	},
];

/** A task whose room the viewers are not all in (and who do not own it) is theirs to see only if this holds. */
export const VISIBLE = `(tasks.conversation_id IS NULL OR NOT EXISTS (SELECT 1 FROM json_each($seen) v
	WHERE v.value IS NOT tasks.owner_id AND NOT EXISTS
		(SELECT 1 FROM open_conversation_members c WHERE c.conversation_id = tasks.conversation_id AND c.person_id = v.value)))`;

export class Tasks {
	constructor(private readonly hub: Hub) {}

	add(input: {
		title: string;
		notes?: string;
		ownerId?: string | null;
		createdBy: string;
		conversationId?: string | null;
		dueAt?: number | null;
	}): Task {
		const at = now();
		const id = newId();
		// Numbered and placed last in one statement, so two adds cannot take the same number.
		this.hub.db
			.query(
				`INSERT INTO tasks (id, title, notes, status, owner_id, created_by, conversation_id, due_at, created_at, touched_at, number, position)
				VALUES ($id, $title, $notes, 'open', $owner_id, $created_by, $conversation_id, $due_at, $at, $at,
					(SELECT COALESCE(MAX(number), 0) + 1 FROM tasks), (SELECT COALESCE(MAX(position), 0) + 1 FROM tasks))`,
			)
			.run({
				id,
				title: input.title.trim(),
				notes: input.notes ?? '',
				owner_id: input.ownerId ?? null,
				created_by: input.createdBy,
				conversation_id: input.conversationId ?? null,
				due_at: input.dueAt ?? null,
				at,
			});
		return this.get(id)!;
	}

	/** A task that is not hidden. */
	get(id: string): Task | null {
		return this.hub.db.query<Task, { id: string }>('SELECT * FROM tasks WHERE id = $id AND hidden_at IS NULL').get({ id });
	}

	list(filter: { status?: TaskStatus | 'all'; ownerId?: string; seenBy?: string[] } = {}): Task[] {
		const status = filter.status ?? 'open';
		return this.hub.db
			.query<Task, { status: string; owner: string | null; seen: string | null }>(
				`SELECT * FROM tasks
				WHERE hidden_at IS NULL AND ($status = 'all' OR status = $status) AND ($owner IS NULL OR owner_id = $owner)
				AND ($seen IS NULL OR ${VISIBLE})
				ORDER BY status = 'done', COALESCE(due_at, 9e15), created_at`,
			)
			.all({ status, owner: filter.ownerId ?? null, seen: filter.seenBy === undefined ? null : JSON.stringify(filter.seenBy) });
	}

	visibleTo(task: Task, seenBy: string[]): boolean {
		const room = task.conversation_id;
		return room === null || seenBy.every((id) => id === task.owner_id || this.hub.conversations.isMember(room, id));
	}

	/** Changes a task. `by` is who is doing it, kept as who finished it when the change completes it. */
	update(
		id: string,
		patch: Partial<Pick<Task, 'title' | 'notes' | 'owner_id' | 'due_at' | 'status' | 'progress'>>,
		by: string | null = null,
	): Task | null {
		const task = this.get(id);
		if (task === null) return null;
		const next = { ...task, ...patch };
		if (next.status === 'done') next.progress = null;
		if (patch.status !== undefined && patch.status !== task.status) {
			next.completed_at = patch.status === 'done' ? now() : null;
			next.completed_by = patch.status === 'done' ? by : null;
		}
		const moved =
			next.status !== task.status ||
			next.progress !== task.progress ||
			next.owner_id !== task.owner_id ||
			next.due_at !== task.due_at;
		if (moved) next.touched_at = now();
		this.hub.db
			.query(
				`UPDATE tasks SET title = $title, notes = $notes, owner_id = $owner_id, due_at = $due_at, status = $status,
				progress = $progress, completed_at = $completed_at, completed_by = $completed_by, touched_at = $touched_at WHERE id = $id`,
			)
			.run({
				id,
				title: next.title,
				notes: next.notes,
				owner_id: next.owner_id,
				due_at: next.due_at,
				status: next.status,
				progress: next.progress,
				completed_at: next.completed_at,
				completed_by: next.completed_by,
				touched_at: next.touched_at,
			});
		return next;
	}
}
