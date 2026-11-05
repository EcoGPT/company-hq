import { Database } from 'bun:sqlite';
import { afterAll, describe, expect, test } from 'bun:test';
import { existsSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const temp: string[] = [];
afterAll(() => temp.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

function tempDir() {
	const dir = mkdtempSync(join(tmpdir(), 'hq-cli-'));
	temp.push(dir);
	return dir;
}

// A test-only connector with no verify step, so saving its secret never calls the network.
const preload = join(tempDir(), 'sample-connector.ts');
writeFileSync(
	preload,
	`import config from ${JSON.stringify(join(import.meta.dir, '../hq.config.ts'))};
config.connectors = [...(config.connectors ?? []), { slug: 'sample', name: 'Sample', description: 'Test only.', tools: [] }];
`,
);

function hq(args: string[], env: Record<string, string>, stdin?: string) {
	const result = Bun.spawnSync(['bun', '--preload', preload, join(import.meta.dir, '../bin/hq.ts'), ...args], {
		env: { ...process.env, ...env },
		cwd: env.CWD,
		stdin: stdin === undefined ? 'ignore' : new TextEncoder().encode(stdin),
	});
	return { code: result.exitCode, out: result.stdout.toString(), err: result.stderr.toString() };
}

describe('hq cli', () => {
	test('--help on a command prints its usage and does nothing', () => {
		const dir = tempDir();
		const help = hq(['setup', '--help'], { CWD: dir, HQ_DB: join(dir, 'hq.sqlite') });
		expect(help.code).toBe(0);
		expect(help.out).toContain('Usage: bun hq setup');
		expect(existsSync(join(dir, '.env'))).toBe(false);
		expect(existsSync(join(dir, 'hq.sqlite'))).toBe(false);
	});

	test('setup, invite, doctor, chat', async () => {
		const dir = tempDir();
		const env = { CWD: dir, HQ_DB: join(dir, 'hq.sqlite') };
		const setup = hq(['setup', '--handle', 'ada', '--name', 'Ada', '--provider', 'ollama', '--model', 'qwen3:14b'], env);
		expect(setup.code).toBe(0);
		const written = await Bun.file(join(dir, '.env')).text();
		expect(written).not.toMatch(/^HQ_VAULT_KEY=/m);
		expect(written).toContain('HQ_LLM_BASE_URL=http://localhost:11434/v1\nHQ_LLM_MODEL=qwen3:14b\n');
		expect(setup.out).toMatch(/Key\s+hq_/);
		expect(setup.out).toMatch(/Server\s+http:/);
		expect(hq(['setup'], env).out).toContain('already has an admin');
		const db = new Database(join(dir, 'hq.sqlite'), { readonly: true });
		expect(
			db
				.query<{ body: string }, []>('SELECT body FROM messages')
				.all()
				.map((m) => m.body)
				.join(),
		).toContain('Welcome to HQ, Ada.');
		db.close();

		expect(hq(['invite', 'bo', '--name', 'Bo'], env).out).toContain('@bo added');
		expect(hq(['invite', 'bo', '--admin'], env).code).toBe(1);
		const again = hq(['invite', '@bo'], env);
		expect(again.out).toContain('New key for @bo.');
		expect(again.out).toMatch(/Key\s+hq_/);

		expect(hq(['connect'], env).out).toMatch(/github\s+not connected/);
		const connected = hq(['connect', 'sample'], env, 'sample-secret\n');
		expect(connected.out).toContain('Sample connected');
		expect(connected.err).toContain('Paste the Sample secret and press Enter');
		expect(hq(['connect'], env).out).toMatch(/sample\s+connected/);
		expect(hq(['disconnect', 'sample'], env).out).toContain('Sample disconnected.');
		expect(hq(['disconnect', 'sample'], env).out).toContain('was not connected');

		expect(hq(['revoke', 'bo'], env).out).toContain('Revoked 1 key for @bo.');
		expect(hq(['revoke', 'bo'], env).out).toContain('@bo had no active keys.');

		const doctor = hq(['doctor'], env);
		expect(doctor.out).toContain('people      3');
		expect(doctor.out).toContain('add_task');

		const chat = hq(['chat'], { ...env, HQ_LLM_PROVIDER: 'mock' }, 'hello there\n');
		expect(chat.code).toBe(0);
		expect(chat.out).toContain('You said: hello there');

		expect(hq(['invite', '--admin', 'cy'], env).out).toContain('@cy added');
		expect(hq(['invite', '@di'], env).out).toContain('@di added');
		expect(hq(['chat', '--as', '@ada'], { ...env, HQ_LLM_PROVIDER: 'mock' }, 'hi\n').out).toContain('as @ada');
		expect(hq(['chat', '--as', 'nobody'], env).err).toContain('Nobody has the handle @nobody.');
		expect(hq(['key', 'nobody'], env).err).toContain('Nobody has the handle @nobody.');
		expect(hq(['key'], env).err).toContain('Usage: bun hq key <handle>');
	}, 30_000);

	test('an invite signs in devices and nothing else, and the newest one replaces the rest', async () => {
		const dir = tempDir();
		const env = { CWD: dir, HQ_DB: join(dir, 'hq.sqlite'), HQ_LLM_PROVIDER: 'mock' };
		const setup = hq(['setup', '--handle', 'ada', '--name', 'Ada'], env);
		expect(setup.out).toContain('Lost the key? `bun hq invite ada` makes a new one and ends this one.');
		const keyOf = (out: string) => /Key\s+(\S+)/.exec(out)![1]!;
		const first = hq(['invite', 'bo', '--name', 'Bo'], env);
		expect(first.out).toContain('They can add each of their devices with it for 7 days');
		const second = hq(['invite', 'bo'], env);
		const { createHq } = await import('../src/hq');
		const server = createHq({ dbPath: join(dir, 'hq.sqlite') });
		const enroll = (key: string) =>
			server.fetch(new Request('http://hq.test/v1/enroll', { method: 'POST', body: JSON.stringify({ key }) }));
		expect((await enroll(keyOf(first.out)))?.status).toBe(401);
		const phone = await (await enroll(keyOf(second.out)))!.json();
		expect((await enroll(keyOf(second.out)))?.status).toBe(201);
		const me = (key: string) =>
			server.fetch(new Request('http://hq.test/v1/me', { headers: { authorization: `Bearer ${key}` } }));
		expect((await me(keyOf(second.out)))?.status).toBe(401);
		expect((await me(phone.bearer))?.status).toBe(200);
		expect(hq(['revoke', 'bo'], env).out).toContain('Revoked 3 keys for @bo.');
		expect(hq(['key', 'bo'], env).code).toBe(0);
		server.stop();
	}, 30_000);

	test('the setup key signs in devices and is never a bearer; `bun hq invite` ends it and keeps their devices', async () => {
		const dir = tempDir();
		const env = { CWD: dir, HQ_DB: join(dir, 'hq.sqlite'), HQ_LLM_PROVIDER: 'mock' };
		const keyOf = (out: string) => /Key\s+(\S+)/.exec(out)![1]!;
		const setupKey = keyOf(hq(['setup', '--handle', 'ada', '--name', 'Ada'], env).out);
		const { createHq } = await import('../src/hq');
		const server = createHq({ dbPath: join(dir, 'hq.sqlite') });
		const call = (path: string, key: string | null, init: RequestInit = {}) =>
			server.fetch(
				new Request(`http://hq.test${path}`, {
					method: 'POST',
					...init,
					headers: key === null ? {} : { authorization: `Bearer ${key}` },
				}),
			);
		const enroll = (key: string) => call('/v1/enroll', null, { body: JSON.stringify({ key }) });
		for (const path of ['/v1/me', '/v1/conversations']) {
			expect((await call(path, setupKey, { method: 'GET' }))?.status).toBe(401);
		}
		expect((await call('/mcp', setupKey, { body: '{}' }))?.status).toBe(401);
		const device = await (await enroll(setupKey))!.json();
		expect((await enroll(setupKey))?.status).toBe(201);
		expect((await call('/v1/me', device.bearer, { method: 'GET' }))?.status).toBe(200);

		const invite = hq(['invite', 'ada'], env);
		expect((await enroll(setupKey))?.status).toBe(401);
		expect((await enroll(keyOf(invite.out)))?.status).toBe(201);
		expect((await call('/v1/me', device.bearer, { method: 'GET' }))?.status).toBe(200);
		server.stop();
	}, 30_000);

	test('`bun hq key` always makes a plain key, whatever its label says, and refuses a removed person', async () => {
		const dir = tempDir();
		const env = { CWD: dir, HQ_DB: join(dir, 'hq.sqlite'), HQ_LLM_PROVIDER: 'mock' };
		hq(['setup', '--handle', 'ada', '--name', 'Ada'], env);
		hq(['invite', 'bo', '--name', 'Bo'], env);
		const { createHq } = await import('../src/hq');
		const server = createHq({ dbPath: join(dir, 'hq.sqlite') });
		const bo = server.hub.people.byHandle('bo')!;
		const labels = ['setup', 'invite', 'device', 'mcp', 'laptop'];
		for (const label of labels) {
			const key = hq(['key', 'bo', '--label', label], env).out.trim();
			const enrolling = await server.fetch(
				new Request('http://hq.test/v1/enroll', { method: 'POST', body: JSON.stringify({ key }) }),
			);
			expect(enrolling?.status).toBe(401);
			const me = await server.fetch(new Request('http://hq.test/v1/me', { headers: { authorization: `Bearer ${key}` } }));
			expect(me?.status).toBe(200);
		}
		const made = server.hub.keys.list(bo.id).filter((k) => k.kind === 'key');
		expect(made.map((k) => k.label)).toEqual(labels);
		// Their invite from `bun hq invite` is untouched: only it and the keys above exist besides.
		expect(
			server.hub.keys
				.list(bo.id)
				.filter((k) => k.kind !== 'key')
				.map((k) => k.kind),
		).toEqual(['invite']);

		server.hub.people.setRemoved(bo.id, Date.now());
		const refused = hq(['key', 'bo'], env);
		expect(refused.code).toBe(1);
		expect(refused.err).toContain('@bo was removed');
		expect(refused.out).toBe('');
		server.stop();
	}, 30_000);

	test('setup keeps the vault key next to the database, and keeps one already set', async () => {
		const dir = tempDir();
		const data = join(dir, 'data');
		const env = { CWD: dir, HQ_DB: join(data, 'hq.sqlite') };
		await Bun.write(join(dir, '.env'), await Bun.file(join(import.meta.dir, '../.env.example')).text());
		expect(hq(['setup', '--handle', 'ada'], env).code).toBe(0);
		expect(await Bun.file(join(dir, '.env')).text()).not.toMatch(/^HQ_VAULT_KEY=/m);
		const key = await Bun.file(join(data, 'vault.key')).text();
		expect(key).toMatch(/^\S{20,}\n$/);
		expect(statSync(join(data, 'vault.key')).mode & 0o777).toBe(0o600);

		const elsewhere = tempDir();
		expect(hq(['connect', 'sample'], { ...env, CWD: elsewhere }, 'sample-secret\n').out).toContain('Sample connected');
		expect(hq(['setup', '--handle', 'ada'], env).code).toBe(0);
		expect(await Bun.file(join(data, 'vault.key')).text()).toBe(key);
		expect(hq(['connect'], { ...env, CWD: elsewhere }).out).toMatch(/sample\s+connected/);

		const kept = tempDir();
		await Bun.write(join(kept, '.env'), 'HQ_VAULT_KEY=keep-this-key\n');
		expect(hq(['setup', '--handle', 'ada'], { CWD: kept, HQ_DB: join(kept, 'hq.sqlite') }).code).toBe(0);
		expect(await Bun.file(join(kept, '.env')).text()).toBe('HQ_VAULT_KEY=keep-this-key\n');
		expect(existsSync(join(kept, 'vault.key'))).toBe(false);
	}, 30_000);

	test('help lists every command; an unknown command fails', () => {
		const help = hq(['help'], {});
		expect(help.code).toBe(0);
		for (const name of ['setup', 'invite', 'key', 'connect', 'disconnect', 'new', 'chat', 'doctor']) {
			expect(help.out).toContain(`\n  ${name}`);
		}
		const unknown = hq(['nope'], {});
		expect(unknown.code).toBe(1);
		expect(unknown.err).toContain('Unknown command: nope');
	});
});

describe('welcome', () => {
	test('names the model, or says how to pick one', async () => {
		const { welcome } = await import('../bin/welcome');
		expect(welcome('Ada Lovelace', 'atlas', 'qwen3:14b')).toStartWith('Welcome to HQ, Ada.');
		expect(welcome('Ada', 'atlas', 'qwen3:14b')).toContain("I'm running on qwen3:14b.");
		expect(welcome('Ada', 'atlas', null)).toContain('bun hq setup');
	});
});
