import { afterEach, describe, expect, setSystemTime, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { migrate, openDatabase } from '../../src/db/database';
import { enrolled, pair } from '../../test/helpers';
import { wire } from '../../test/wire-fixture';
import tasks from './app';
import { REDACTED } from './redact';
import { migrations } from './store';
import { MAX_SESSIONS, SNAPSHOT_MAX_BYTES, transcriptQuotaBytes } from './transcripts';

// What the app decodes, as the fixture says it: every key the server sends is one the app reads (or the fixture lists as the
// helper's), and every key the app requires is there.
function shape(name: string, value: unknown, path = name): string[] {
	const spec = wire.structs[name]!;
	if (typeof value !== 'object' || value === null || Array.isArray(value)) return [`${path}: expected an object`];
	const object = value as Record<string, unknown>;
	const problems: string[] = [];
	for (const key of Object.keys(object))
		if (!(key in spec) && !(wire.ignored[name] ?? []).includes(key))
			problems.push(`${path}.${key}: the app does not decode this`);
	for (const [key, field] of Object.entries(spec)) {
		const present = object[key];
		if (present === undefined || present === null) {
			if (field.required) problems.push(`${path}.${key}: the app requires this`);
			continue;
		}
		if (field.of === undefined) continue;
		if (!field.list) problems.push(...shape(field.of, present, `${path}.${key}`));
		else if (!Array.isArray(present)) problems.push(`${path}.${key}: expected a list`);
		else present.forEach((item, i) => problems.push(...shape(field.of!, item, `${path}.${key}[${i}]`)));
	}
	return problems;
}
const decodes = (name: string, value: unknown) => expect(shape(name, value)).toEqual([]);

// Made up here, at run time: no real-looking key sits in the source.
const fakeKey = () => 'ghp_' + 'Zq7Lm2'.repeat(6);

type Snapshot = {
	projection: string;
	title: string;
	cwd: string;
	git_branch: string | null;
	task_ref: string | null;
	messages: { id: string; role: string; text: string; timestamp: string | null }[];
};

const snap = (over: Partial<Snapshot> = {}): Snapshot => ({
	projection: 'conversation-text-v1',
	title: 'Fix the login',
	cwd: '/work/app',
	git_branch: 'main',
	task_ref: null,
	messages: [
		{ id: 'm1', role: 'user', text: 'hello', timestamp: new Date().toISOString() },
		{ id: 'm2', role: 'assistant', text: 'done', timestamp: null },
	],
	...over,
});

const sha256 = (text: string) => createHash('sha256').update(text).digest('hex');
const envelope = (s: Snapshot) =>
	sha256(
		JSON.stringify([
			s.projection,
			s.title,
			s.cwd,
			s.git_branch,
			s.task_ref,
			s.messages.map((m) => [m.id, m.role, m.text, m.timestamp]),
		]),
	);

async function team() {
	const made = await pair({ apps: [tasks] });
	const { hq, a } = made;
	const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
	hq.hub.conversations.addMember(hq.hub.general().id, cy.id);
	const c = await enrolled(hq, hq.hub.keys.mint(cy.id, 'setup').secret, 'Cy Mac');
	type Who = typeof a;
	const raw = (who: { bearer: string } | null, method: string, path: string, body?: string) =>
		hq.fetch(
			new Request(`http://hq.test${path}`, {
				method,
				headers: { ...(who === null ? {} : { authorization: `Bearer ${who.bearer}` }), 'content-type': 'application/json' },
				body,
			}),
		) as Promise<Response>;
	const put = (who: Who, source: string, snapshot: Snapshot, extra: Record<string, unknown> = {}, provider = 'claude') =>
		who.as('PUT', `/v1/agent-sessions/${provider}/${source}`, { base_revision: 0, snapshot, ...extra });
	const as = (who: Who) => ({ hub: hq.hub, caller: hq.hub.people.get(who.person.id)! });
	const call = async (who: Who, name: string, input: unknown) => {
		const result = await hq.registry.call(name, input, as(who));
		if (!result.ok) throw new Error(result.error);
		return result.value as Record<string, any>;
	};
	const rows = () => hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM agent_sessions').get()!.n;
	return { ...made, cy, c, raw, put, as, call, rows };
}

let saved: string | undefined;
afterEach(() => {
	setSystemTime();
	if (saved === undefined) delete process.env.HQ_TRANSCRIPT_QUOTA_MB;
	else process.env.HQ_TRANSCRIPT_QUOTA_MB = saved;
});

describe("the helper's routes", () => {
	test('a snapshot is stored, read back as sent, and its hash is the one the helper computes', async () => {
		const { a, put, raw, hq } = await team();
		const snapshot = snap();
		const made = await put(a, 's1', snapshot);
		expect(made.status).toBe(200);
		expect(made.body).toMatchObject({
			status: 'synced',
			stored_verbatim: true,
			session: {
				provider: 'claude',
				source_id: 's1',
				revision: 1,
				message_count: 2,
				title: 'Fix the login',
				cwd: '/work/app',
				git_branch: 'main',
				sha256: envelope(snapshot),
				tool_history: false,
				archived_at: null,
				task_ids: [],
				files_touched: null,
			},
		});
		expect(made.body.body_sha256).toMatch(/^[a-f0-9]{64}$/);
		decodes('CodingSession', made.body.session);

		const one = await a.as('GET', '/v1/agent-sessions/claude/s1');
		expect(one.body.session).toEqual(made.body.session);
		const text = await raw(a, 'GET', '/v1/agent-sessions/claude/s1/transcript');
		expect(text.status).toBe(200);
		expect(text.headers.get('x-hq-snapshot-sha256')).toBe(envelope(snapshot));
		expect(text.headers.get('x-hq-revision')).toBe('1');
		expect(text.headers.get('cache-control')).toBe('no-store');
		const stored = await text.text();
		expect(JSON.parse(stored)).toEqual(snapshot);
		expect(made.body.body_sha256).toBe(sha256(stored));
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM agent_session_transcripts').get()).toEqual({ n: 1 });
	});

	test('the hash of a fixed snapshot is the value an independent implementation gives', async () => {
		const { a, put } = await team();
		const fixed = snap({
			messages: [
				{ id: 'm1', role: 'user', text: 'hello é "quoted"   🌳', timestamp: '2026-10-31T09:00:00Z' },
				{ id: 'm2', role: 'assistant', text: 'done', timestamp: null },
			],
		});
		const made = await put(a, 'fixed', fixed);
		expect(made.body.session.sha256).toBe('5128b02646f10c34b419834c68a75de8e78c4ad7d559caf27ef6fb5251a22a22');
	});

	test('the same text again is unchanged; new text replaces the stored body and moves the revision', async () => {
		const { a, put, raw, hq } = await team();
		const same = snap();
		await put(a, 's1', same);
		const again = await put(a, 's1', same);
		expect(again.body).toMatchObject({ status: 'unchanged', stored_verbatim: true, body_sha256: null, session: { revision: 1 } });

		const next = snap({ messages: [{ id: 'm1', role: 'user', text: 'a new thought', timestamp: null }] });
		const second = await put(a, 's1', next, { base_revision: 1 });
		expect(second.body).toMatchObject({ status: 'synced', session: { revision: 2, message_count: 1, sha256: envelope(next) } });
		const read = await (await raw(a, 'GET', '/v1/agent-sessions/claude/s1/transcript')).json();
		expect(read).toEqual(next);
		// Only the latest snapshot is kept.
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM agent_session_transcripts').get()).toEqual({ n: 1 });
		expect(hq.hub.db.query('SELECT COUNT(*) AS n FROM agent_sessions').get()).toEqual({ n: 1 });
	});

	test('a stale base revision is a conflict and changes nothing', async () => {
		const { a, put, raw } = await team();
		await put(a, 's1', snap());
		const changed = snap({ title: 'Other' });
		for (const base of [0, 5]) {
			const refused = await put(a, 's1', changed, { base_revision: base });
			expect(refused.status).toBe(409);
			expect(refused.body).toEqual({ error: 'revision_conflict' });
		}
		expect((await a.as('GET', '/v1/agent-sessions/claude/s1')).body.session).toMatchObject({
			revision: 1,
			title: 'Fix the login',
		});
		expect((await (await raw(a, 'GET', '/v1/agent-sessions/claude/s1/transcript')).json()).title).toBe('Fix the login');
		// A first upload must say it is the first.
		expect((await put(a, 'new', snap(), { base_revision: 1 })).status).toBe(409);
	});

	test('a conversation not yet synced has no transcript to read', async () => {
		const { a, b, call } = await team();
		const { session_id } = await call(a, 'start_session', { provider: 'claude', source_id: 'only-mcp', intent: 'working' });
		expect((await a.as('GET', '/v1/agent-sessions/claude/only-mcp/transcript')).status).toBe(409);
		expect((await a.as('GET', `/v1/agent-sessions/by-id/${session_id}/transcript`)).body).toEqual({ error: 'not_synced_yet' });
		expect((await b.as('GET', `/v1/agent-sessions/by-id/${session_id}/transcript`)).status).toBe(409);
		expect((await a.as('GET', '/v1/agent-sessions/claude/ghost/transcript')).status).toBe(404);
	});

	test('the activity route records time and files for text the server holds, and refuses anything else', async () => {
		const { a, b, put } = await team();
		const made = await put(a, 's1', snap({ messages: [{ id: 'm1', role: 'user', text: 'x', timestamp: null }] }));
		const hash = made.body.session.sha256;
		const at = Date.now() - 1000;
		const ok = await a.as('PUT', '/v1/agent-sessions/claude/s1/activity', {
			sha256: hash,
			activity_at: at,
			files_touched: ['src/a.ts'],
		});
		expect(ok.body).toMatchObject({
			status: 'unchanged',
			session: { activity_at: at, files_touched: ['src/a.ts'], revision: 1 },
		});
		// Time only moves forward.
		const older = await a.as('PUT', '/v1/agent-sessions/claude/s1/activity', { sha256: hash, activity_at: at - 5000 });
		expect(older.body.session).toMatchObject({ activity_at: at, files_touched: ['src/a.ts'] });

		const call = (who: typeof a, body: unknown, source = 's1') =>
			who.as('PUT', `/v1/agent-sessions/claude/${source}/activity`, body);
		expect((await call(a, { sha256: 'f'.repeat(64) })).status).toBe(409);
		expect((await call(a, { sha256: hash }, 'ghost')).status).toBe(404);
		expect((await call(b, { sha256: hash })).status).toBe(404);
		expect((await call(a, { sha256: 'nope' })).status).toBe(400);
		expect((await call(a, { sha256: hash, activity_at: Date.now() + 3_600_000 })).body).toEqual({
			error: 'invalid_activity_time',
		});
		for (const files of [['/etc/passwd'], ['../x'], ['a/../b'], [''], Array.from({ length: 51 }, (_, i) => `f${i}`)]) {
			expect((await call(a, { sha256: hash, files_touched: files })).status).toBe(400);
		}
		expect((await call(a, { sha256: hash, extra: 1 })).status).toBe(400);
	});

	test('archiving hides a session from everyone else and un-archiving brings it back', async () => {
		const { a, b, put } = await team();
		const id = (await put(a, 's1', snap())).body.session.id;
		const archive = (archived: unknown) => a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived });
		const archived = await archive(true);
		expect(archived.body.session.archived_at).toMatch(/^\d{4}-/);
		expect(archived.body.session).toMatchObject({ revision: 1 });
		expect((await b.as('GET', `/v1/agent-sessions/by-id/${id}`)).status).toBe(404);
		expect((await b.as('GET', `/v1/agent-sessions/by-id/${id}/transcript`)).status).toBe(404);
		expect((await a.as('GET', `/v1/agent-sessions/by-id/${id}/transcript`)).status).toBe(200);
		expect((await a.as('GET', '/v1/agent-sessions/claude/s1')).body.session.archived_at).not.toBeNull();
		expect((await archive('yes')).status).toBe(400);
		expect((await a.as('PUT', '/v1/agent-sessions/claude/ghost/archive', { archived: true })).status).toBe(404);
		expect((await b.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: false })).status).toBe(404);

		expect((await archive(false)).body.session.archived_at).toBeNull();
		expect((await b.as('GET', `/v1/agent-sessions/by-id/${id}`)).status).toBe(200);
	});

	test('the owner lists their own, a page at a time, and archived ones only when asked', async () => {
		const { a, b, put } = await team();
		for (let i = 0; i < 53; i++) await put(a, `s${String(i).padStart(2, '0')}`, snap());
		await put(b, 'theirs', snap());
		const first = await a.as('GET', '/v1/agent-sessions');
		expect(first.body.sessions).toHaveLength(50);
		expect(first.body.next_before).toBe(first.body.sessions[49].id);
		decodes('CodingSessionPage', first.body);
		const second = await a.as('GET', `/v1/agent-sessions?before=${first.body.next_before}`);
		expect(second.body.sessions).toHaveLength(3);
		expect(second.body.next_before).toBeNull();
		const everyone = [...first.body.sessions, ...second.body.sessions];
		expect(new Set(everyone.map((s: any) => s.owner_person_id))).toEqual(new Set([a.person.id]));
		expect(new Set(everyone.map((s: any) => s.id)).size).toBe(53);

		await a.as('PUT', '/v1/agent-sessions/claude/s52/archive', { archived: true });
		const plain = (await a.as('GET', '/v1/agent-sessions')).body.sessions;
		expect(plain).toHaveLength(50);
		expect(plain.map((s: any) => s.source_id)).not.toContain('s52');
		const withArchived = (await a.as('GET', '/v1/agent-sessions?include_archived=1')).body.sessions;
		expect(withArchived).toHaveLength(50);
		expect(withArchived.map((s: any) => s.source_id)).toContain('s52');
		expect((await a.as('GET', `/v1/agent-sessions?before=${'x'.repeat(129)}`)).status).toBe(400);
	});

	test('a task_ref links the session to that task; one the owner cannot see is ignored and the snapshot is still stored', async () => {
		const { a, b, put, hq } = await team();
		const made = await a.as('POST', '/v1/tasks', { title: 'Ship docs' });
		const number = made.body.task.number;
		const linked = await put(a, 's1', snap({ task_ref: `HQ-${number}` }));
		expect(linked.body.session.task_ids).toEqual([made.body.task.id]);
		expect(linked.body.session.task_id).toBe(made.body.task.id);
		const byTask = await a.as('GET', `/v1/agent-sessions?task_id=${made.body.task.id}`);
		expect(byTask.body.sessions.map((s: any) => s.source_id)).toEqual(['s1']);
		// The list for a task is the caller's own sessions: Bo has none on it.
		expect((await b.as('GET', `/v1/agent-sessions?task_id=${made.body.task.id}`)).body.sessions).toEqual([]);
		expect((await a.as('GET', '/v1/agent-sessions?task_id=ghost')).body.sessions).toEqual([]);

		const links = (sessionId: string) =>
			hq.hub.db
				.query<{ n: number }, { id: string }>('SELECT COUNT(*) AS n FROM agent_session_tasks WHERE session_id = $id')
				.get({ id: sessionId })!.n;
		const none = await put(a, 's2', snap({ task_ref: 'HQ-' + '9'.repeat(6) }));
		expect([none.status, none.body.status, none.body.session.revision, links(none.body.session.id)]).toEqual([
			200,
			'synced',
			1,
			0,
		]);
		expect((await put(a, 's2', snap({ task_ref: 'nope' }))).body).toEqual({ error: 'invalid_snapshot' });
		const room = hq.hub.conversations.createRoom({ title: 'Private', createdBy: b.person.id });
		const secret = (await hq.registry.call(
			'add_task',
			{ title: 'Raise' },
			{ hub: hq.hub, caller: hq.assistant.self, conversationId: room.id, viewers: [b.person.id] },
		)) as {
			value: { id: string };
		};
		const hidden = hq.hub.db
			.query<{ number: number }, { id: string }>('SELECT number FROM tasks WHERE id = $id')
			.get({ id: secret.value.id })!;
		const unseen = await put(a, 's3', snap({ task_ref: `HQ-${hidden.number}` }));
		expect([unseen.status, unseen.body.status, links(unseen.body.session.id)]).toEqual([200, 'synced', 0]);
	});

	test('a task that goes away later does not stop the conversation syncing', async () => {
		const { a, put, rows } = await team();
		const task = (await a.as('POST', '/v1/tasks', { title: 'Short-lived' })).body.task;
		const ref = snap({ task_ref: `HQ-${task.number}` });
		expect((await put(a, 's1', ref)).body.session.task_ids).toEqual([task.id]);
		expect((await a.as('DELETE', `/v1/tasks/${task.id}`)).status).toBe(200);
		const next = snap({ task_ref: `HQ-${task.number}`, messages: [{ id: 'm9', role: 'user', text: 'later', timestamp: null }] });
		const again = await put(a, 's1', next, { base_revision: 1 });
		expect([again.status, again.body.status, again.body.session.revision, again.body.session.message_count]).toEqual([
			200,
			'synced',
			2,
			1,
		]);
		expect(rows()).toBe(1);
	});

	test('what a snapshot may hold: each limit is exact, one past it is refused', async () => {
		const { a, put } = await team();
		const message = (id: string, text = 'x') => ({ id, role: 'user', text, timestamp: null });
		const ok = [
			snap({ title: 'T'.repeat(200) }),
			snap({ cwd: 'c'.repeat(2048) }),
			snap({ git_branch: 'b'.repeat(256) }),
			snap({ messages: [message('m', 'x'.repeat(500_000))] }),
			snap({ messages: Array.from({ length: 10_000 }, (_, i) => message(`m${i}`)) }),
			snap({ messages: [message('i'.repeat(256))] }),
			snap({ messages: [{ ...message('m'), timestamp: 't'.repeat(64) }] }),
		];
		for (const [i, snapshot] of ok.entries()) expect((await put(a, `ok${i}`, snapshot)).status).toBe(200);
		const bad = [
			snap({ title: 'T'.repeat(201) }),
			snap({ cwd: '' }),
			snap({ cwd: 'c'.repeat(2049) }),
			snap({ git_branch: 'b'.repeat(257) }),
			snap({ messages: [message('m', 'x'.repeat(500_001))] }),
			snap({ messages: Array.from({ length: 10_001 }, (_, i) => message(`m${i}`)) }),
			snap({ messages: [message('i'.repeat(257))] }),
			snap({ messages: [message('')] }),
			snap({ messages: [{ ...message('m'), timestamp: 't'.repeat(65) }] }),
			snap({ messages: [message('same'), message('same')] }),
			snap({ messages: [{ ...message('m'), role: 'system' }] }),
			snap({ projection: 'other' }),
			{ ...snap(), extra: 1 } as Snapshot,
		];
		for (const [i, snapshot] of bad.entries()) {
			const refused = await put(a, `bad${i}`, snapshot);
			expect([i, refused.status, refused.body]).toEqual([i, 400, { error: 'invalid_snapshot' }]);
		}
		expect((await put(a, 'x', snap(), { files_touched: ['/abs'] })).status).toBe(400);
		expect((await put(a, 'x', snap(), { activity_at: Date.now() + 3_600_000 })).body).toEqual({ error: 'invalid_activity_time' });
		expect((await put(a, 'x', snap(), { extra: 1 })).status).toBe(400);
		expect((await a.as('PUT', '/v1/agent-sessions/claude/x', { snapshot: snap() })).status).toBe(400);
		expect((await a.as('PUT', '/v1/agent-sessions/claude/x', { base_revision: -1, snapshot: snap() })).status).toBe(400);
	});

	test('the identity in the path is checked', async () => {
		const { a, put } = await team();
		for (const [provider, source] of [
			['cursor', 's1'],
			['claude', 'has space'],
			['claude', 'a.b'],
			['claude', 'x'.repeat(129)],
		]) {
			const refused = await put(a, source!, snap(), {}, provider);
			expect([provider, source, refused.status, refused.body]).toEqual([provider, source, 400, { error: 'invalid_identity' }]);
			expect((await a.as('GET', `/v1/agent-sessions/${provider}/${source}`)).status).toBe(400);
		}
		expect((await put(a, 'x'.repeat(128), snap(), {}, 'codex')).status).toBe(200);
	});

	test('a body over the cap is refused with 413 before it is read', async () => {
		const { a, raw } = await team();
		const body = (messages: number) =>
			JSON.stringify({
				base_revision: 0,
				snapshot: snap({
					messages: Array.from({ length: messages }, (_, i) => ({
						id: `m${i}`,
						role: 'user',
						text: 'x'.repeat(300_000),
						timestamp: null,
					})),
				}),
			});
		expect(SNAPSHOT_MAX_BYTES).toBe(1_048_576);
		// As many 300 KB messages as fit under the cap, and one more.
		const count = Math.floor(SNAPSHOT_MAX_BYTES / 300_000);
		const fits = body(count);
		expect(fits.length).toBeLessThan(SNAPSHOT_MAX_BYTES);
		expect(body(count + 1).length).toBeGreaterThan(SNAPSHOT_MAX_BYTES);
		expect((await raw(a, 'PUT', '/v1/agent-sessions/claude/fits', fits)).status).toBe(200);
		const over = await raw(a, 'PUT', '/v1/agent-sessions/claude/big', body(count + 1));
		expect(over.status).toBe(413);
		expect(over.headers.get('cache-control')).toBe('no-store');
		expect((await a.as('GET', '/v1/agent-sessions/claude/big')).status).toBe(404);
		// The side routes are small.
		const long = JSON.stringify({ sha256: 'f'.repeat(64), files_touched: [], pad: 'x'.repeat(70_000) });
		expect((await raw(a, 'PUT', '/v1/agent-sessions/claude/fits/activity', long)).status).toBe(413);
		const padded = JSON.stringify({ archived: true, pad: 'x'.repeat(2000) });
		expect((await raw(a, 'PUT', '/v1/agent-sessions/claude/fits/archive', padded)).status).toBe(413);
	});
});

describe('the size of a request', () => {
	test('exactly 1 MiB, envelope included, is taken, and one byte more is not', async () => {
		const { a, raw } = await team();
		// Three messages, the last sized so the whole request body is the wanted number of bytes (it is all ASCII).
		const make = (last: number) =>
			JSON.stringify({
				base_revision: 0,
				snapshot: snap({
					messages: [500_000, 500_000, last].map((n, i) => ({ id: `m${i}`, role: 'user', text: 'x'.repeat(n), timestamp: null })),
				}),
			});
		const sized = (bytes: number) => make(bytes - make(0).length);
		const exact = sized(1_048_576);
		expect(exact.length).toBe(1_048_576);
		expect((await raw(a, 'PUT', '/v1/agent-sessions/claude/exact', exact)).status).toBe(200);
		const more = sized(1_048_577);
		expect(more.length).toBe(1_048_577);
		expect((await raw(a, 'PUT', '/v1/agent-sessions/claude/more', more)).status).toBe(413);
	});
});

describe('the per-person limits on what is stored', () => {
	test('the limit is HQ_TRANSCRIPT_QUOTA_MB, 512 by default', () => {
		expect(transcriptQuotaBytes({})).toBe(512 * 1024 * 1024);
		expect(transcriptQuotaBytes({ HQ_TRANSCRIPT_QUOTA_MB: '1' })).toBe(1024 * 1024);
		expect(transcriptQuotaBytes({ HQ_TRANSCRIPT_QUOTA_MB: ' 2.5 ' })).toBe(2.5 * 1024 * 1024);
		for (const bad of ['', '0', '-3', 'lots', 'NaN'])
			expect(transcriptQuotaBytes({ HQ_TRANSCRIPT_QUOTA_MB: bad })).toBe(512 * 1024 * 1024);
	});

	test('a person over their quota gets 413 quota_exceeded; others and smaller replacements are not affected', async () => {
		const { a, b, put } = await team();
		const text = (n: number) => snap({ messages: [{ id: 'm', role: 'user', text: 'x'.repeat(n), timestamp: null }] });
		const first = await put(a, 'one', text(1400));
		const size: number = first.body.session.bytes;
		saved = process.env.HQ_TRANSCRIPT_QUOTA_MB;
		process.env.HQ_TRANSCRIPT_QUOTA_MB = String((size * 1.5) / (1024 * 1024));

		const over = await put(a, 'two', text(1400));
		expect(over.status).toBe(413);
		expect(over.body).toEqual({ error: 'quota_exceeded' });
		expect((await a.as('GET', '/v1/agent-sessions/claude/two')).status).toBe(404);
		// Another person has their own allowance.
		expect((await put(b, 'two', text(1400))).status).toBe(200);
		// Growing the stored one past the limit is refused too, and nothing changes.
		const grown = await put(a, 'one', text(2600), { base_revision: 1 });
		expect(grown.status).toBe(413);
		expect((await a.as('GET', '/v1/agent-sessions/claude/one')).body.session.revision).toBe(1);
		// A smaller one is always allowed, and gives room back.
		expect((await put(a, 'one', text(100), { base_revision: 1 })).status).toBe(200);
		expect((await put(a, 'two', text(1000))).status).toBe(200);
		// Even with the limit lowered under what is held, a person can still shrink.
		process.env.HQ_TRANSCRIPT_QUOTA_MB = '0.0001';
		expect((await put(a, 'two', text(50), { base_revision: 1 })).status).toBe(200);
		expect((await put(a, 'two', text(500), { base_revision: 2 })).status).toBe(413);
	});

	test('a person may hold only so many sessions', async () => {
		const { a, b, put, hq } = await team();
		const insert = hq.hub.db.query(
			`INSERT INTO agent_sessions (id, owner_id, provider, source_id, state, last_seen_at, created_at, updated_at)
			VALUES ($id, $owner, 'claude', $source, 'idle', 0, 1, 1)`,
		);
		hq.hub.db.transaction(() => {
			for (let i = 0; i < MAX_SESSIONS; i++) insert.run({ id: `fill-${i}`, owner: a.person.id, source: `fill-${i}` });
		})();
		const refused = await put(a, 'one-more', snap());
		expect([refused.status, refused.body]).toEqual([413, { error: 'session_limit' }]);
		// It is a different limit from the stored-text quota: raising HQ_TRANSCRIPT_QUOTA_MB does not lift it.
		saved = process.env.HQ_TRANSCRIPT_QUOTA_MB;
		process.env.HQ_TRANSCRIPT_QUOTA_MB = '100000';
		expect((await put(a, 'one-more', snap())).body).toEqual({ error: 'session_limit' });
		expect((await put(b, 'fine', snap())).status).toBe(200);
		// A session already held can still be updated.
		expect((await put(a, 'fill-1', snap())).status).toBe(200);
	});
});

describe('removing a session by hand', () => {
	// The statements in docs/sessions.md and SECURITY.md, in the order they give: foreign keys are on and nothing cascades.
	const statements = (id: string) => [
		`DELETE FROM agent_session_transcripts WHERE session_id = '${id}'`,
		`DELETE FROM agent_session_tasks WHERE session_id = '${id}'`,
		`DELETE FROM agent_sessions WHERE id = '${id}'`,
	];

	async function linked() {
		const world = await team();
		const task = (await world.a.as('POST', '/v1/tasks', { title: 'Linked' })).body.task;
		const made = await world.put(world.a, 's1', snap({ task_ref: `HQ-${task.number}` }));
		return { ...world, id: made.body.session.id as string };
	}

	test('in the documented order the session goes, with its text and task links', async () => {
		const { hq, id } = await linked();
		const count = (table: string, column: string) =>
			hq.hub.db.query<{ n: number }, { id: string }>(`SELECT COUNT(*) AS n FROM ${table} WHERE ${column} = $id`).get({ id })!.n;
		expect([
			count('agent_session_transcripts', 'session_id'),
			count('agent_session_tasks', 'session_id'),
			count('agent_sessions', 'id'),
		]).toEqual([1, 1, 1]);
		for (const sql of statements(id)) hq.hub.db.exec(sql);
		expect([
			count('agent_session_transcripts', 'session_id'),
			count('agent_session_tasks', 'session_id'),
			count('agent_sessions', 'id'),
		]).toEqual([0, 0, 0]);
	});

	test('the session first is refused by the foreign keys, which is why the order is given', async () => {
		const { hq, id } = await linked();
		expect(() => hq.hub.db.exec(statements(id)[2]!)).toThrow(/FOREIGN KEY/);
	});

	test('both docs give those statements', () => {
		for (const file of ['docs/sessions.md', 'SECURITY.md']) {
			const text = readFileSync(join(import.meta.dir, '../..', file), 'utf8');
			const at = statements('<id>').map((sql) => text.indexOf(sql));
			expect([file, at.every((i) => i >= 0), at.toSorted((x, y) => x - y)]).toEqual([file, true, at]);
		}
	});
});

describe('one row for a conversation, however it was reported', () => {
	test('a synced conversation and an MCP-reported session with the same source are one row', async () => {
		const { a, put, call, rows } = await team();
		const started = await call(a, 'start_session', {
			provider: 'claude',
			source_id: 's1',
			title: 'Agent title',
			intent: 'reading the code',
		});
		const synced = await put(a, 's1', snap({ title: 'Synced title' }));
		expect(synced.body.session.id).toBe(started.session_id);
		expect(rows()).toBe(1);
		// The agent's own check-ins carry on, on the same row.
		const checked = await call(a, 'check_session', { session_id: started.session_id, intent: 'testing' });
		expect(checked).toMatchObject({ id: started.session_id, title: 'Agent title', intent: 'testing', state: 'active' });
		// A sync leaves the agent's state alone.
		await put(a, 's1', snap({ title: 'Third' }), { base_revision: 1 });
		const listed = await call(a, 'active_sessions', {});
		expect(listed).toMatchObject([{ id: started.session_id, state: 'active', title: 'Agent title', intent: 'testing' }]);
		await call(a, 'check_session', { session_id: started.session_id, state: 'ended' });
		await put(a, 's1', snap({ title: 'Fourth' }), { base_revision: 2 });
		expect(await call(a, 'active_sessions', {})).toMatchObject([{ id: started.session_id, state: 'ended' }]);

		// The other way round: synced first, then the agent reports.
		const first = await put(a, 's2', snap());
		const joined = await call(a, 'start_session', { provider: 'claude', source_id: 's2', intent: 'now' });
		expect(joined.session_id).toBe(first.body.session.id);
		expect(rows()).toBe(2);
		expect((await a.as('GET', '/v1/agent-sessions/claude/s2')).body.session.revision).toBe(1);
	});

	test('a sync never makes an old backfill active, and a new row starts idle', async () => {
		const { a, b, put, call, hq } = await team();
		const old = new Date(Date.now() - 3 * 86_400_000).toISOString();
		const made = await put(a, 'old', snap({ messages: [{ id: 'm1', role: 'user', text: 'long ago', timestamp: old }] }));
		expect(made.body.session.activity_at).toBe(Date.parse(old));
		const row = hq.hub.db.query('SELECT state, last_seen_at FROM agent_sessions').get();
		expect(row).toEqual({ state: 'idle', last_seen_at: 0 });
		// Syncing it again changes neither its state nor its check-in time.
		await put(a, 'old', snap({ title: 'Edited', messages: [{ id: 'm1', role: 'user', text: 'long ago', timestamp: old }] }), {
			base_revision: 1,
		});
		expect(hq.hub.db.query('SELECT state, last_seen_at FROM agent_sessions').get()).toEqual({ state: 'idle', last_seen_at: 0 });
		const active = await b.as('GET', '/v1/agent-sessions/active?since_minutes=1440');
		expect(active.body.sessions).toEqual([]);
		expect(await call(a, 'active_sessions', { since_minutes: 1440 })).toEqual([]);

		// A conversation with a message from a minute ago is on the board, idle until its agent checks in.
		const recent = new Date(Date.now() - 60_000).toISOString();
		await put(a, 'recent', snap({ messages: [{ id: 'm1', role: 'user', text: 'now', timestamp: recent }] }));
		const board = await b.as('GET', '/v1/agent-sessions/active');
		expect(board.body.sessions).toHaveLength(1);
		expect(board.body.sessions[0]).toMatchObject({ state: 'idle', last_seen_at: 0, provider: 'claude', owner_name: 'Ada' });
		expect(Math.abs(board.body.sessions[0].last_activity_at - Date.parse(recent))).toBeLessThan(1000);
		// Stamps from the future count as now, not later.
		const future = new Date(Date.now() + 30_000).toISOString();
		const soon = await put(a, 'soon', snap({ messages: [{ id: 'm1', role: 'user', text: 'x', timestamp: future }] }));
		expect(soon.body.session.activity_at).toBeLessThanOrEqual(Date.now());
		const far = new Date(Date.now() + 86_400_000).toISOString();
		const ignored = await put(a, 'far', snap({ messages: [{ id: 'm1', role: 'user', text: 'x', timestamp: far }] }));
		expect(ignored.body.session.activity_at).toBeNull();
		// The helper's own activity time counts too, but never from the future.
		const stamped = await put(a, 'stamped', snap({ messages: [{ id: 'm1', role: 'user', text: 'x', timestamp: null }] }), {
			activity_at: Date.now() - 5000,
		});
		expect(stamped.body.session.activity_at).toBeGreaterThan(Date.now() - 6000);
	});

	test('nothing a conversation says reaches the MCP tools or the old sessions route', async () => {
		const { a, b, put, call } = await team();
		const text = 'zebra-crossing-unique-phrase';
		const cwd = '/Users/ada/zebra-private-folder';
		await call(a, 'start_session', { provider: 'claude', source_id: 's1', intent: 'plain intent' });
		await put(
			a,
			's1',
			snap({
				title: `Title ${text}`,
				cwd,
				git_branch: 'zebra-branch-name',
				messages: [{ id: 'm1', role: 'user', text, timestamp: new Date().toISOString() }],
			}),
		);
		const seen = JSON.stringify([
			await call(a, 'active_sessions', {}),
			await call(b, 'active_sessions', {}),
			await call(a, 'start_session', { provider: 'claude', source_id: 's1', intent: 'again' }),
			await call(a, 'link_session_tasks', {
				session_id: (await a.as('GET', '/v1/agent-sessions/claude/s1')).body.session.id,
				task_ids: [],
			}),
			(await a.as('GET', '/apps/tasks/api/sessions?since_minutes=1440')).body,
		]);
		expect(seen).not.toContain('zebra');
		expect(seen).toContain('plain intent');
	});
});

describe('who reads what', () => {
	async function shared() {
		const world = await team();
		const key = fakeKey();
		const snapshot = snap({
			title: `Debug with ${key}`,
			cwd: '/Users/ada/private-folder',
			git_branch: 'main',
			messages: [
				{ id: 'm1', role: 'user', text: `my key is ${key} please use it`, timestamp: new Date().toISOString() },
				{ id: 'm2', role: 'assistant', text: 'Authorization: Basic dXNlcjpwYXNz', timestamp: null },
			],
		});
		const made = await world.put(world.a, 's1', snapshot, { files_touched: ['src/secret-area.ts'] });
		return { ...world, key, snapshot, id: made.body.session.id as string };
	}

	test('the owner reads their text as stored; everyone else gets secrets hidden, no hash and no folder', async () => {
		const { a, b, c, raw, key, snapshot, id } = await shared();
		const mine = await raw(a, 'GET', `/v1/agent-sessions/by-id/${id}/transcript`);
		expect(await mine.json()).toEqual(snapshot);
		expect(mine.headers.get('x-hq-snapshot-sha256')).toBe(envelope(snapshot));

		for (const who of [b, c]) {
			const theirs = await raw(who, 'GET', `/v1/agent-sessions/by-id/${id}/transcript`);
			expect(theirs.status).toBe(200);
			expect(theirs.headers.get('x-hq-snapshot-sha256')).toBeNull();
			expect(theirs.headers.get('x-hq-revision')).toBe('1');
			expect(theirs.headers.get('cache-control')).toBe('no-store');
			const text = await theirs.text();
			expect(text).not.toContain(key);
			expect(text).not.toContain('dXNlcjpwYXNz');
			expect(text).not.toContain('private-folder');
			const body = JSON.parse(text);
			expect('cwd' in body).toBe(false);
			expect(body.title).toBe(`Debug with ${REDACTED}`);
			expect(body.messages.map((m: any) => m.text)).toEqual([`my key is ${REDACTED} please use it`, REDACTED]);
			expect(body.messages[0]).toMatchObject({ id: 'm1', role: 'user' });
			decodes('CodingTranscript', body);
		}
		// The owner's route works for the owner only, and the same text comes from by-id for them.
		expect((await b.as('GET', '/v1/agent-sessions/claude/s1/transcript')).status).toBe(404);
	});

	test('the detail and the board show others a trimmed, redacted session; the owner sees all of theirs', async () => {
		const { a, b, key, id } = await shared();
		const own = await a.as('GET', `/v1/agent-sessions/by-id/${id}`);
		decodes('CodingThreadDetail', own.body);
		expect(own.body.session).toMatchObject({
			cwd: '/Users/ada/private-folder',
			files_touched: ['src/secret-area.ts'],
			title: `Debug with ${key}`,
		});
		expect(own.body.thread.title).toBe(`Debug with ${key}`);

		// The app asks with ?open=1; another member gets the same answer without it.
		const open = await b.as('GET', `/v1/agent-sessions/by-id/${id}?open=1`);
		expect((await b.as('GET', `/v1/agent-sessions/by-id/${id}`)).body).toEqual(open.body);
		decodes('CodingThreadDetail', open.body);
		const text = JSON.stringify(open.body);
		expect(text).not.toContain(key);
		expect(text).not.toContain('private-folder');
		expect(text).not.toContain('secret-area');
		expect(open.body.session).toMatchObject({ id, sha256: null, title: `Debug with ${REDACTED}`, revision: 1, message_count: 2 });
		for (const hidden of ['cwd', 'files_touched', 'bytes']) expect(hidden in open.body.session).toBe(false);
		expect((await b.as('GET', '/v1/agent-sessions/by-id/ghost')).status).toBe(404);

		const board = await b.as('GET', '/v1/agent-sessions/active');
		decodes('CodingThreadPage', board.body);
		expect(JSON.stringify(board.body)).not.toContain(key);
		expect(board.body.sessions).toHaveLength(1);
		expect(board.body.sessions[0]).toMatchObject({
			session_id: id,
			owner_person_id: a.person.id,
			title: `Debug with ${REDACTED}`,
			tasks: [],
			projects: [],
		});
		// The owner's own board shows it as stored.
		expect((await a.as('GET', '/v1/agent-sessions/active')).body.sessions[0].title).toBe(`Debug with ${key}`);
	});

	test('an archived session leaves the board and the other members', async () => {
		const { a, b, id } = await shared();
		await a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: true });
		expect((await b.as('GET', '/v1/agent-sessions/active')).body.sessions).toEqual([]);
		expect((await a.as('GET', '/v1/agent-sessions/active')).body.sessions).toEqual([]);
		expect((await b.as('GET', `/v1/agent-sessions/by-id/${id}`)).status).toBe(404);
	});

	test("task titles in a session follow the viewer's task visibility", async () => {
		const { a, b, hq, id, call } = await shared();
		const room = hq.hub.conversations.createRoom({ title: 'Comp', createdBy: a.person.id });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		const added = (await hq.registry.call(
			'add_task',
			{ title: 'Raise for Cy' },
			{ ...ctx, conversationId: room.id, viewers: [a.person.id] },
		)) as { value: { id: string } };
		const privateTask = added.value.id;
		const publicTask = (await a.as('POST', '/v1/tasks', { title: 'Ship docs' })).body.task;
		const project = (await a.as('POST', '/v1/projects', { name: 'Launch' })).body.project;
		await a.as('PATCH', `/v1/tasks/${publicTask.id}`, { project_ids: [project.id] });
		await call(a, 'link_session_tasks', { session_id: id, task_ids: [privateTask, publicTask.id] });

		const number = (taskId: string) =>
			hq.hub.db.query<{ number: number }, { id: string }>('SELECT number FROM tasks WHERE id = $id').get({ id: taskId })!.number;
		const mine = await a.as('GET', '/v1/agent-sessions/active');
		expect(mine.body.sessions[0].tasks).toEqual([
			{ id: privateTask, ref: `HQ-${number(privateTask)}`, title: 'Raise for Cy' },
			{ id: publicTask.id, ref: `HQ-${number(publicTask.id)}`, title: 'Ship docs' },
		]);
		expect(mine.body.sessions[0].projects).toEqual([{ id: project.id, name: 'Launch' }]);
		decodes('CodingThreadPage', mine.body);

		const theirs = await b.as('GET', '/v1/agent-sessions/active');
		expect(theirs.body.sessions[0].tasks).toEqual([
			{ id: publicTask.id, ref: `HQ-${number(publicTask.id)}`, title: 'Ship docs' },
		]);
		const detail = await b.as('GET', `/v1/agent-sessions/by-id/${id}?open=1`);
		expect(JSON.stringify(detail.body)).not.toContain('Raise for Cy');
		expect(JSON.stringify(detail.body)).not.toContain(privateTask);
		expect(detail.body.session.task_ids).toEqual([publicTask.id]);
		expect((await a.as('GET', `/v1/agent-sessions/by-id/${id}?open=1`)).body.session.task_ids).toEqual([
			privateTask,
			publicTask.id,
		]);
	});

	test('a removed person is frozen: their sessions stay readable, as their messages do, and they can no longer write', async () => {
		const world = await team();
		const { a, b, c, put } = world;
		const made = await put(b, 'bo-chat', snap({ title: 'Bo’s chat' }));
		expect((await a.as('POST', `/v1/people/${b.person.id}/remove`)).status).toBe(200);
		const read = await a.as('GET', `/v1/agent-sessions/by-id/${made.body.session.id}?open=1`);
		expect(read.status).toBe(200);
		expect(read.body.session.title).toBe('Bo’s chat');
		expect((await c.as('GET', `/v1/agent-sessions/by-id/${made.body.session.id}/transcript`)).status).toBe(200);
		// Their own device is refused: they cannot list, write or archive any more.
		expect((await b.as('GET', '/v1/agent-sessions')).status).toBe(401);
		expect((await put(b, 'later', snap())).status).toBe(401);
		expect((await b.as('PUT', '/v1/agent-sessions/claude/bo-chat/archive', { archived: true })).status).toBe(401);
	});
});

describe('who may call', () => {
	test("only a signed-in device: a script key, an MCP key and no key at all are refused, and one person can't reach another's routes", async () => {
		const { a, b, hq, put, raw } = await team();
		await put(a, 's1', snap());
		const id = (await a.as('GET', '/v1/agent-sessions/claude/s1')).body.session.id;
		const routes: [string, string, string?][] = [
			['GET', '/v1/agent-sessions'],
			['GET', '/v1/agent-sessions/active'],
			['GET', '/v1/agent-sessions/claude/s1'],
			['GET', '/v1/agent-sessions/claude/s1/transcript'],
			['GET', `/v1/agent-sessions/by-id/${id}`],
			['GET', `/v1/agent-sessions/by-id/${id}/transcript`],
			['PUT', '/v1/agent-sessions/claude/s1', JSON.stringify({ base_revision: 1, snapshot: snap() })],
			['PUT', '/v1/agent-sessions/claude/s1/activity', JSON.stringify({ sha256: 'f'.repeat(64) })],
			['PUT', '/v1/agent-sessions/claude/s1/archive', JSON.stringify({ archived: true })],
		];
		for (const kind of ['mcp', 'key'] as const) {
			const secret = hq.hub.keys.mint(b.person.id, kind).secret;
			for (const [method, path, body] of routes) {
				const refused = await raw({ bearer: secret }, method, path, body);
				expect([kind, method, path, refused.status, await refused.json()]).toEqual([
					kind,
					method,
					path,
					403,
					{ error: 'device_only' },
				]);
				expect(refused.headers.get('cache-control')).toBe('no-store');
			}
		}
		for (const [method, path, body] of routes) expect((await raw(null, method, path, body)).status).toBe(401);
		expect((await raw({ bearer: 'hq_nope' }, 'GET', '/v1/agent-sessions')).status).toBe(401);

		// Bo's routes by identity are Bo's: Ada's source id is not there.
		expect((await b.as('GET', '/v1/agent-sessions/claude/s1')).status).toBe(404);
		expect((await b.as('GET', '/v1/agent-sessions/claude/s1/transcript')).status).toBe(404);
		expect((await b.as('GET', '/v1/agent-sessions')).body.sessions).toEqual([]);
		// Writing to the same source id makes Bo's own row; Ada's is untouched.
		const bos = await put(b, 's1', snap({ title: 'Bo' }));
		expect(bos.body.session.id).not.toBe(id);
		expect((await a.as('GET', '/v1/agent-sessions/claude/s1')).body.session.title).toBe('Fix the login');
	});

	test('every answer is no-store, errors included', async () => {
		const { a, raw } = await team();
		for (const [method, path, body] of [
			['GET', '/v1/agent-sessions', undefined],
			['GET', '/v1/agent-sessions/active?limit=0', undefined],
			['GET', '/v1/agent-sessions/claude/ghost', undefined],
			['GET', '/v1/agent-sessions/by-id/ghost/transcript', undefined],
			['PUT', '/v1/agent-sessions/claude/x', 'not json'],
		] as const) {
			const answer = await raw(a, method, path, body);
			expect([path, answer.headers.get('cache-control')]).toEqual([path, 'no-store']);
			expect(answer.headers.get('x-content-type-options')).toBe('nosniff');
		}
		expect((await raw(a, 'PUT', '/v1/agent-sessions/claude/x', 'not json')).status).toBe(400);
	});

	test('what is not in this server answers 404', async () => {
		const { a, put, raw } = await team();
		await put(a, 's1', snap());
		for (const [method, path] of [
			['GET', '/v1/agent-sessions/claude/s1/tools/0'],
			['PUT', '/v1/agent-sessions/claude/s1/tools/0'],
			['POST', '/v1/agent-sessions/claude/s1/hook'],
			['GET', '/v1/agent-sessions/claude/s1/messages'],
			['POST', '/v1/agent-sessions/claude/s1/messages/ack'],
			['PUT', '/v1/agent-sessions/sync-status'],
			['GET', '/v1/agent-sessions/coverage'],
			['PATCH', '/v1/agent-sessions/claude/s1/tasks'],
		] as const) {
			const answer = await raw(a, method, path, '{}');
			expect([method, path, answer.status]).toEqual([method, path, 404]);
		}
	});
});

describe('the board', () => {
	test('pages in id order with a cursor, within the window, and refuses bad queries', async () => {
		const { a, b, c, put } = await team();
		for (const [who, source] of [
			[a, 'a1'],
			[b, 'b1'],
			[c, 'c1'],
			[a, 'a2'],
			[b, 'b2'],
		] as const) {
			await put(who, source, snap({ messages: [{ id: 'm', role: 'user', text: 'x', timestamp: new Date().toISOString() }] }));
		}
		const first = await c.as('GET', '/v1/agent-sessions/active?limit=2');
		expect(first.body.sessions).toHaveLength(2);
		expect(first.body.next_cursor).toBe(first.body.sessions[1].session_id);
		const seen = [...first.body.sessions];
		let cursor: string | null = first.body.next_cursor;
		while (cursor !== null) {
			const page: any = (await c.as('GET', `/v1/agent-sessions/active?limit=2&cursor=${cursor}`)).body;
			seen.push(...page.sessions);
			cursor = page.next_cursor;
		}
		expect(seen.map((s: any) => s.session_id)).toEqual(seen.map((s: any) => s.session_id).toSorted());
		expect(new Set(seen.map((s: any) => s.owner_name))).toEqual(new Set(['Ada', 'Bo', 'Cy']));
		expect(seen).toHaveLength(5);
		decodes('CodingThreadPage', { sessions: seen, next_cursor: null });

		// 50 at most; everything else in the query is checked.
		expect((await c.as('GET', '/v1/agent-sessions/active?limit=51')).status).toBe(400);
		expect((await c.as('GET', '/v1/agent-sessions/active?limit=0')).status).toBe(400);
		expect((await c.as('GET', '/v1/agent-sessions/active?since_minutes=0')).status).toBe(400);
		expect((await c.as('GET', '/v1/agent-sessions/active?since_minutes=1441')).status).toBe(400);
		expect((await c.as('GET', '/v1/agent-sessions/active?cursor=' + 'x'.repeat(129))).status).toBe(400);
		expect((await c.as('GET', '/v1/agent-sessions/active?limit=50&since_minutes=1440')).status).toBe(200);
	});

	test('the window is since_minutes (10 by default), counted from the newest of an agent check-in and a message', async () => {
		const { a, b, put, call } = await team();
		const ago = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();
		const msg = (minutes: number) => snap({ messages: [{ id: 'm', role: 'user', text: 'x', timestamp: ago(minutes) }] });
		await put(a, 'five', msg(5));
		await put(a, 'thirty', msg(30));
		await put(a, 'day', msg(1300));
		await call(b, 'start_session', { provider: 'claude', source_id: 'mcp-now', intent: 'just reported' });
		const sources = async (query = '') => {
			const board = (await a.as('GET', `/v1/agent-sessions/active${query}`)).body.sessions;
			return board.map((s: any) => s.intent || s.title).toSorted();
		};
		expect((await sources()).length).toBe(2);
		expect((await sources('?since_minutes=60')).length).toBe(3);
		expect((await sources('?since_minutes=1440')).length).toBe(4);
		// An agent-reported session shows too: it is the same list.
		expect(await sources()).toContain('just reported');
	});
});

describe('the synced branch and archived sessions stay out of the MCP tools', () => {
	test('the branch a conversation was on reaches the app (hidden from others if it looks like a secret) and no MCP tool or old route', async () => {
		const { a, b, put, call } = await team();
		const branch = `fix/${fakeKey()}`;
		const mcp = await call(a, 'start_session', { provider: 'claude', source_id: 's1', intent: 'x', branch: 'agent-branch' });
		const made = await put(a, 's1', snap({ git_branch: branch }));
		expect(made.body.session.git_branch).toBe(branch);
		const reported = JSON.stringify([
			await call(a, 'active_sessions', {}),
			await call(b, 'active_sessions', {}),
			(await a.as('GET', '/apps/tasks/api/sessions?since_minutes=1440')).body,
			(await b.as('GET', '/apps/tasks/api/sessions?since_minutes=1440')).body,
		]);
		expect(reported).not.toContain('fix/');
		expect(reported).toContain('agent-branch');
		// The app: the owner reads it as stored, another member with the secret hidden.
		const own = (await a.as('GET', `/v1/agent-sessions/by-id/${mcp.session_id}`)).body;
		expect([own.thread.git_branch, own.session.git_branch]).toEqual([branch, branch]);
		const theirs = (await b.as('GET', `/v1/agent-sessions/by-id/${mcp.session_id}?open=1`)).body;
		expect([theirs.thread.git_branch, theirs.session.git_branch]).toEqual(['fix/[REDACTED]', 'fix/[REDACTED]']);
		expect((await b.as('GET', '/v1/agent-sessions/active')).body.sessions[0].git_branch).toBe('fix/[REDACTED]');
		// A session with no synced branch shows the one its agent reported.
		await call(a, 'start_session', { provider: 'claude', source_id: 'only-mcp', intent: 'y', branch: 'agent-only' });
		await put(a, 'later', snap({ git_branch: null }));
		const board = (await a.as('GET', '/v1/agent-sessions/active')).body.sessions;
		expect(board.map((t: any) => t.git_branch).toSorted()).toEqual([branch, 'agent-only', null].toSorted());
		// A later snapshot with no branch clears the synced one (the agent's own stays).
		await put(a, 's1', snap({ git_branch: null, title: 'again' }), { base_revision: 1 });
		expect((await a.as('GET', `/v1/agent-sessions/by-id/${mcp.session_id}`)).body.thread.git_branch).toBe('agent-branch');
	});

	test('an archived session shows to no other member through the MCP tool or the old route, and is its owner’s still', async () => {
		const { a, b, put, call, hq, as } = await team();
		await put(a, 's1', snap());
		await call(a, 'start_session', { provider: 'claude', source_id: 's1', intent: 'visible until archived' });
		const handles = async (who: typeof a) => [
			(await call(who, 'active_sessions', {})).map((x: any) => x.owner.handle),
			(await who.as('GET', '/apps/tasks/api/sessions?since_minutes=1440')).body.map((x: any) => x.owner.handle),
		];
		expect(await handles(b)).toEqual([['ada'], ['ada']]);
		await a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: true });
		expect(await handles(b)).toEqual([[], []]);
		expect(await handles(a)).toEqual([['ada'], ['ada']]);
		// Asked with others looking on (the tool's `viewers`), it is the owner's alone no longer: nobody else's eyes see it.
		const watched = await hq.registry.call('active_sessions', {}, { ...as(a), viewers: [b.person.id] });
		expect(watched).toMatchObject({ ok: true, value: [] });

		// An archived session does not use up the owner's 50: even the newest one, archived, leaves all 50 others showing.
		for (let i = 0; i < 50; i++) await call(a, 'start_session', { provider: 'claude', source_id: `n${i}`, intent: 'now' });
		setSystemTime(new Date(Date.now() + 5000));
		await call(a, 'start_session', { provider: 'claude', source_id: 's1', intent: 'newest' });
		await a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: true });
		expect((await handles(b)).map((list) => list.length)).toEqual([50, 50]);
	});

	test('an agent reporting in again makes an archived session live; un-archiving puts an ended one back to idle', async () => {
		const { a, put, call, hq } = await team();
		const state = (source: string) =>
			hq.hub.db
				.query<{ state: string; archived_at: number | null }, { source: string }>(
					'SELECT state, archived_at FROM agent_sessions WHERE source_id = $source',
				)
				.get({ source })!;
		await put(a, 's1', snap());
		await a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: true });
		expect(state('s1')).toMatchObject({ state: 'ended' });
		expect(state('s1').archived_at).not.toBeNull();
		await a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: false });
		expect(state('s1')).toEqual({ state: 'idle', archived_at: null });

		await a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: true });
		await call(a, 'start_session', { provider: 'claude', source_id: 's1', intent: 'back at it' });
		expect(state('s1')).toEqual({ state: 'active', archived_at: null });
		// Un-archiving what was never archived leaves its state alone.
		await a.as('PUT', '/v1/agent-sessions/claude/s1/archive', { archived: false });
		expect(state('s1')).toEqual({ state: 'active', archived_at: null });
	});
});

describe('the board holds a limit per person', () => {
	test('one member with many current conversations shows their newest 50 and leaves room for everyone else', async () => {
		const { a, b, c, put, hq } = await team();
		const at = Date.now();
		// Bo has 60 conversations, the n-th active n seconds before now, written straight in: no need to sync 60 times.
		const insert = hq.hub.db.query(
			`INSERT INTO agent_sessions (id, owner_id, provider, source_id, state, last_seen_at, created_at, updated_at, activity_at)
			VALUES ($id, $owner, 'claude', $source, 'idle', 0, 1, 1, $at)`,
		);
		hq.hub.db.transaction(() => {
			for (let i = 0; i < 60; i++)
				insert.run({ id: `bo-${String(i).padStart(2, '0')}`, owner: b.person.id, source: `bo${i}`, at: at - i * 1000 });
		})();
		await put(a, 'ada-one', snap({ messages: [{ id: 'm', role: 'user', text: 'x', timestamp: new Date().toISOString() }] }));

		const walk = async (limit: number) => {
			const seen: any[] = [];
			let cursor: string | null = null;
			let pages = 0;
			do {
				const page: any = (
					await c.as('GET', `/v1/agent-sessions/active?limit=${limit}${cursor === null ? '' : `&cursor=${cursor}`}`)
				).body;
				seen.push(...page.sessions);
				cursor = page.next_cursor;
				pages++;
			} while (cursor !== null);
			return { seen, pages };
		};
		const wide = await walk(50);
		expect(wide.seen).toHaveLength(51);
		expect(wide.pages).toBe(2);
		const bos = wide.seen.filter((t) => t.owner_name === 'Bo').map((t) => t.session_id);
		// The newest 50 of Bo's: the ten oldest are the ones left off.
		expect(bos.toSorted()).toEqual(Array.from({ length: 50 }, (_, i) => `bo-${String(i).padStart(2, '0')}`));
		expect(wide.seen.filter((t) => t.owner_name === 'Ada')).toHaveLength(1);
		// Small pages see the same set, once each.
		const narrow = await walk(7);
		expect(narrow.seen.map((t) => t.session_id).toSorted()).toEqual(wide.seen.map((t) => t.session_id).toSorted());
		expect(narrow.pages).toBe(8);
	});
});

describe('existing rows', () => {
	test('keep their ids and everything an agent reported when the sync columns are added', () => {
		const db = openDatabase();
		db.exec('CREATE TABLE people (id TEXT PRIMARY KEY); CREATE TABLE conversations (id TEXT PRIMARY KEY);');
		db.exec("INSERT INTO people (id) VALUES ('ada')");
		migrate(db, migrations.slice(0, 2));
		db.exec(
			`INSERT INTO agent_sessions (id, owner_id, provider, source_id, title, intent, repo, branch, state, last_seen_at, created_at, updated_at)
			VALUES ('s1', 'ada', 'claude', 'abc', 'T', 'I', 'r', 'b', 'active', 500, 100, 400)`,
		);
		const applied = migrate(db, migrations);
		expect(applied.length).toBe(migrations.length - 2);
		expect(applied).toContain('010_synced_sessions');
		expect(applied).toContain('011_session_transcripts');
		expect(db.query('SELECT * FROM agent_sessions').all()).toEqual([
			{
				id: 's1',
				owner_id: 'ada',
				provider: 'claude',
				source_id: 'abc',
				title: 'T',
				intent: 'I',
				repo: 'r',
				branch: 'b',
				state: 'active',
				last_seen_at: 500,
				created_at: 100,
				updated_at: 400,
				cwd: '',
				synced_title: '',
				revision: 0,
				sha256: '',
				bytes: 0,
				message_count: 0,
				activity_at: null,
				archived_at: null,
				files_touched: null,
				synced_branch: null,
			},
		]);
	});
});
