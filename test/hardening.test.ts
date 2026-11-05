import { afterEach, describe, expect, test } from 'bun:test';
import { existsSync, readdirSync } from 'node:fs';
import type { Server } from 'bun';
import { CORE_MIGRATIONS } from '../src/core/hub';
import { People } from '../src/core/people';
import { migrate, openDatabase } from '../src/db/database';
import { createHq } from '../src/hq';
import type { SocketData } from '../src/realtime/socket';
import { RateLimiter } from '../src/wire/rate-limit';
import { admin, connect, enrolled, pair, say, serve, type Connection } from './helpers';

type Signed = Awaited<ReturnType<typeof enrolled>>;
type Hq = ReturnType<typeof createHq>;
type Streamed = RequestInit & { duplex: 'half' };

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
const MB = 1024 * 1024;

let server: Server<SocketData> | undefined;
let open: Connection[] = [];
afterEach(() => {
	for (const connection of open) connection.ws.close();
	open = [];
	void server?.stop(true);
	server = undefined;
});

const send = (hq: Hq, who: Signed | null, method: string, path: string, body?: BodyInit, headers: Record<string, string> = {}) =>
	hq.fetch(
		new Request(`http://hq.test${path}`, {
			method,
			body,
			headers: { ...(who === null ? {} : { authorization: `Bearer ${who.bearer}` }), ...headers },
			...(body instanceof ReadableStream ? { duplex: 'half' } : {}),
		} as Streamed),
	) as Promise<Response>;

const upload = (hq: Hq, who: Signed, conversationId: string, body: BodyInit, headers: Record<string, string> = {}) =>
	send(hq, who, 'POST', `/v1/conversations/${conversationId}/attachments`, body, {
		'content-type': 'text/plain',
		'x-hq-file-name': 'notes.txt',
		...headers,
	});

/** A body of `total` bytes in `chunk`-byte pieces that counts how much of it anyone actually read. */
function counted(total: number, chunk: number) {
	let sent = 0;
	const stream = new ReadableStream<Uint8Array>({
		pull(controller) {
			if (sent >= total) return controller.close();
			sent += chunk;
			controller.enqueue(new Uint8Array(chunk));
		},
	});
	return { stream, read: () => sent };
}

const from = (address: string) => ({ requestIP: () => ({ address }) }) as unknown as Server<never>;
const enrollFrom = (hq: Hq, address: string, body: unknown) =>
	hq.fetch(
		new Request('http://hq.test/v1/enroll', { method: 'POST', body: JSON.stringify(body) }),
		from(address) as never,
	) as Promise<Response>;

describe('enrolling is limited by failures only', () => {
	test('a correct key gets in from an address that has used up its failed tries', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const key = hq.hub.keys.mint(ada.person.id, 'setup').secret;
		for (let i = 0; i < 20; i++) expect((await enrollFrom(hq, '203.0.113.9', { key: 'hq_junk' })).status).toBe(401);
		expect((await enrollFrom(hq, '203.0.113.9', { key: 'hq_junk' })).status).toBe(429);
		expect((await enrollFrom(hq, '203.0.113.9', { key })).status).toBe(201);
	});

	test('good enrolls are not counted: thirty devices from one address, and the junk budget is still whole', async () => {
		const hq = createHq();
		const ada = admin(hq);
		const key = hq.hub.keys.mint(ada.person.id, 'setup').secret;
		for (let i = 0; i < 30; i++) expect((await enrollFrom(hq, '198.51.100.4', { key })).status).toBe(201);
		for (let i = 0; i < 20; i++) expect((await enrollFrom(hq, '198.51.100.4', { key: 'hq_junk' })).status).toBe(401);
		expect((await enrollFrom(hq, '198.51.100.4', { key: 'hq_junk' })).status).toBe(429);
	});
});

describe('request bodies are capped', () => {
	test('enroll refuses a declared body over 4 KB, and stops reading a streamed one', async () => {
		const hq = createHq();
		admin(hq);
		const declared = await send(hq, null, 'POST', '/v1/enroll', '{"key":"hq_x"}', { 'content-length': String(95 * MB) });
		expect(declared.status).toBe(413);
		const body = counted(20 * MB, 16 * 1024);
		const streamed = await send(hq, null, 'POST', '/v1/enroll', body.stream);
		expect([400, 413]).toContain(streamed.status);
		expect(body.read()).toBeLessThan(MB);
	});

	test('other JSON routes stop at 1 MB, with a code', async () => {
		const { hq, a, room } = await pair();
		const too = await send(hq, a, 'POST', `/v1/conversations/${room.id}/messages`, '{}', { 'content-length': String(2 * MB) });
		expect(too.status).toBe(413);
		expect(await too.json()).toEqual({ error: 'payload_too_large' });
		const body = counted(30 * MB, 64 * 1024);
		const streamed = await send(hq, a, 'POST', `/v1/conversations/${room.id}/messages`, body.stream, {
			'content-type': 'application/json',
		});
		expect(streamed.status).toBe(413);
		expect(body.read()).toBeLessThan(4 * MB);
		const mcp = await send(hq, a, 'POST', '/mcp', '{}', { 'content-length': String(2 * MB) });
		expect(mcp.status).toBe(413);
		expect(await mcp.json()).toEqual({ error: 'payload_too_large' });
		// A body that does not say how long it is gets the same answer, not a JSON-RPC parse error.
		const chunked = counted(30 * MB, 64 * 1024);
		const cut = await send(hq, a, 'POST', '/mcp', chunked.stream, { 'content-type': 'application/json' });
		expect([cut.status, await cut.json()]).toEqual([413, { error: 'payload_too_large' }]);
		expect(chunked.read()).toBeLessThan(4 * MB);
	});

	test('only the upload routes get the upload limit, and they still stream under it', async () => {
		const { hq, a, room } = await pair({ maxUploadBytes: 3 * MB });
		expect((await upload(hq, a, room.id, new Uint8Array(2 * MB + 5))).status).toBe(201);
		expect((await upload(hq, a, room.id, new Uint8Array(3 * MB + 1))).status).toBe(413);
		const body = counted(40 * MB, 256 * 1024);
		const streamed = await upload(hq, a, room.id, body.stream);
		expect(streamed.status).toBe(413);
		expect(body.read()).toBeLessThan(8 * MB);
		const picture = await send(hq, a, 'PUT', '/v1/me/avatar', PNG, { 'content-type': 'image/png' });
		expect(picture.status).toBe(200);
	});

	test('a real server turns a 20 MB enroll away', async () => {
		const hq = createHq();
		admin(hq);
		server = serve(hq);
		const response = await fetch(`http://localhost:${server.port}/v1/enroll`, { method: 'POST', body: new Uint8Array(20 * MB) });
		expect(response.status).toBe(413);
	});
});

describe('edit history', () => {
	test('every version stays in the database; a payload carries the last 20; the conversation list carries none', async () => {
		const { hq, a, b, room } = await pair();
		server = serve(hq);
		const watcher = await connect(server, b.bearer);
		open.push(watcher);
		const message = (await say(a.as, room.id, 'v0')).body.message;
		for (let i = 1; i <= 30; i++) await a.as('PATCH', `/v1/messages/${message.id}`, { content: `v${i}` });
		await watcher.settle();

		expect(
			hq.hub.db.query<{ n: number }, [string]>('SELECT COUNT(*) AS n FROM message_edits WHERE message_id = ?').get(message.id)!.n,
		).toBe(30);
		const wanted = Array.from({ length: 20 }, (_, i) => `v${i + 10}`);
		const page = (await b.as('GET', `/v1/conversations/${room.id}/messages`)).body.messages[0];
		expect(page.content).toBe('v30');
		expect(page.edit_history.map((r: { content: string }) => r.content)).toEqual(wanted);
		const frames = watcher.frames.filter((f) => f.type === 'message_updated');
		expect(frames.at(-1)!.message.edit_history.map((r: { content: string }) => r.content)).toEqual(wanted);
		expect(frames.every((f) => f.message.edit_history.length <= 20)).toBe(true);

		const last = (await b.as('GET', '/v1/conversations')).body.conversations.find(
			(c: { id: string }) => c.id === room.id,
		).last_message;
		expect(last).toMatchObject({ id: message.id, content: 'v30', edit_history: [] });
		expect(last.edited_at).not.toBeNull();
	});
});

describe('profile pictures', () => {
	const put = (hq: Hq, who: Signed, body: BodyInit, type = 'image/png', path = '/v1/me/avatar') =>
		send(hq, who, 'PUT', path, body, { 'content-type': type });
	const HEIC = new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63, 0, 0, 0, 0]);
	const WEBP = new Uint8Array([0x52, 0x49, 0x46, 0x46, 4, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 1, 2]);

	test('png, jpeg, heic and webp that really are; never svg', async () => {
		const { hq, a, b } = await pair();
		for (const [bytes, type] of [
			[PNG, 'image/png'],
			[JPEG, 'image/jpeg'],
			[HEIC, 'image/heic'],
			[WEBP, 'image/webp'],
		] as const) {
			const set = await put(hq, a, bytes, type);
			expect([type, set.status]).toEqual([type, 200]);
			const id = (await set.json()).person.avatar_id;
			const got = await send(hq, b, 'GET', `/v1/avatars/people/${a.person.id}/${id}`);
			expect(got.headers.get('content-type')).toBe(type);
			expect(new Uint8Array(await got.arrayBuffer())).toEqual(bytes);
		}
		expect((await put(hq, a, '<svg xmlns="http://www.w3.org/2000/svg"/>', 'image/svg+xml')).status).toBe(415);
		expect((await put(hq, a, WEBP, 'image/heic')).status).toBe(415);
		expect((await put(hq, a, HEIC, 'image/webp')).status).toBe(415);
		expect((await put(hq, a, JPEG, 'image/png')).status).toBe(415);
		expect(readdirSync(hq.hub.files.path('avatars', 'people', a.person.id))).toHaveLength(1);
	});

	test('a streamed body is cut off at 5 MiB, not read whole, and leaves no file behind', async () => {
		const { hq, a } = await pair();
		const body = counted(60 * MB, 256 * 1024);
		const refused = await put(hq, a, body.stream);
		expect(refused.status).toBe(413);
		expect(body.read()).toBeLessThan(10 * MB);
		const folder = hq.hub.files.path('avatars', 'people', a.person.id);
		expect(existsSync(folder) ? readdirSync(folder) : []).toEqual([]);
		expect(hq.hub.people.get(a.person.id)!.avatar_id).toBeNull();
	});

	test('two uploads at once do not delete each other’s file', async () => {
		const { hq, a, b } = await pair();
		let finish!: () => void;
		const stalled = new ReadableStream<Uint8Array>({
			start(controller) {
				controller.enqueue(PNG);
				finish = () => controller.close();
			},
		});
		const slow = put(hq, a, stalled);
		const folder = hq.hub.files.path('avatars', 'people', a.person.id);
		for (let i = 0; i < 100 && !(existsSync(folder) && readdirSync(folder).some((n) => n.endsWith('.part'))); i++)
			await Bun.sleep(5);
		expect(readdirSync(folder).some((n) => n.endsWith('.part'))).toBe(true);

		const quick = await put(hq, a, JPEG, 'image/jpeg');
		expect(quick.status).toBe(200);
		expect(readdirSync(folder).some((n) => n.endsWith('.part'))).toBe(true);
		finish();
		const done = await slow;
		expect(done.status).toBe(200);

		const id = (await done.json()).person.avatar_id;
		expect((await send(hq, b, 'GET', `/v1/avatars/people/${a.person.id}/${id}`)).status).toBe(200);
		expect(readdirSync(folder)).toHaveLength(1);
	});
});

describe('storage limits', () => {
	test('a person’s uploads are capped by bytes; the error says so, nothing is deleted, others are unaffected', async () => {
		const { hq, a, b, room } = await pair({ uploadQuotaBytes: 1000 });
		const mine = await upload(hq, a, room.id, new Uint8Array(600));
		expect(mine.status).toBe(201);
		const over = await upload(hq, a, room.id, new Uint8Array(600));
		expect(over.status).toBe(413);
		expect(await over.json()).toEqual({ error: 'quota_exceeded' });
		expect((await upload(hq, a, room.id, new Uint8Array(10), { 'content-length': '5000' })).status).toBe(413);
		const theirs = await upload(hq, b, room.id, new Uint8Array(600));
		expect(theirs.status).toBe(201);
		// Sending the file, or unsending the message, gives nothing back: no file is ever deleted.
		const sent = (await say(a.as, room.id, 'here', { attachment_ids: [(await mine.json()).attachment.id] })).body.message;
		await a.as('DELETE', `/v1/messages/${sent.id}`);
		expect((await upload(hq, a, room.id, new Uint8Array(600))).status).toBe(413);
		expect(readdirSync(hq.hub.files.path('attachments', room.id))).toHaveLength(2);
		expect(hq.hub.db.query<{ n: number }, []>('SELECT COUNT(*) AS n FROM attachments').get()!.n).toBe(2);
	});

	test('uploads arriving at once share the quota: 5 of 400 KB against 1 MB never store more than 1 MB', async () => {
		const { hq, a, room } = await pair({ uploadQuotaBytes: MB });
		let open!: () => void;
		const gate = new Promise<void>((resolve) => (open = resolve));
		// No declared length, so each upload could be anything up to the cap until its last byte.
		const arriving = () =>
			new ReadableStream<Uint8Array>({
				async pull(controller) {
					await gate;
					controller.enqueue(new Uint8Array(400 * 1024));
					controller.close();
				},
			});
		const sent = Array.from({ length: 5 }, () => upload(hq, a, room.id, arriving()));
		await Bun.sleep(50);
		open();
		const answers = await Promise.all(sent);
		const stored = hq.hub.db.query<{ n: number }, []>('SELECT COALESCE(SUM(byte_size), 0) AS n FROM attachments').get()!.n;
		expect(stored).toBeLessThanOrEqual(MB);
		expect(answers.filter((r) => r.status === 201).length).toBeGreaterThanOrEqual(1);
		for (const refused of answers.filter((r) => r.status !== 201)) {
			expect([refused.status, (await refused.json()).error]).toEqual([413, 'quota_exceeded']);
		}
		expect(readdirSync(hq.hub.files.path('attachments', room.id)).filter((n) => n.endsWith('.part'))).toEqual([]);
		// What an upload held back is given up when it ends, so the room that is left can be used.
		const left = MB - stored;
		expect((await upload(hq, a, room.id, new Uint8Array(left))).status).toBe(201);
	});

	test('a reservation is released when an upload fails, so a failed one never blocks the next', async () => {
		const { hq, a, room } = await pair({ uploadQuotaBytes: MB, maxUploadBytes: 600 * 1024 });
		const body = counted(5 * MB, 64 * 1024);
		expect((await upload(hq, a, room.id, body.stream)).status).toBe(413);
		const broken = new ReadableStream<Uint8Array>({
			pull() {
				throw new Error('connection lost');
			},
		});
		await upload(hq, a, room.id, broken).catch(() => {});
		expect((await upload(hq, a, room.id, new Uint8Array(500 * 1024))).status).toBe(201);
	});

	test('HQ_UPLOAD_QUOTA_MB sets it when booted (2048 when unset)', async () => {
		const { boot } = await import('../src/boot');
		const { hq } = boot({ HQ_DB: ':memory:', HQ_UPLOAD_QUOTA_MB: '7' });
		const ada = hq.hub.people.create({ name: 'Ada', handle: 'ada' });
		hq.hub.conversations.addMember(hq.hub.general().id, ada.id);
		const who = await enrolled(hq, hq.hub.keys.mint(ada.id, 'setup').secret);
		const refused = await upload(hq, who, hq.hub.general().id, 'x', { 'content-length': String(7 * MB + 1) });
		expect([refused.status, (await refused.json()).error]).toEqual([413, 'quota_exceeded']);
		hq.stop();
	});

	test('at most 20 uploads wait unattached; sending one frees a place', async () => {
		const { hq, a, b, room } = await pair();
		const made: string[] = [];
		for (let i = 0; i < 20; i++) {
			const response = await upload(hq, a, room.id, `file ${i}`);
			expect(response.status).toBe(201);
			made.push((await response.json()).attachment.id);
		}
		const refused = await upload(hq, a, room.id, 'one more');
		expect(refused.status).toBe(429);
		expect(await refused.json()).toEqual({ error: 'too_many_uploads' });
		expect((await upload(hq, b, room.id, 'mine')).status).toBe(201);
		expect((await say(a.as, room.id, 'sent', { attachment_ids: [made[0]!] })).status).toBe(201);
		expect((await upload(hq, a, room.id, 'now it fits')).status).toBe(201);
		expect((await upload(hq, a, room.id, 'but not another')).status).toBe(429);
		expect(readdirSync(hq.hub.files.path('attachments', room.id))).toHaveLength(22);
	});
});

describe('the sign-in limiter at scale', () => {
	test('50,000 addresses are tracked cheaply and the table stays bounded', () => {
		let t = 0;
		const limiter = new RateLimiter(20, 300_000, () => t);
		const started = performance.now();
		for (let i = 0; i < 50_000; i++) {
			t += 1;
			limiter.admit(`2001:db8::${i.toString(16)}`);
		}
		const took = performance.now() - started;
		expect(took).toBeLessThan(1000);
		expect(limiter.size).toBeLessThanOrEqual(10_000);
		// The newest sources are still counted; one that went quiet for the whole window is forgotten.
		for (let i = 0; i < 19; i++) limiter.admit('newest');
		expect(limiter.admit('newest')).toBe(0);
		expect(limiter.admit('newest')).toBeGreaterThan(0);
		t += 300_001;
		limiter.admit('later');
		expect(limiter.size).toBe(1);
	});
});

describe('socket limits', () => {
	const fake = () => {
		const clock = { now: 1_000_000 };
		return { clock, options: { socket: { clock: () => clock.now } } };
	};

	test('frames over 64 KB close the socket', async () => {
		const { hq, a } = await pair();
		expect(hq.websocket.maxPayloadLength).toBe(64 * 1024);
		server = serve(hq);
		const connection = await connect(server, a.bearer);
		connection.send('x'.repeat(100 * 1024));
		// 1009 (too big) on the wire; Bun's client reports a connection dropped on a protocol error as 1006.
		expect([1006, 1009]).toContain(await connection.closed);
		const small = await connect(server, a.bearer);
		open.push(small);
		small.send('x'.repeat(60 * 1024));
		await small.settle();
		expect(small.ws.readyState).toBe(WebSocket.OPEN);
	});

	test('asking for the next page of a replay is not held to the pace; asking again from anywhere else is', async () => {
		const { options } = fake();
		const { hq, ada, a, room } = await pair(options);
		for (let i = 0; i < 520; i++) hq.hub.messages.send({ conversationId: room.id, authorId: ada.person.id, body: `m${i}` });
		server = serve(hq);
		const connection = await connect(server, a.bearer);
		open.push(connection);
		connection.send({ type: 'sync', since_message_id: '' });
		expect((await connection.take('sync_complete')).is_partial).toBe(true);
		const last = connection.frames
			.filter((f) => f.type === 'sync_batch')
			.at(-1)!
			.messages.at(-1).id;
		connection.send({ type: 'sync', since_message_id: '' });
		const refused = await connection.take('sync_complete');
		expect(refused.is_partial).toBe(true);
		expect(connection.frames.filter((f) => f.type === 'sync_batch')).toHaveLength(5);
		connection.send({ type: 'sync', since_message_id: last });
		const next = await connection.take('sync_complete');
		expect(next.is_partial).toBe(false);
		expect(connection.frames.filter((f) => f.type === 'sync_batch').length).toBeGreaterThan(5);
		// The allowance is used up by that page: another immediate ask for the same page is a repeat.
		const served = connection.frames.length;
		connection.send({ type: 'sync', since_message_id: last });
		expect((await connection.take('sync_complete')).is_partial).toBe(true);
		expect(connection.frames.slice(served).some((f) => f.type === 'sync_batch')).toBe(false);
	});

	test('typing is passed on once a second per connection', async () => {
		const { clock, options } = fake();
		const { hq, a, b, room } = await pair(options);
		server = serve(hq);
		const typist = await connect(server, a.bearer);
		const watcher = await connect(server, b.bearer);
		open.push(typist, watcher);
		const typings = () => watcher.frames.filter((f) => f.type === 'typing').length;
		for (let i = 0; i < 5; i++) typist.send({ type: 'typing', conversation_id: room.id });
		await typist.settle();
		await watcher.settle();
		expect(typings()).toBe(1);
		clock.now += 999;
		typist.send({ type: 'typing', conversation_id: room.id });
		await typist.settle();
		await watcher.settle();
		expect(typings()).toBe(1);
		clock.now += 1;
		typist.send({ type: 'typing', conversation_id: room.id });
		await typist.settle();
		await watcher.settle();
		expect(typings()).toBe(2);
	});

	test('sync is served once every 2 seconds per connection; the excess is dropped but still answered', async () => {
		const { clock, options } = fake();
		const { a, hq, room } = await pair(options);
		await say(a.as, room.id, 'one');
		server = serve(hq);
		const connection = await connect(server, a.bearer);
		open.push(connection);
		const batches = () => connection.frames.filter((f) => f.type === 'sync_batch').length;
		connection.send({ type: 'sync' });
		const first = await connection.take('sync_complete');
		expect(first.is_partial).toBe(false);
		expect(batches()).toBe(1);
		connection.send({ type: 'sync' });
		const dropped = await connection.take('sync_complete');
		expect(dropped.is_partial).toBe(true);
		expect(batches()).toBe(1);
		clock.now += 2_000;
		connection.send({ type: 'sync' });
		expect((await connection.take('sync_complete')).is_partial).toBe(false);
		expect(batches()).toBe(2);
	});

	test('a person keeps 10 connections; the 11th closes the oldest with 4000', async () => {
		const { hq, a, b } = await pair();
		server = serve(hq);
		const sockets: Connection[] = [];
		for (let i = 0; i < 10; i++) sockets.push(await connect(server, a.bearer));
		open.push(...sockets);
		const other = await connect(server, b.bearer);
		open.push(other);
		sockets.push(await connect(server, a.bearer));
		open.push(sockets[10]!);
		expect(await sockets[0]!.closed).toBe(4000);
		await sockets[10]!.settle();
		for (const alive of sockets.slice(1)) expect(alive.ws.readyState).toBe(WebSocket.OPEN);
		expect(other.ws.readyState).toBe(WebSocket.OPEN);
		sockets.push(await connect(server, a.bearer));
		open.push(sockets[11]!);
		expect(await sockets[1]!.closed).toBe(4000);
	});
});

describe('smaller things', () => {
	test('a file name loses bidi and control characters but keeps its spaces', async () => {
		const { hq, a, room } = await pair();
		const at = (...codes: number[]) => String.fromCodePoint(...codes);
		const named = async (name: string) =>
			(await (await upload(hq, a, room.id, 'x', { 'x-hq-file-name': encodeURIComponent(name) })).json()).attachment.file_name;
		// 202E right-to-left override, 2066 and 2069 isolates, 200F mark, 061C letter mark; 7F, 85 and 9F are control characters.
		expect(await named(`invoice${at(0x202e)}fdp.exe`)).toBe('invoicefdp.exe');
		expect(await named(`a${at(0x2066)}b${at(0x2069)}c${at(0x200f)}d${at(0x61c)}e${at(0x7f)}f${at(0x85)}g${at(0x9f)}h.txt`)).toBe(
			'abcdefgh.txt',
		);
		// A narrow no-break space (202F) is what macOS puts before "PM" in screenshot names, and is kept.
		expect(await named(`Screenshot 9.41${at(0x202f)}PM.png`)).toBe(`Screenshot 9.41${at(0x202f)}PM.png`);
		expect(await named(`${at(0x202e)}${at(0)}`)).toBe('file');
	});

	test('sending the same client message id twice returns the first message, even when the first lookup misses it', async () => {
		const { hq, a, room } = await pair();
		const id = crypto.randomUUID();
		const first = await say(a.as, room.id, 'once', { client_msg_id: id });
		expect(first.status).toBe(201);
		const real = hq.hub.messages.byClientId.bind(hq.hub.messages);
		let lookups = 0;
		hq.hub.messages.byClientId = (...args) => (lookups++ === 0 ? null : real(...args));
		const again = await say(a.as, room.id, 'once', { client_msg_id: id });
		expect(again.status).toBe(200);
		expect(again.body.message.id).toBe(first.body.message.id);
		expect(hq.hub.messages.list(room.id)).toHaveLength(1);
	});

	test('keys made before keys had kinds keep what their label meant', () => {
		const db = openDatabase();
		const before = CORE_MIGRATIONS.filter((m) => m.id !== 'core/016_key_kinds');
		migrate(db, before);
		const person = new People(db).create({ name: 'Ada', handle: 'ada' });
		const insert = db.query('INSERT INTO api_keys (id, person_id, label, hash, created_at) VALUES ($id, $p, $label, $id, 1)');
		for (const label of ['setup', 'invite', 'device', 'laptop']) insert.run({ id: label, p: person.id, label });
		migrate(db, CORE_MIGRATIONS);
		const kinds = db.query<{ id: string; kind: string }, []>('SELECT id, kind FROM api_keys ORDER BY id').all();
		expect(kinds).toEqual([
			{ id: 'device', kind: 'device' },
			{ id: 'invite', kind: 'invite' },
			{ id: 'laptop', kind: 'key' },
			{ id: 'setup', kind: 'setup' },
		]);
	});
});
