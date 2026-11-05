import { afterAll, describe, expect, test } from 'bun:test';
import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { appFiles, automationFile, connectorFile, register, SLUG } from '../bin/scaffold';

const root = join(import.meta.dir, '..');
const temp: string[] = [];
afterAll(() => temp.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

describe('register', () => {
	const config = `import { defineConfig } from '@hq/sdk';\nimport tasks from './apps/tasks/app';\n\nexport default defineConfig({\n\tassistant,\n\tapps: [tasks],\n\tconnectors: [],\n});\n`;

	test('adds an import and an array entry, idempotently', () => {
		const once = register(config, 'apps', 'standup', './apps/standup/app');
		expect(once).toContain("import tasks from './apps/tasks/app';\nimport standup from './apps/standup/app';");
		expect(once).toContain('apps: [tasks, standup]');
		expect(register(once, 'apps', 'standup', './apps/standup/app')).toBe(once);
		expect(register(config, 'connectors', 'weather', './connectors/weather')).toContain('connectors: [weather]');
	});

	test('refuses names that would not compile', () => {
		expect(() => register(config, 'apps', 'new', './apps/new/app')).toThrow('reserved word');
		expect(() => register(config, 'apps', 'eval', './apps/eval/app')).toThrow('reserved word');
		expect(['release-notes', 'a1', 'x'].every((slug) => SLUG.test(slug))).toBe(true);
		expect(['foo-', 'foo--bar', '1x', '-x', 'a'.repeat(33)].some((slug) => SLUG.test(slug))).toBe(false);
		expect(() => register(config, 'apps', 'defineConfig', './apps/define-config/app')).toThrow('already imported');
		expect(() => register(config, 'connectors', 'tasks', './connectors/tasks')).toThrow('already imported');
		expect(register(config, 'apps', 'app', './apps/app/app')).toContain('apps: [tasks, app]');
		const app = appFiles('standup')['app.ts']!.replace('automations: []', 'automations: [nudge]');
		expect(() => register(app, 'automations', 'changed', './automations/changed')).toThrow('already declared');
		expect(register(app, 'automations', 'pager', './automations/pager')).toContain('automations: [nudge, pager]');
	});

	test('refuses when the array is missing', () => {
		expect(() => register('export default {}', 'automations', 'x', './x')).toThrow('Add `automations: [],` and run this again');
	});
});

describe('generated app', () => {
	test('works as written', async () => {
		const dir = mkdtempSync(join(root, 'apps', '.scaffold-'));
		temp.push(dir);
		for (const [file, text] of Object.entries(appFiles('standup-notes'))) await Bun.write(join(dir, file), text);
		const app = (await import(join(dir, 'app.ts'))).default;
		const { createHq } = await import('../src/hq');
		const hq = createHq({ apps: [app] });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		expect((await hq.registry.call('standup_notes_add', { body: 'hello' }, ctx)).ok).toBe(true);
		const listed = await hq.registry.call('standup_notes_list', {}, ctx);
		expect(listed.ok && (listed.value as { body: string }[])[0]?.body).toBe('hello');
	});

	test('announces a change when an item is added', async () => {
		const dir = mkdtempSync(join(root, 'apps', '.scaffold-'));
		temp.push(dir);
		for (const [file, text] of Object.entries(appFiles('notes'))) await Bun.write(join(dir, file), text);
		const app = (await import(join(dir, 'app.ts'))).default;
		const { createHq } = await import('../src/hq');
		const hq = createHq({ apps: [app] });
		const events: { app: string; name: string }[] = [];
		hq.hub.bus.on((event) => event.type === 'app.event' && events.push(event));
		await hq.registry.call('notes_add', { body: 'hi' }, { hub: hq.hub, caller: hq.assistant.self });
		expect(events).toMatchObject([{ app: 'notes', name: 'changed' }]);
	});

	test('every file is already formatted', async () => {
		const prettier = await import('prettier');
		const files = {
			...appFiles('x'),
			...Object.fromEntries(Object.entries(appFiles('a-very-long-app-slug-of-32-chars')).map(([f, t]) => [`long-${f}`, t])),
			...appFiles('standup-notes', 'Daily notes.'),
			'automations/nudge.ts': automationFile('nudge'),
			'connectors/weather.ts': connectorFile('weather', 'https://api.weather.example'),
		};
		for (const [file, text] of Object.entries(files)) {
			const filepath = join(root, 'apps', 'standup-notes', file);
			const options = await prettier.resolveConfig(filepath);
			expect({ file, formatted: await prettier.check(text, { ...options, filepath }) }).toEqual({ file, formatted: true });
		}
	});
});

describe('hq new (cli)', () => {
	test('app, automation, connector in a copy of the repo', () => {
		const copy = mkdtempSync(join(root, '.scaffold-repo-'));
		temp.push(copy);
		for (const entry of [
			'hq.config.ts',
			'apps',
			'assistant',
			'connectors',
			'src',
			'test',
			'bin',
			'tsconfig.json',
			'package.json',
			'node_modules',
		]) {
			cpSync(join(root, entry), join(copy, entry), { recursive: true, filter: (src) => !src.includes('.scaffold-') });
		}
		const run = (...args: string[]) =>
			Bun.spawnSync(['bun', join(root, 'bin/hq.ts'), ...args], {
				env: { ...process.env, HQ_ROOT: copy, HQ_DB: ':memory:' },
				cwd: copy,
			});
		expect(run('new', 'app', 'standup').exitCode).toBe(0);
		expect(run('new', 'automation', 'nudge', '--app', 'standup').exitCode).toBe(0);
		expect(run('new', 'connector', 'weather', '--base-url', 'https://api.weather.example/v2').exitCode).toBe(0);
		expect(run('new', 'app', 'standup').exitCode).toBe(1);
		const tests = Bun.spawnSync(['bun', 'test', 'apps/standup'], { cwd: copy, env: { ...process.env } });
		expect(tests.exitCode).toBe(0);
		const typecheck = Bun.spawnSync(['bunx', 'tsc', '--noEmit', '-p', 'tsconfig.json'], { cwd: copy });
		expect(typecheck.stdout.toString()).toBe('');
	}, 60_000);
});

describe('scaffold copy', () => {
	test('the briefing is real guidance and descriptions are quoted safely', () => {
		const app = appFiles('standup')['app.ts']!;
		expect(app).toContain("'When someone asks to save something to Standup, use standup_add.");
		expect(app).not.toMatch(/Tell the assistant|One line on what/);
		expect(appFiles('x', "Bo's \\ list")['app.ts']).toContain("description: 'Bo\\'s \\\\ list',");
	});
});
