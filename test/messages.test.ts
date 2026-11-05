import { describe, expect, test } from 'bun:test';
import { migrate, openDatabase } from '../src/db/database';
import { CONVERSATION_MIGRATIONS, Conversations } from '../src/core/conversations';
import { MESSAGE_MIGRATIONS, Messages, type Message } from '../src/core/messages';
import { newId } from '../src/core/ids';
import { People, PEOPLE_MIGRATIONS } from '../src/core/people';
import { WIRE_MIGRATIONS } from '../src/core/wire-schema';

function setup() {
	const db = openDatabase();
	migrate(db, [...PEOPLE_MIGRATIONS, ...CONVERSATION_MIGRATIONS, ...MESSAGE_MIGRATIONS, ...WIRE_MIGRATIONS]);
	const people = new People(db);
	const conversations = new Conversations(db);
	const sent: Message[] = [];
	const messages = new Messages(db, (m) => sent.push(m));
	const ada = people.create({ name: 'Ada', handle: 'ada' });
	const bo = people.create({ name: 'Bo', handle: 'bo' });
	const room = conversations.createRoom({ title: 'Room', createdBy: ada.id, memberIds: [bo.id] });
	const secret = conversations.createRoom({ title: 'Secret', createdBy: ada.id });
	return { messages, sent, ada, bo, room, secret };
}

describe('messages', () => {
	test('lists in order, pages after a cursor', () => {
		const { messages, ada, room, sent } = setup();
		const ids = ['one', 'two', 'three'].map((body) => messages.send({ conversationId: room.id, authorId: ada.id, body }).id);
		expect(messages.list(room.id).map((m) => m.body)).toEqual(['one', 'two', 'three']);
		expect(messages.list(room.id, { after: ids[0] }).map((m) => m.body)).toEqual(['two', 'three']);
		expect(messages.list(room.id, { limit: 2 }).map((m) => m.body)).toEqual(['two', 'three']);
		expect(messages.list(room.id, { limit: 2.5 }).map((m) => m.body)).toEqual(['two', 'three']);
		expect(sent).toHaveLength(3);
	});

	test('metadata round-trips', () => {
		const { messages, ada, room } = setup();
		const m = messages.send({ conversationId: room.id, authorId: ada.id, body: 'x', metadata: { app: 'tasks' } });
		expect(messages.get(m.id)?.metadata).toEqual({ app: 'tasks' });
	});

	test('search only sees rooms the searcher is in', () => {
		const { messages, ada, bo, room, secret } = setup();
		messages.send({ conversationId: room.id, authorId: ada.id, body: 'launch plan v2' });
		messages.send({ conversationId: secret.id, authorId: ada.id, body: 'launch budget' });
		expect(messages.search(ada.id, 'launch')).toHaveLength(2);
		expect(messages.search(bo.id, 'launch').map((m) => m.body)).toEqual(['launch plan v2']);
		expect(messages.search(bo.id, '%')).toEqual([]);
	});

	test('search matches substrings case-insensitively, newest first', () => {
		const { messages, ada, room } = setup();
		const bodies = ['Relaunch Friday', 'the LAUNCH slipped', 'unrelated', '100% done_now', 'say "hi" twice'];
		for (const body of bodies) messages.send({ conversationId: room.id, authorId: ada.id, body });
		expect(messages.search(ada.id, 'aunc').map((m) => m.body)).toEqual(['the LAUNCH slipped', 'Relaunch Friday']);
		expect(messages.search(ada.id, 'launch', 1).map((m) => m.body)).toEqual(['the LAUNCH slipped']);
		expect(messages.search(ada.id, '0% d').map((m) => m.body)).toEqual(['100% done_now']);
		expect(messages.search(ada.id, 'e_n').map((m) => m.body)).toEqual(['100% done_now']);
		expect(messages.search(ada.id, '0%d')).toEqual([]);
		expect(messages.search(ada.id, '"hi"').map((m) => m.body)).toEqual(['say "hi" twice']);
		expect(messages.search(ada.id, 'Fr').map((m) => m.body)).toEqual(['Relaunch Friday']);
		expect(messages.search(ada.id, 'zzz')).toEqual([]);
	});

	test('search follows edits', () => {
		const { messages, ada, room } = setup();
		const m = messages.send({ conversationId: room.id, authorId: ada.id, body: 'meet on tuesday' });
		messages.edit(m.id, 'meet on thursday');
		expect(messages.search(ada.id, 'tuesday')).toEqual([]);
		expect(messages.search(ada.id, 'thursday').map((x) => x.id)).toEqual([m.id]);
	});

	test('the search index backfills messages written before it existed', () => {
		const db = openDatabase();
		const [create, ...rest] = MESSAGE_MIGRATIONS;
		migrate(db, [...PEOPLE_MIGRATIONS, ...CONVERSATION_MIGRATIONS, create!]);
		const ada = new People(db).create({ name: 'Ada', handle: 'ada' });
		const room = new Conversations(db).createRoom({ title: 'Old', createdBy: ada.id });
		db.query('INSERT INTO messages (id, conversation_id, author_id, body, created_at) VALUES ($id, $c, $a, $body, 1)').run({
			id: newId(),
			c: room.id,
			a: ada.id,
			body: 'archived roadmap',
		});
		migrate(db, [...PEOPLE_MIGRATIONS, ...CONVERSATION_MIGRATIONS, create!, ...rest, ...WIRE_MIGRATIONS]);
		expect(new Messages(db).search(ada.id, 'roadmap').map((m) => m.body)).toEqual(['archived roadmap']);
	});

	test('edits keep the id and stamp edited_at', () => {
		const { messages, ada, room } = setup();
		const m = messages.send({ conversationId: room.id, authorId: ada.id, body: 'teh' });
		const edited = messages.edit(m.id, 'the');
		expect(edited?.body).toBe('the');
		expect(edited?.edited_at).not.toBeNull();
	});
});
