// The app protocol against the real server process: first run, two devices, a room, and everything
// the native app does to it, over HTTP and WebSocket only.
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { connect, type Connection } from '../test/helpers';

const root = join(import.meta.dirname, '..');

let dir = '';
let child: ChildProcess | undefined;
let base = '';
let port = 0;

function serverEnv(extra: Record<string, string> = {}): Record<string, string | undefined> {
	const env: Record<string, string | undefined> = {
		...process.env,
		HQ_DB: join(dir, 'hq.sqlite'),
		HQ_VAULT_KEY: 'e2e-vault-key',
		...extra,
	};
	for (const name of Object.keys(env)) if (name.startsWith('HQ_LLM_') || name === 'HQ_PUBLIC_URL') delete env[name];
	return env;
}

function cli(args: string[]): string {
	const result = spawnSync('bun', [join(root, 'bin/hq.ts'), ...args], { cwd: dir, env: serverEnv(), encoding: 'utf8' });
	if (result.status !== 0) throw new Error(`bun hq ${args.join(' ')} failed:\n${result.stdout}${result.stderr}`);
	return result.stdout;
}

const keyFrom = (output: string) => /Key\s+(hq_[A-Za-z0-9_-]+)/.exec(output)![1]!;

async function startServer(): Promise<void> {
	child = spawn('bun', [join(root, 'src/server.ts')], {
		cwd: dir,
		env: serverEnv({ PORT: '0' }),
		stdio: ['ignore', 'pipe', 'pipe'],
	});
	let log = '';
	base = await new Promise<string>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`server did not start:\n${log}`)), 20_000);
		const look = (chunk: Buffer) => {
			log += chunk.toString();
			const match = /HQ is up on (http:\/\/localhost:(\d+))/.exec(log);
			if (match === null) return;
			clearTimeout(timer);
			port = Number(match[2]);
			resolve(match[1]!);
		};
		child!.stdout!.on('data', look);
		child!.stderr!.on('data', look);
		child!.on('exit', (code) => reject(new Error(`server exited with ${code}:\n${log}`)));
	});
}

async function call(bearer: string | null, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
	const raw = body instanceof Uint8Array;
	return fetch(`${base}${path}`, {
		method,
		headers: {
			...(bearer === null ? {} : { authorization: `Bearer ${bearer}` }),
			...(body === undefined || raw ? {} : { 'content-type': 'application/json' }),
			...headers,
		},
		body: body === undefined ? undefined : raw ? new Blob([body as Uint8Array<ArrayBuffer>]) : JSON.stringify(body),
	});
}

async function json(response: Response) {
	return { status: response.status, body: await response.json() };
}

const enroll = async (key: string, deviceName: string) => {
	const response = await json(await call(null, 'POST', '/v1/enroll', { key, device_name: deviceName }));
	expect(response.status).toBe(201);
	return response.body as { bearer: string; device_id: string; person: { id: string; name: string } };
};

beforeAll(() => {
	dir = mkdtempSync(join(tmpdir(), 'hq-e2e-'));
});

afterAll(() => {
	child?.kill();
	rmSync(dir, { recursive: true, force: true });
});

describe('the app protocol, end to end', () => {
	test('first run to a conversation, with every kind of change', async () => {
		// First run: the CLI makes the admin and an invite, as the README says.
		const adaKey = keyFrom(cli(['setup', '--handle', 'ada', '--name', 'Ada Lovelace']));
		const boKey = keyFrom(cli(['invite', 'bo', '--name', 'Bo Chen']));
		await startServer();

		expect((await json(await call(null, 'POST', '/v1/enroll', { key: 'hq_wrong' }))).body).toEqual({ error: 'invalid_key' });
		const ada = await enroll(adaKey, 'Ada MacBook');
		const bo = await enroll(boKey, 'Bo iPhone');
		expect(ada.person.name).toBe('Ada Lovelace');
		// The keys the CLI printed sign devices in and nothing else.
		expect((await call(adaKey, 'GET', '/v1/me')).status).toBe(401);
		expect((await call(boKey, 'GET', '/v1/me')).status).toBe(401);
		expect((await json(await call(null, 'GET', '/v1/conversations'))).body).toEqual({ error: 'unauthorized' });

		const sockets: Connection[] = [];
		const adaSocket = await connect({ port }, ada.bearer);
		let boSocket = await connect({ port }, bo.bearer);
		sockets.push(adaSocket, boSocket);
		expect(adaSocket.frames[0]).toMatchObject({ type: 'hello', device_id: ada.device_id, person_id: ada.person.id });

		// A room with both of them in it.
		const made = await json(
			await call(ada.bearer, 'POST', '/v1/conversations', { kind: 'group', title: 'Launch', person_ids: [bo.person.id] }),
		);
		expect(made.status).toBe(201);
		const room = made.body.conversation as { id: string };
		expect((await boSocket.take('conversation_updated', (f) => f.conversation.id === room.id)).conversation.title).toBe('Launch');

		// A message crosses to the other socket.
		const send = (bearer: string, content: string, extra: Record<string, unknown> = {}) =>
			call(bearer, 'POST', `/v1/conversations/${room.id}/messages`, { client_msg_id: crypto.randomUUID(), content, ...extra });
		const hello = (await json(await send(ada.bearer, 'hello Bo'))).body.message;
		expect((await boSocket.take('message', (f) => f.message.id === hello.id)).message).toEqual(hello);
		expect(
			(await call(bo.bearer, 'GET', `/v1/conversations/${room.id}/messages`).then(json)).body.messages.map(
				(m: { id: string }) => m.id,
			),
		).toEqual([hello.id]);

		// Tapback, edit, unsend.
		const tapped = (await json(await call(bo.bearer, 'POST', `/v1/messages/${hello.id}/reactions`, { emoji: '👍' }))).body
			.message;
		expect(tapped.reactions).toEqual([{ emoji: '👍', person_ids: [bo.person.id] }]);
		expect((await adaSocket.take('message_updated', (f) => f.message.reactions.length === 1)).message.id).toBe(hello.id);
		const edited = (await json(await call(ada.bearer, 'PATCH', `/v1/messages/${hello.id}`, { content: 'hello Bo!' }))).body
			.message;
		expect(
			(await boSocket.take('message_updated', (f) => f.message.content === 'hello Bo!')).message.edit_history[0].content,
		).toBe('hello Bo');
		expect(edited.edited_at).not.toBeNull();
		const oops = (await json(await send(ada.bearer, 'oops'))).body.message;
		await call(ada.bearer, 'DELETE', `/v1/messages/${oops.id}`);
		expect(
			(await boSocket.take('message_updated', (f) => f.message.id === oops.id && f.message.deleted_at !== null)).message.content,
		).toBe('');

		// Read state.
		const read = await json(await call(bo.bearer, 'POST', `/v1/conversations/${room.id}/read`, { message_id: oops.id }));
		expect(read.body).toEqual({ last_read_message_id: oops.id });
		expect(await adaSocket.take('read')).toEqual({
			type: 'read',
			conversation_id: room.id,
			person_id: bo.person.id,
			last_read_message_id: oops.id,
		});

		// An attachment goes up as raw bytes and comes back the same, as a download.
		const bytes = new Uint8Array(200_000).map((_, i) => i % 251);
		const uploaded = await json(
			await call(ada.bearer, 'POST', `/v1/conversations/${room.id}/attachments`, bytes, {
				'content-type': 'application/octet-stream',
				'x-hq-file-name': encodeURIComponent('data file.bin'),
			}),
		);
		expect(uploaded.status).toBe(201);
		const attachment = uploaded.body.attachment as { id: string; byte_size: number; file_name: string };
		expect(attachment).toMatchObject({ byte_size: 200_000, file_name: 'data file.bin' });
		const withFile = (await json(await send(ada.bearer, '', { attachment_ids: [attachment.id] }))).body.message;
		expect(withFile.attachments).toHaveLength(1);
		const download = await call(bo.bearer, 'GET', `/v1/attachments/${attachment.id}`);
		expect(download.status).toBe(200);
		expect(new Uint8Array(await download.arrayBuffer())).toEqual(bytes);
		expect(download.headers.get('content-disposition')).toStartWith('attachment;');
		expect(download.headers.get('x-content-type-options')).toBe('nosniff');

		// Bo's phone drops off. Ada writes while it is away. It comes back and asks for what it missed.
		const lastSeen = withFile.id as string;
		boSocket.ws.close();
		await boSocket.closed;
		const missed = (await json(await send(ada.bearer, 'while you were away'))).body.message;
		boSocket = await connect({ port }, bo.bearer);
		sockets.push(boSocket);
		boSocket.send({ type: 'sync', since_message_id: lastSeen });
		const batch = await boSocket.take('sync_batch');
		expect(batch.messages.map((m: { id: string }) => m.id)).toEqual([missed.id]);
		expect(await boSocket.take('sync_complete')).toEqual({ type: 'sync_complete', is_partial: false });

		// Revoking a device ends its access and its socket.
		expect((await json(await call(ada.bearer, 'POST', `/v1/devices/${bo.device_id}/revoke`))).body).toEqual({ ok: true });
		expect(await boSocket.closed).toBe(4001);
		expect(await json(await call(bo.bearer, 'GET', '/v1/people'))).toEqual({ status: 401, body: { error: 'unauthorized' } });
		expect((await call(ada.bearer, 'GET', '/v1/people').then(json)).body.people.map((p: { name: string }) => p.name)).toContain(
			'Bo Chen',
		);

		for (const socket of sockets) socket.ws.close();
	}, 60_000);
});
