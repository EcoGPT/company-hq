import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import { newId, now } from './ids';

export type ConversationKind = 'room' | 'dm';

export type Conversation = {
	id: string;
	kind: ConversationKind;
	title: string;
	key: string | null;
	created_by: string | null;
	created_at: number;
	archived_at: number | null;
	avatar_id: string | null;
};

export const CONVERSATION_MIGRATIONS: Migration[] = [
	{
		id: 'core/003_conversations',
		up: `CREATE TABLE conversations (
			id TEXT PRIMARY KEY,
			kind TEXT NOT NULL CHECK (kind IN ('room', 'dm')),
			title TEXT NOT NULL,
			key TEXT UNIQUE,
			created_by TEXT REFERENCES people(id),
			created_at INTEGER NOT NULL,
			archived_at INTEGER
		);
		CREATE TABLE conversation_members (
			conversation_id TEXT NOT NULL REFERENCES conversations(id),
			person_id TEXT NOT NULL REFERENCES people(id),
			joined_at INTEGER NOT NULL,
			PRIMARY KEY (conversation_id, person_id)
		);
		CREATE INDEX conversation_members_person ON conversation_members(person_id);`,
	},
	{
		id: 'core/009_member_order',
		up: 'CREATE INDEX conversation_members_order ON conversation_members(conversation_id, joined_at, person_id)',
	},
	{
		// Every membership check reads this view, so an archived conversation has no members to anyone.
		id: 'core/011_open_members',
		up: `CREATE VIEW open_conversation_members AS
			SELECT m.* FROM conversation_members m
			JOIN conversations c ON c.id = m.conversation_id
			WHERE c.archived_at IS NULL`,
	},
];

const dmKey = (a: string, b: string) => `dm:${[a, b].sort().join(':')}`;

export class Conversations {
	constructor(
		private readonly db: Database,
		private readonly onCreate: (conversation: Conversation) => void = () => {},
	) {}

	createRoom(input: { title: string; createdBy?: string; memberIds?: string[]; key?: string }): Conversation {
		const conversation = this.insert({
			kind: 'room',
			title: input.title.trim(),
			key: input.key ?? null,
			created_by: input.createdBy ?? null,
		});
		const members = new Set([...(input.memberIds ?? []), ...(input.createdBy ? [input.createdBy] : [])]);
		for (const personId of members) this.addMember(conversation.id, personId);
		this.onCreate(conversation);
		return conversation;
	}

	ensureRoom(key: string, title: string): Conversation {
		return this.byKey(key) ?? this.createRoom({ title, key });
	}

	findDm(a: string, b: string): Conversation | null {
		return this.byKey(dmKey(a, b));
	}

	dm(a: string, b: string): Conversation {
		const key = dmKey(a, b);
		const existing = this.byKey(key);
		if (existing !== null) return existing;
		const conversation = this.insert({ kind: 'dm', title: '', key, created_by: a });
		this.addMember(conversation.id, a);
		this.addMember(conversation.id, b);
		this.onCreate(conversation);
		return conversation;
	}

	get(id: string): Conversation | null {
		return this.db.query<Conversation, { id: string }>('SELECT * FROM conversations WHERE id = $id').get({ id });
	}

	byKey(key: string): Conversation | null {
		return this.db.query<Conversation, { key: string }>('SELECT * FROM conversations WHERE key = $key').get({ key });
	}

	listFor(personId: string): Conversation[] {
		return this.db
			.query<Conversation, { person_id: string }>(
				`SELECT conversations.* FROM conversations
				JOIN conversation_members m ON m.conversation_id = conversations.id
				WHERE m.person_id = $person_id AND conversations.archived_at IS NULL
				ORDER BY conversations.created_at`,
			)
			.all({ person_id: personId });
	}

	all(): Conversation[] {
		return this.db.query<Conversation, []>('SELECT * FROM conversations WHERE archived_at IS NULL ORDER BY created_at').all();
	}

	/** An empty title is allowed: a group without a name is shown by its members. */
	rename(id: string, title: string): string {
		const clean = title.trim();
		this.db.query('UPDATE conversations SET title = $title WHERE id = $id').run({ id, title: clean });
		return clean;
	}

	setAvatar(id: string, avatarId: string | null): void {
		this.db.query('UPDATE conversations SET avatar_id = $avatarId WHERE id = $id').run({ id, avatarId });
	}

	removeMember(conversationId: string, personId: string): void {
		this.db
			.query('DELETE FROM conversation_members WHERE conversation_id = $c AND person_id = $p')
			.run({ c: conversationId, p: personId });
	}

	archive(id: string): void {
		this.db.query('UPDATE conversations SET archived_at = $at WHERE id = $id AND archived_at IS NULL').run({ id, at: now() });
	}

	addMember(conversationId: string, personId: string): void {
		this.db
			.query('INSERT OR IGNORE INTO conversation_members (conversation_id, person_id, joined_at) VALUES ($c, $p, $at)')
			.run({ c: conversationId, p: personId, at: now() });
	}

	isMember(conversationId: string, personId: string): boolean {
		return (
			this.db
				.query('SELECT 1 FROM open_conversation_members WHERE conversation_id = $c AND person_id = $p')
				.get({ c: conversationId, p: personId }) !== null
		);
	}

	memberIds(conversationId: string): string[] {
		return this.db
			.query<{ person_id: string }, { c: string }>(
				'SELECT person_id FROM open_conversation_members WHERE conversation_id = $c ORDER BY joined_at, person_id',
			)
			.all({ c: conversationId })
			.map((row) => row.person_id);
	}

	private insert(input: Pick<Conversation, 'kind' | 'title' | 'key' | 'created_by'>): Conversation {
		const conversation: Conversation = { id: newId(), created_at: now(), archived_at: null, avatar_id: null, ...input };
		this.db
			.query(
				'INSERT INTO conversations (id, kind, title, key, created_by, created_at) VALUES ($id, $kind, $title, $key, $created_by, $created_at)',
			)
			.run({
				id: conversation.id,
				kind: conversation.kind,
				title: conversation.title,
				key: conversation.key,
				created_by: conversation.created_by,
				created_at: conversation.created_at,
			});
		return conversation;
	}
}
