import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, spyOn, test } from 'bun:test';
import { defineApp, defineAutomation, type AppContext } from '@hq/sdk';
import { AUTOMATION_MIGRATIONS, Scheduler } from '../src/automations/scheduler';
import { Hub } from '../src/core/hub';
import { createHq } from '../src/hq';
import { admin, client } from './helpers';

function clock(start: string) {
	let t = new Date(start).getTime();
	return { now: () => new Date(t), advance: (ms: number) => (t += ms) };
}

function app(run: Parameters<typeof defineAutomation>[0]['run'], schedule = '0 9 * * *') {
	return defineApp({
		slug: 'ops',
		name: 'Ops',
		description: 'Ops jobs',
		automations: [defineAutomation({ slug: 'morning', name: 'Morning', description: 'Says morning', schedule, run })],
	});
}

describe('automations', () => {
	test('a daily automation fires once when due, and records the run', async () => {
		const c = clock('2026-03-01T08:59:00Z');
		let runs = 0;
		const hq = createHq({
			clock: c.now,
			apps: [
				app(({ assistant, hub, log }) => {
					runs += 1;
					log('posting');
					assistant.post(hub.general().id, 'Good morning');
					return 'posted';
				}),
			],
		});
		expect(await hq.scheduler.tick()).toEqual([]);
		c.advance(60_000);
		const [run] = await hq.scheduler.tick();
		expect(run).toMatchObject({ status: 'succeeded', output: 'posted', trigger: 'schedule' });
		expect(run!.logs).toContain('posting');
		expect(await hq.scheduler.tick()).toEqual([]);
		expect(runs).toBe(1);
		expect(hq.hub.messages.list(hq.hub.general().id).at(-1)?.body).toBe('Good morning');
		expect(hq.scheduler.list()[0]?.next_run).toBe('2026-03-02T09:00:00.000Z');
	});

	test('failures are recorded, not thrown', async () => {
		const hq = createHq({
			apps: [
				app(() => {
					throw new Error('upstream 500');
				}, 'manual'),
			],
		});
		using _ = spyOn(console, 'error').mockImplementation(() => {});
		const run = await hq.scheduler.run('ops', 'morning');
		expect(run).toMatchObject({ status: 'failed', error: 'upstream 500', trigger: 'manual' });
	});

	test('a run in flight is not started twice', async () => {
		let release!: () => void;
		let starts = 0;
		const hq = createHq({
			apps: [
				app(async () => {
					starts += 1;
					await new Promise<void>((r) => (release = r));
				}, 'manual'),
			],
		});
		const a = hq.scheduler.run('ops', 'morning');
		const b = hq.scheduler.run('ops', 'morning');
		release();
		await Promise.all([a, b]);
		expect(starts).toBe(1);
	});

	test('HTTP: list, run (admins), history', async () => {
		const hq = createHq({ apps: [app(() => 'ok', 'manual')] });
		const ada = admin(hq);
		const as = client(hq, ada.key);
		expect((await as('GET', '/v1/automations')).body[0]).toMatchObject({ app: 'ops', slug: 'morning', next_run: null });
		expect((await as('POST', '/v1/automations/ops/morning/run')).status).toBe(202);
		await hq.scheduler.idle();
		expect((await as('GET', '/v1/automations/ops/morning/runs')).body[0]).toMatchObject({ status: 'succeeded', output: 'ok' });
		expect((await as('POST', '/v1/automations/ops/nope/run')).status).toBe(404);
	});

	test('run output and logs are for admins, since automations write about every room', async () => {
		const hq = createHq({
			apps: [
				app(({ log }) => {
					log('asked in Secret Room');
					return 'posted in Secret Room';
				}, 'manual'),
			],
		});
		const ada = admin(hq);
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const asBo = client(hq, hq.hub.keys.mint(bo.id).secret);
		await hq.scheduler.run('ops', 'morning');

		expect((await asBo('GET', '/v1/automations/ops/morning/runs')).status).toBe(403);
		const listed = await asBo('GET', '/v1/automations');
		expect(listed.status).toBe(200);
		expect(JSON.stringify(listed.body)).not.toContain('Secret Room');
		expect(listed.body[0].last_run).toMatchObject({ status: 'succeeded' });

		const asAda = client(hq, ada.key);
		expect((await asAda('GET', '/v1/automations')).body[0].last_run.output).toBe('posted in Secret Room');
		expect((await asAda('GET', '/v1/automations/ops/morning/runs')).body[0].logs).toContain('asked in Secret Room');
	});

	test('stopping HQ aborts the signal of runs in flight', async () => {
		using _ = spyOn(console, 'error').mockImplementation(() => {});
		const hq = createHq({
			apps: [
				app(({ signal }) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason))), 'manual'),
			],
		});
		const run = hq.scheduler.run('ops', 'morning');
		hq.stop();
		expect(await run).toMatchObject({ status: 'failed', error: 'HQ is stopping' });
	});

	test('run times and log lines come from the HQ clock', async () => {
		const c = clock('2026-03-01T08:00:00Z');
		const hq = createHq({ clock: c.now, apps: [app(({ log }) => log('hello'), 'manual')] });
		const run = await hq.scheduler.run('ops', 'morning');
		const at = c.now().getTime();
		expect(run).toMatchObject({ started_at: at, finished_at: at, logs: '2026-03-01T08:00:00.000Z hello' });
		expect(hq.scheduler.runs('ops', 'morning')).toEqual([run]);
	});

	test('bad schedules fail at definition time', () => {
		expect(() => defineAutomation({ slug: 'x', name: 'x', description: '', schedule: 'every tuesday', run: () => {} })).toThrow();
	});
});

describe('run history', () => {
	test('keeps the newest runs per automation, and always the last scheduled one', async () => {
		const hub = Hub.open(':memory:', AUTOMATION_MIGRATIONS);
		const scheduler = new Scheduler(hub, () => new Date(), 3);
		const automation = defineAutomation({ slug: 'tick', name: 'Tick', description: '', schedule: '@every 1h', run: () => 'ok' });
		scheduler.add('ops', automation, {} as AppContext);
		await scheduler.tick();
		for (let i = 0; i < 6; i++) await scheduler.run('ops', 'tick');
		const runs = scheduler.runs('ops', 'tick', 50);
		expect(runs).toHaveLength(4);
		expect(runs.filter((r) => r.trigger === 'schedule')).toHaveLength(1);
	});
});

describe('interrupted runs', () => {
	test('are only marked failed by a scheduler that starts, not by every process that opens the database', () => {
		const path = join(tmpdir(), `hq-runs-${crypto.randomUUID()}.sqlite`);
		const server = createHq({ dbPath: path });
		server.hub.db
			.query(
				"INSERT INTO automation_runs (id, app, slug, trigger, status, started_at) VALUES ('r1', 'ops', 'x', 'manual', 'running', 0)",
			)
			.run();
		const status = () =>
			server.hub.db.query<{ status: string }, []>("SELECT status FROM automation_runs WHERE id = 'r1'").get()?.status;

		createHq({ dbPath: path }).stop();
		expect(status()).toBe('running');

		const restarted = createHq({ dbPath: path, startScheduler: true });
		restarted.stop();
		expect(status()).toBe('failed');
	});
});
