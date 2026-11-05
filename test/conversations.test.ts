import { describe, expect, test } from 'bun:test';
import { migrate, openDatabase } from '../src/db/database';
import { CONVERSATION_MIGRATIONS, Conversations, type Conversation } from '../src/core/conversations';
import { People, PEOPLE_MIGRATIONS } from '../src/core/people';

function setup() {
	const db = openDatabase();
	migrate(db, [...PEOPLE_MIGRATIONS, ...CONVERSATION_MIGRATIONS]);
	const created: Conversation[] = [];
	const people = new People(db);
	return {
		db,
		people,
		conversations: new Conversations(db, (c) => created.push(c)),
		created,
		ada: people.create({ name: 'Ada', handle: 'ada' }),
		bo: people.create({ name: 'Bo', handle: 'bo' }),
	};
}

describe('conversations', () => {
	test('a room includes its creator and members', () => {
		const { conversations, ada, bo, created } = setup();
		const room = conversations.createRoom({ title: 'Launch', createdBy: ada.id, memberIds: [bo.id] });
		expect(conversations.memberIds(room.id).sort()).toEqual([ada.id, bo.id].sort());
		expect(conversations.listFor(bo.id).map((c) => c.id)).toEqual([room.id]);
		expect(created).toHaveLength(1);
	});

	test('members list in join order', () => {
		const { db, conversations, people, ada, bo } = setup();
		const cy = people.create({ name: 'Cy', handle: 'cy' });
		const room = conversations.createRoom({ title: 'Order', createdBy: ada.id });
		conversations.addMember(room.id, cy.id);
		conversations.addMember(room.id, bo.id);
		db.query('UPDATE conversation_members SET joined_at = 3 WHERE person_id = $p').run({ p: ada.id });
		db.query('UPDATE conversation_members SET joined_at = 1 WHERE person_id = $p').run({ p: cy.id });
		db.query('UPDATE conversation_members SET joined_at = 2 WHERE person_id = $p').run({ p: bo.id });
		expect(conversations.memberIds(room.id)).toEqual([cy.id, bo.id, ada.id]);
	});

	test('a DM between two people is one conversation', () => {
		const { conversations, ada, bo, created } = setup();
		const first = conversations.dm(ada.id, bo.id);
		expect(conversations.dm(bo.id, ada.id).id).toBe(first.id);
		expect(created).toHaveLength(1);
	});

	test('ensureRoom is keyed', () => {
		const { conversations } = setup();
		expect(conversations.ensureRoom('general', 'General').id).toBe(conversations.ensureRoom('general', 'General').id);
	});

	test('archived rooms drop out of listings', () => {
		const { conversations, ada } = setup();
		const room = conversations.createRoom({ title: 'Old', createdBy: ada.id });
		conversations.archive(room.id);
		expect(conversations.listFor(ada.id)).toEqual([]);
		expect(conversations.get(room.id)?.archived_at).not.toBeNull();
	});

	test('membership checks', () => {
		const { conversations, ada, bo } = setup();
		const room = conversations.createRoom({ title: 'Solo', createdBy: ada.id });
		expect(conversations.isMember(room.id, ada.id)).toBe(true);
		expect(conversations.isMember(room.id, bo.id)).toBe(false);
	});
});
