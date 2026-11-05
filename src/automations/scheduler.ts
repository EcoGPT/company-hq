import type { AppContext } from '../apps/define';
import type { Hub } from '../core/hub';
import { newId } from '../core/ids';
import type { Migration } from '../db/database';
import type { AutomationDefinition } from './define';
import { nextRun, parseSchedule, type Schedule } from './schedule';

export const AUTOMATION_MIGRATIONS: Migration[] = [
	{
		id: 'core/006_automation_runs',
		up: `CREATE TABLE automation_runs (
			id TEXT PRIMARY KEY,
			app TEXT NOT NULL,
			slug TEXT NOT NULL,
			trigger TEXT NOT NULL CHECK (trigger IN ('schedule', 'manual')),
			status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed')),
			started_at INTEGER NOT NULL,
			finished_at INTEGER,
			output TEXT,
			error TEXT,
			logs TEXT NOT NULL DEFAULT ''
		);
		CREATE INDEX automation_runs_slug ON automation_runs(app, slug, id);`,
	},
];

export type AutomationRun = {
	id: string;
	app: string;
	slug: string;
	trigger: 'schedule' | 'manual';
	status: 'running' | 'succeeded' | 'failed';
	started_at: number;
	finished_at: number | null;
	output: string | null;
	error: string | null;
	logs: string;
};

type Entry = { app: string; automation: AutomationDefinition; schedule: Schedule; context: AppContext };

const keyOf = (app: string, slug: string) => `${app}/${slug}`;

export class Scheduler {
	private readonly entries = new Map<string, Entry>();
	private readonly inFlight = new Map<string, Promise<AutomationRun>>();
	private readonly controllers = new Set<AbortController>();
	private readonly bootedAt: Date;
	private timer?: ReturnType<typeof setInterval>;

	constructor(
		private readonly hub: Hub,
		private readonly clock: () => Date = () => new Date(),
		private readonly keepRuns = 200,
	) {
		this.bootedAt = clock();
	}

	add(app: string, automation: AutomationDefinition, context: AppContext): void {
		const key = keyOf(app, automation.slug);
		if (this.entries.has(key)) throw new Error(`duplicate automation ${key}`);
		this.entries.set(key, { app, automation, schedule: parseSchedule(automation.schedule), context });
	}

	list() {
		return [...this.entries.values()].map(({ app, automation, schedule }) => {
			const next = this.nextFor(app, automation.slug, schedule);
			return {
				app,
				slug: automation.slug,
				name: automation.name,
				description: automation.description,
				schedule: automation.schedule,
				next_run: next?.toISOString() ?? null,
				last_run: this.runs(app, automation.slug, 1)[0] ?? null,
				running: this.inFlight.has(keyOf(app, automation.slug)),
			};
		});
	}

	runs(app: string, slug: string, limit = 20): AutomationRun[] {
		return this.hub.db
			.query<AutomationRun, { app: string; slug: string; limit: number }>(
				'SELECT * FROM automation_runs WHERE app = $app AND slug = $slug ORDER BY id DESC LIMIT $limit',
			)
			.all({ app, slug, limit });
	}

	has(app: string, slug: string): boolean {
		return this.entries.has(keyOf(app, slug));
	}

	async tick(): Promise<AutomationRun[]> {
		const at = this.clock();
		const due = [...this.entries.values()].filter(({ app, automation, schedule }) => {
			if (this.inFlight.has(keyOf(app, automation.slug))) return false;
			const next = this.nextFor(app, automation.slug, schedule);
			return next !== null && next.getTime() <= at.getTime();
		});
		return Promise.all(due.map(({ app, automation }) => this.run(app, automation.slug, 'schedule')));
	}

	async idle(): Promise<void> {
		while (this.inFlight.size > 0) await Promise.allSettled(this.inFlight.values());
	}

	start(intervalMs = 15_000): void {
		if (this.timer === undefined) {
			this.hub.db
				.query("UPDATE automation_runs SET status = 'failed', error = 'interrupted by restart' WHERE status = 'running'")
				.run();
		}
		this.timer ??= setInterval(() => void this.tick(), intervalMs);
	}

	stop(): void {
		if (this.timer !== undefined) clearInterval(this.timer);
		this.timer = undefined;
		for (const controller of this.controllers) controller.abort(new Error('HQ is stopping'));
	}

	run(app: string, slug: string, trigger: AutomationRun['trigger'] = 'manual'): Promise<AutomationRun> {
		const key = keyOf(app, slug);
		const entry = this.entries.get(key);
		if (entry === undefined) return Promise.reject(new Error(`no automation ${key}`));
		const existing = this.inFlight.get(key);
		if (existing !== undefined) return existing;
		const work = this.execute(entry, trigger).finally(() => this.inFlight.delete(key));
		this.inFlight.set(key, work);
		return work;
	}

	private async execute(entry: Entry, trigger: AutomationRun['trigger']): Promise<AutomationRun> {
		const { app, automation } = entry;
		const id = newId();
		const startedAt = this.clock().getTime();
		const logs: string[] = [];
		this.hub.db
			.query(
				"INSERT INTO automation_runs (id, app, slug, trigger, status, started_at) VALUES ($id, $app, $slug, $trigger, 'running', $at)",
			)
			.run({ id, app, slug: automation.slug, trigger, at: startedAt });
		const controller = new AbortController();
		this.controllers.add(controller);
		let status: AutomationRun['status'] = 'succeeded';
		let output: string | null = null;
		let error: string | null = null;
		try {
			const result = await automation.run({
				...entry.context,
				runId: id,
				trigger,
				signal: controller.signal,
				log: (line) => logs.push(`${this.clock().toISOString()} ${line}`),
			});
			output = typeof result === 'string' ? result : null;
		} catch (caught) {
			status = 'failed';
			error = caught instanceof Error ? caught.message : String(caught);
			console.error(`[automations] ${keyOf(app, automation.slug)} failed: ${error}`);
		} finally {
			this.controllers.delete(controller);
		}
		const run: AutomationRun = {
			id,
			app,
			slug: automation.slug,
			trigger,
			status,
			started_at: startedAt,
			finished_at: this.clock().getTime(),
			output,
			error,
			logs: logs.join('\n'),
		};
		this.hub.db
			.query(
				'UPDATE automation_runs SET status = $status, finished_at = $finished_at, output = $output, error = $error, logs = $logs WHERE id = $id',
			)
			.run({ id, status, finished_at: run.finished_at, output, error, logs: run.logs });
		this.prune(app, automation.slug);
		return run;
	}

	private prune(app: string, slug: string): void {
		this.hub.db
			.query(
				`DELETE FROM automation_runs WHERE app = $app AND slug = $slug AND status != 'running'
				AND id NOT IN (SELECT id FROM automation_runs WHERE app = $app AND slug = $slug ORDER BY id DESC LIMIT $keep)
				AND id != COALESCE((SELECT id FROM automation_runs WHERE app = $app AND slug = $slug AND trigger = 'schedule' ORDER BY id DESC LIMIT 1), '')`,
			)
			.run({ app, slug, keep: this.keepRuns });
	}

	private nextFor(app: string, slug: string, schedule: Schedule): Date | null {
		const last = this.hub.db
			.query<{ started_at: number }, { app: string; slug: string }>(
				"SELECT started_at FROM automation_runs WHERE app = $app AND slug = $slug AND trigger = 'schedule' ORDER BY id DESC LIMIT 1",
			)
			.get({ app, slug });
		const lastAt = last === null ? null : new Date(last.started_at);
		return nextRun(schedule, lastAt ?? this.bootedAt, lastAt);
	}
}
