import { describe, expect, test } from 'bun:test';
import { client, enrolled, pair, say } from '../../test/helpers';
import docs from '../docs/app';
import { Docs } from '../docs/store';
import library from './app';
import { decodeProblems } from './decode';

type Who = Awaited<ReturnType<typeof enrolled>>;

async function setup() {
	const base = await pair({ apps: [docs, library] });
	const { hq } = base;
	const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
	hq.hub.conversations.addMember(hq.hub.general().id, cy.id);
	const c = await enrolled(hq, hq.hub.keys.mint(cy.id, 'setup').secret, 'Cy Mac');
	return { ...base, cy, c };
}

describe('the files list', () => {
	/** Uploads `name` to the room as `who` and sends it in a message. Returns the attachment id and the message id. */
	async function share(ctx: Awaited<ReturnType<typeof setup>>, who: Who, roomId: string, name: string, send = true) {
		const upload = await ctx.hq.fetch(
			new Request(`http://hq.test/v1/conversations/${roomId}/attachments`, {
				method: 'POST',
				body: new TextEncoder().encode(`contents of ${name}`),
				headers: { authorization: `Bearer ${who.bearer}`, 'content-type': 'text/plain', 'x-hq-file-name': name },
			}),
		);
		expect(upload?.status).toBe(201);
		const id = (await upload!.json()).attachment.id as string;
		if (!send) return { id, messageId: null };
		const sent = await say(who.as, roomId, `here is ${name}`, { attachment_ids: [id] });
		expect(sent.status).toBe(201);
		return { id, messageId: sent.body.message.id as string };
	}

	const listed = async (who: Who) => {
		const answer = await who.as('GET', '/v1/files');
		expect(answer.status).toBe(200);
		expect(decodeProblems('LibraryFiles', answer.body)).toEqual([]);
		return (answer.body.files as { id: string; file_name: string }[]).map((f) => f.file_name);
	};

	test('a file sent in chat is listed for the members of that conversation, as the app decodes it', async () => {
		const ctx = await setup();
		const { a, b, room } = ctx;
		const { id } = await share(ctx, a, room.id, 'plan.txt');
		const answer = await b.as('GET', '/v1/files');
		expect(answer.body.files).toEqual([
			{
				id,
				file_name: 'plan.txt',
				content_type: 'text/plain',
				byte_size: 'contents of plan.txt'.length,
				conversation_id: room.id,
				conversation_title: 'Launch',
				uploader_name: 'Ada',
				created_at: expect.stringMatching(/^\d{4}-\d\d-\d\dT/),
				folder_id: null,
			},
		]);
		expect(await listed(a)).toEqual(['plan.txt']);
	});

	test('is never another room’s file: a person who is not in the conversation does not see it', async () => {
		const ctx = await setup();
		const { a, b, c, room } = ctx;
		await share(ctx, a, room.id, 'secret.txt');
		expect(await listed(b)).toEqual(['secret.txt']);
		expect(await listed(c)).toEqual([]);
		// Cy has a room of their own with Bo, and sees only what was shared there.
		const other = (await c.as('POST', '/v1/conversations', { kind: 'group', title: 'Side', person_ids: [b.person.id] })).body
			.conversation;
		await share(ctx, b, other.id, 'side.txt');
		expect(await listed(c)).toEqual(['side.txt']);
		expect((await listed(b)).sort()).toEqual(['secret.txt', 'side.txt']);
		expect(await listed(a)).toEqual(['secret.txt']);
	});

	test('a direct message’s file is for the two of them only, with no title', async () => {
		const ctx = await setup();
		const { a, b, c } = ctx;
		const dm = (await a.as('POST', '/v1/conversations', { kind: 'dm', person_id: b.person.id })).body.conversation;
		await share(ctx, a, dm.id, 'between-us.txt');
		const mine = (await b.as('GET', '/v1/files')).body.files;
		expect(mine).toHaveLength(1);
		expect(mine[0].conversation_title).toBeNull();
		expect(await listed(c)).toEqual([]);
	});

	test('stops listing a file when its message is unsent, the conversation is closed, or the person leaves', async () => {
		const ctx = await setup();
		const { a, b, c, hq, room } = ctx;
		const kept = await share(ctx, a, room.id, 'kept.txt');
		const unsent = await share(ctx, a, room.id, 'unsent.txt');
		expect((await listed(b)).sort()).toEqual(['kept.txt', 'unsent.txt']);
		await a.as('DELETE', `/v1/messages/${unsent.messageId}`);
		expect(await listed(b)).toEqual(['kept.txt']);

		// Cy joins later and sees what is in the room now; leaving takes it away again.
		hq.hub.conversations.addMember(room.id, c.person.id);
		expect(await listed(c)).toEqual(['kept.txt']);
		hq.hub.conversations.removeMember(room.id, c.person.id);
		expect(await listed(c)).toEqual([]);

		hq.hub.conversations.archive(room.id);
		expect(await listed(a)).toEqual([]);
		expect(await listed(b)).toEqual([]);
		expect(kept.id).not.toBe(unsent.id);
	});

	test('an upload no message holds yet is not in the list', async () => {
		const ctx = await setup();
		const { a, room } = ctx;
		await share(ctx, a, room.id, 'draft.txt', false);
		expect(await listed(a)).toEqual([]);
	});

	test('lists the newest first, and no more than 500', async () => {
		const ctx = await setup();
		const { a, hq, room } = ctx;
		await share(ctx, a, room.id, 'first.txt');
		await Bun.sleep(5);
		const { messageId } = await share(ctx, a, room.id, 'second.txt');
		expect(await listed(a)).toEqual(['second.txt', 'first.txt']);
		const insert = hq.hub.db.query(
			`INSERT INTO attachments (id, conversation_id, uploader_id, message_id, file_name, content_type, byte_size, created_at)
			VALUES ($id, $room, $person, $message, 'bulk.txt', 'text/plain', 1, 0)`,
		);
		for (let i = 0; i < 500; i += 1) insert.run({ id: `bulk${i}`, room: room.id, person: a.person.id, message: messageId });
		const all = await listed(a);
		expect(all).toHaveLength(500);
		expect(all.slice(0, 2)).toEqual(['second.txt', 'first.txt']);
	});

	test('needs a sign-in', async () => {
		const { hq } = await setup();
		expect((await client(hq)('GET', '/v1/files')).status).toBe(401);
		expect((await client(hq)('GET', '/v1/library')).status).toBe(401);
	});
});

describe('folders', () => {
	test('there are none, and the app decodes the empty list', async () => {
		const { a } = await setup();
		const answer = await a.as('GET', '/v1/library');
		expect(answer).toEqual({ status: 200, body: { folders: [] } });
		expect(decodeProblems('LibraryFolders', answer.body)).toEqual([]);
	});
});

describe('documents in the library', () => {
	test('a doc is listed and opened as the app decodes it', async () => {
		const { a, b, hq, ada, bo } = await setup();
		const store = new Docs(hq.hub);
		store.write({ slug: 'launch-plan', title: 'Launch plan', body: '# Plan\n\nShip it.', by: ada.person.id });
		await Bun.sleep(5);
		store.write({ slug: 'notes', title: 'Notes', body: 'Bo wrote this.', by: bo.id });

		const list = await b.as('GET', '/v1/documents');
		expect(list.status).toBe(200);
		expect(decodeProblems('LibraryDocuments', list.body)).toEqual([]);
		expect(list.body.documents).toEqual([
			{ slug: 'notes', title: 'Notes', updated_at: expect.any(String), updated_by_name: 'Bo', folder_id: null },
			{ slug: 'launch-plan', title: 'Launch plan', updated_at: expect.any(String), updated_by_name: 'Ada', folder_id: null },
		]);

		const opened = await a.as('GET', '/v1/documents/launch-plan');
		expect(opened.status).toBe(200);
		expect(decodeProblems('LibraryDocument', opened.body)).toEqual([]);
		expect(opened.body.document).toEqual({
			slug: 'launch-plan',
			title: 'Launch plan',
			content: '# Plan\n\nShip it.',
			updated_at: expect.any(String),
			updated_by_name: 'Ada',
		});
	});

	test('every signed-in member reads the whole shelf, as they do through the docs app; no one else does', async () => {
		const { c, hq, ada } = await setup();
		new Docs(hq.hub).write({ slug: 'shared', title: 'Shared', body: 'for the team', by: ada.person.id });
		expect((await c.as('GET', '/v1/documents/shared')).status).toBe(200);
		expect((await c.as('GET', '/apps/docs/api/docs/shared')).status).toBe(200);
		expect((await client(hq)('GET', '/v1/documents')).status).toBe(401);
		expect((await client(hq)('GET', '/v1/documents/shared')).status).toBe(401);
	});

	test('a doc that is not there is a 404', async () => {
		const { a } = await setup();
		expect((await a.as('GET', '/v1/documents/nope')).status).toBe(404);
		expect((await a.as('GET', '/v1/documents/..%2Fsecrets')).status).toBe(404);
	});

	test('the shelf lists no more than 500, newest first', async () => {
		const { a, hq, ada } = await setup();
		const insert = hq.hub.db.query(
			`INSERT INTO docs (slug, title, body, updated_by, updated_at) VALUES ($slug, $slug, '', $by, $at)`,
		);
		for (let i = 0; i < 501; i += 1) insert.run({ slug: `doc-${i}`, by: ada.person.id, at: i + 1 });
		const list = (await a.as('GET', '/v1/documents')).body.documents as { slug: string }[];
		expect(list).toHaveLength(500);
		expect(list[0]!.slug).toBe('doc-500');
		expect(list.some((doc) => doc.slug === 'doc-0')).toBe(false);
	});
});
