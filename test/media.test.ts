import { describe, expect, test } from 'bun:test';
import { existsSync, readdirSync } from 'node:fs';
import { createHq } from '../src/hq';
import { enrolled, pair, say } from './helpers';

type Signed = Awaited<ReturnType<typeof enrolled>>;
type Hq = ReturnType<typeof createHq>;

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);

const send = (
	hq: Hq,
	who: Signed | null,
	method: string,
	path: string,
	init: { body?: BodyInit; headers?: Record<string, string> } = {},
) =>
	hq.fetch(
		new Request(`http://hq.test${path}`, {
			method,
			body: init.body,
			headers: { ...(who === null ? {} : { authorization: `Bearer ${who.bearer}` }), ...init.headers },
		}),
	) as Promise<Response>;

const upload = (hq: Hq, who: Signed, conversationId: string, body: BodyInit, headers: Record<string, string> = {}) =>
	send(hq, who, 'POST', `/v1/conversations/${conversationId}/attachments`, {
		body,
		headers: { 'content-type': 'text/plain', 'x-hq-file-name': 'notes.txt', ...headers },
	});

async function attach(hq: Hq, who: Signed, conversationId: string, body: BodyInit, headers: Record<string, string> = {}) {
	const response = await upload(hq, who, conversationId, body, headers);
	expect(response.status).toBe(201);
	const { attachment } = await response.json();
	await say(who.as, conversationId, 'a file', { attachment_ids: [attachment.id] });
	return attachment as { id: string };
}

describe('attachment upload', () => {
	test('raw bytes in, the six fields the app decodes out', async () => {
		const { hq, a, room } = await pair();
		const response = await upload(hq, a, room.id, 'hello bytes', {
			'content-type': 'image/png',
			'x-hq-file-name': encodeURIComponent('Screenshot 2026-10-31 at 9.41 PM.png'),
			'x-hq-image-width': '640',
			'x-hq-image-height': '480',
		});
		expect(response.status).toBe(201);
		const { attachment } = await response.json();
		expect(attachment).toEqual({
			id: attachment.id,
			file_name: 'Screenshot 2026-10-31 at 9.41 PM.png',
			content_type: 'image/png',
			byte_size: 11,
			width: 640,
			height: 480,
		});
		const plain = (await (await upload(hq, a, room.id, 'x')).json()).attachment;
		expect(plain).toMatchObject({ file_name: 'notes.txt', byte_size: 1, width: null, height: null });
	});

	test('a file name cannot carry a path or odd characters', async () => {
		const { hq, a, room } = await pair();
		const named = async (name: string) =>
			(await (await upload(hq, a, room.id, 'x', { 'x-hq-file-name': name })).json()).attachment.file_name;
		expect(await named(encodeURIComponent('../../etc/passwd'))).toBe('.._.._etc_passwd');
		expect(await named('%E0%A4%A')).toBe('%E0%A4%A');
		expect(await named('')).toBe('file');
		expect((await named('x'.repeat(500))).length).toBe(120);
	});

	test('files land under the data folder and are refused when empty or over the limit', async () => {
		const { hq, a, room } = await pair();
		expect((await upload(hq, a, room.id, '')).status).toBe(400);
		const small = createHq({ maxUploadBytes: 10 });
		const ada = await enrolled(small, small.hub.keys.mint(small.hub.people.create({ name: 'Ada', handle: 'ada' }).id).secret);
		const made = (await ada.as('POST', '/v1/conversations', { kind: 'group', person_ids: [ada.person.id], title: 'T' })).body
			.conversation;
		expect((await upload(small, ada, made.id, '0123456789')).status).toBe(201);
		const over = await upload(small, ada, made.id, '0123456789A');
		expect(over.status).toBe(413);
		expect(await over.json()).toEqual({ error: 'file_too_large' });
		const declared = await upload(small, ada, made.id, 'tiny', { 'content-length': '5000' });
		expect(declared.status).toBe(413);
		const folder = small.hub.files.path('attachments', made.id);
		expect(readdirSync(folder)).toHaveLength(1);
		expect(readdirSync(folder).some((name) => name.endsWith('.part'))).toBe(false);
		expect(small.hub.db.query('SELECT COUNT(*) AS n FROM attachments').get()).toEqual({ n: 1 });
		// The empty upload left nothing behind.
		const quiet = hq.hub.files.path('attachments', room.id);
		expect(existsSync(quiet) ? readdirSync(quiet) : []).toEqual([]);
	});

	test('the limit defaults to 100 MiB', async () => {
		const hq = createHq();
		const ada = hq.hub.people.create({ name: 'Ada', handle: 'ada' });
		hq.hub.conversations.addMember(hq.hub.general().id, ada.id);
		const signedIn = await enrolled(hq, hq.hub.keys.mint(ada.id).secret);
		const response = await upload(hq, signedIn, hq.hub.general().id, 'x', { 'content-length': String(100 * 1024 * 1024 + 1) });
		expect(response.status).toBe(413);
	});
});

describe('attaching to a message', () => {
	test('the first message to name an upload claims it; nobody else can', async () => {
		const { hq, a, b, room } = await pair();
		const mine = (await (await upload(hq, a, room.id, 'one')).json()).attachment;
		const theirs = (await (await upload(hq, b, room.id, 'two')).json()).attachment;
		const post = (who: Signed, ids: string[]) => say(who.as, room.id, 'files', { attachment_ids: ids });
		const stolen = await post(a, [theirs.id]);
		expect(stolen).toEqual({ status: 400, body: { error: 'invalid_attachment' } });
		expect((await post(a, ['nope'])).status).toBe(400);
		const sent = await post(a, [mine.id]);
		expect(sent.status).toBe(201);
		expect(sent.body.message.attachments).toEqual([mine]);
		expect((await post(b, [mine.id])).status).toBe(400);
		expect((await post(a, [mine.id])).status).toBe(400);
		expect(hq.hub.messages.list(room.id)).toHaveLength(1);
		// An attachment can carry the message on its own.
		const alone = await say(b.as, room.id, '', { attachment_ids: [theirs.id] });
		expect(alone.body.message).toMatchObject({ content: '', attachments: [{ id: theirs.id }] });
	});

	test('an upload from one conversation cannot go into another', async () => {
		const { hq, a, room } = await pair();
		const made = (await (await upload(hq, a, room.id, 'one')).json()).attachment;
		expect((await say(a.as, hq.hub.general().id, 'wrong room', { attachment_ids: [made.id] })).status).toBe(400);
	});

	test('at most ten', async () => {
		const { a, room } = await pair();
		expect((await say(a.as, room.id, 'many', { attachment_ids: Array.from({ length: 11 }, (_, i) => `a${i}`) })).body).toEqual({
			error: 'invalid_body',
		});
	});

	test('the frame and the page show the attachment', async () => {
		const { hq, a, b, room } = await pair();
		const file = await attach(hq, a, room.id, 'bytes');
		const page = (await b.as('GET', `/v1/conversations/${room.id}/messages`)).body.messages;
		expect(page[0].attachments.map((x: { id: string }) => x.id)).toEqual([file.id]);
		expect((await b.as('GET', `/v1/conversations/${room.id}`)).body.conversation.last_message.attachments).toHaveLength(1);
	});
});

describe('attachment download', () => {
	test('a member gets the bytes as a download, never to be shown in the page', async () => {
		const { hq, a, b, room } = await pair();
		const file = await attach(hq, a, room.id, 'the bytes', { 'content-type': 'text/plain', 'x-hq-file-name': 'plan.txt' });
		for (const who of [a, b]) {
			const response = await send(hq, who, 'GET', `/v1/attachments/${file.id}`);
			expect(response.status).toBe(200);
			expect(await response.text()).toBe('the bytes');
			expect(response.headers.get('content-type')).toBe('text/plain');
			expect(response.headers.get('content-disposition')).toStartWith('attachment; filename="plan.txt"');
			expect(response.headers.get('x-content-type-options')).toBe('nosniff');
			expect(response.headers.get('content-security-policy')).toContain('sandbox');
			expect(response.headers.get('cache-control')).toContain('private');
		}
	});

	test('HTML, SVG and other active types are handed out as opaque downloads', async () => {
		const { hq, a, room } = await pair();
		const active = [
			'text/html',
			'text/html; charset=utf-8',
			'TEXT/HTML',
			'image/svg+xml',
			'application/xhtml+xml',
			'text/xml',
			'application/javascript',
		];
		for (const type of active) {
			const file = await attach(hq, a, room.id, '<script>alert(document.cookie)</script>', {
				'content-type': type,
				'x-hq-file-name': 'page.html',
			});
			const response = await send(hq, a, 'GET', `/v1/attachments/${file.id}`);
			expect([type, response.headers.get('content-type')]).toEqual([type, 'application/octet-stream']);
			expect(response.headers.get('content-disposition')).toStartWith('attachment;');
			expect(response.headers.get('content-disposition')).not.toContain('inline');
			expect(response.headers.get('x-content-type-options')).toBe('nosniff');
		}
		const png = await attach(hq, a, room.id, PNG, { 'content-type': 'image/png' });
		expect((await send(hq, a, 'GET', `/v1/attachments/${png.id}`)).headers.get('content-type')).toBe('image/png');
	});

	test('the file name cannot break out of the header', async () => {
		const { hq, a, room } = await pair();
		const file = await attach(hq, a, room.id, 'x', { 'x-hq-file-name': encodeURIComponent('a"b\r\nx-evil: 1é.txt') });
		const disposition = (await send(hq, a, 'GET', `/v1/attachments/${file.id}`)).headers.get('content-disposition')!;
		expect(disposition).not.toMatch(/[\r\n]/);
		expect(disposition).toContain('filename="a_bx-evil_ 1_.txt"');
		expect(disposition).toContain("filename*=UTF-8''");
	});

	test('someone outside the room, or without a bearer, gets nothing', async () => {
		const { hq, a, room } = await pair();
		const cy = await enrolled(hq, hq.hub.keys.mint(hq.hub.people.create({ name: 'Cy', handle: 'cy' }).id).secret);
		const file = await attach(hq, a, room.id, 'private');
		expect((await send(hq, cy, 'GET', `/v1/attachments/${file.id}`)).status).toBe(404);
		expect((await send(hq, null, 'GET', `/v1/attachments/${file.id}`)).status).toBe(401);
		expect((await send(hq, a, 'GET', '/v1/attachments/nope')).status).toBe(404);
		expect((await send(hq, a, 'GET', '/v1/attachments/..%2F..%2Fhq.sqlite')).status).toBe(404);
	});

	test('before it is sent an upload is its uploader’s alone', async () => {
		const { hq, a, b, room } = await pair();
		const pending = (await (await upload(hq, a, room.id, 'draft')).json()).attachment;
		expect((await send(hq, a, 'GET', `/v1/attachments/${pending.id}`)).status).toBe(200);
		expect((await send(hq, b, 'GET', `/v1/attachments/${pending.id}`)).status).toBe(404);
	});

	test('once its message is unsent, nobody can fetch it', async () => {
		const { hq, a, b, room } = await pair();
		const file = await attach(hq, a, room.id, 'oops');
		const message = hq.hub.messages.latest(room.id)!;
		await a.as('DELETE', `/v1/messages/${message.id}`);
		for (const who of [a, b]) expect((await send(hq, who, 'GET', `/v1/attachments/${file.id}`)).status).toBe(404);
	});
});

describe('pictures', () => {
	const put = (hq: Hq, who: Signed, path: string, body: BodyInit, type = 'image/png') =>
		send(hq, who, 'PUT', path, { body, headers: { 'content-type': type } });

	test('a profile picture is set, seen by others, replaced and cleared', async () => {
		const { hq, a, b } = await pair();
		const set = await put(hq, a, '/v1/me/avatar', PNG);
		expect(set.status).toBe(200);
		const first = (await set.json()).person;
		expect(first.id).toBe(a.person.id);
		expect(typeof first.avatar_id).toBe('string');
		const picture = await send(hq, b, 'GET', `/v1/avatars/people/${a.person.id}/${first.avatar_id}`);
		expect(picture.status).toBe(200);
		expect(picture.headers.get('content-type')).toBe('image/png');
		expect(picture.headers.get('x-content-type-options')).toBe('nosniff');
		expect(new Uint8Array(await picture.arrayBuffer())).toEqual(PNG);
		expect((await b.as('GET', '/v1/people')).body.people.find((p: { id: string }) => p.id === a.person.id).avatar_id).toBe(
			first.avatar_id,
		);

		const second = (await (await put(hq, a, '/v1/me/avatar', JPEG, 'image/jpeg')).json()).person;
		expect(second.avatar_id).not.toBe(first.avatar_id);
		expect((await send(hq, b, 'GET', `/v1/avatars/people/${a.person.id}/${first.avatar_id}`)).status).toBe(404);
		const now = await send(hq, b, 'GET', `/v1/avatars/people/${a.person.id}/${second.avatar_id}`);
		expect(now.headers.get('content-type')).toBe('image/jpeg');
		expect(readdirSync(hq.hub.files.path('avatars', 'people', a.person.id))).toHaveLength(1);

		const cleared = await a.as('DELETE', '/v1/me/avatar');
		expect(cleared.body.person.avatar_id).toBeNull();
		expect((await send(hq, b, 'GET', `/v1/avatars/people/${a.person.id}/${second.avatar_id}`)).status).toBe(404);
		expect(readdirSync(hq.hub.files.path('avatars', 'people', a.person.id))).toEqual([]);
	});

	test('only png and jpeg that really are, up to 5 MiB', async () => {
		const { hq, a } = await pair();
		expect((await put(hq, a, '/v1/me/avatar', PNG, 'image/svg+xml')).status).toBe(415);
		expect((await put(hq, a, '/v1/me/avatar', PNG, 'text/html')).status).toBe(415);
		expect((await put(hq, a, '/v1/me/avatar', '<svg onload=alert(1)>', 'image/png')).status).toBe(415);
		expect((await put(hq, a, '/v1/me/avatar', JPEG, 'image/png')).status).toBe(415);
		expect((await put(hq, a, '/v1/me/avatar', new Uint8Array(0))).status).toBe(400);
		const big = new Uint8Array(5 * 1024 * 1024 + 1);
		big.set(PNG);
		expect((await put(hq, a, '/v1/me/avatar', big)).status).toBe(413);
		expect(hq.hub.people.get(a.person.id)?.avatar_id).toBeNull();
	});

	test('a group photo belongs to its members and its group', async () => {
		const { hq, a, b, room } = await pair();
		const cy = await enrolled(hq, hq.hub.keys.mint(hq.hub.people.create({ name: 'Cy', handle: 'cy' }).id).secret);
		const set = await put(hq, b, `/v1/conversations/${room.id}/image`, PNG);
		expect(set.status).toBe(200);
		const { conversation } = await set.json();
		expect(typeof conversation.avatar_id).toBe('string');
		const url = `/v1/avatars/conversations/${room.id}/${conversation.avatar_id}`;
		expect((await send(hq, a, 'GET', url)).status).toBe(200);
		expect((await send(hq, cy, 'GET', url)).status).toBe(404);
		expect((await put(hq, cy, `/v1/conversations/${room.id}/image`, PNG)).status).toBe(404);
		expect((await put(hq, a, `/v1/conversations/${hq.hub.general().id}/image`, PNG)).status).toBe(409);
		const dm = (await a.as('POST', '/v1/conversations', { kind: 'dm', person_id: b.person.id })).body.conversation;
		expect((await put(hq, a, `/v1/conversations/${dm.id}/image`, PNG)).status).toBe(409);
		const cleared = await a.as('DELETE', `/v1/conversations/${room.id}/image`);
		expect(cleared.body.conversation.avatar_id).toBeNull();
		expect((await send(hq, a, 'GET', url)).status).toBe(404);
	});
});
