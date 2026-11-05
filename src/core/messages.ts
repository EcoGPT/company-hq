import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import { newId, now } from './ids';

export type Message = {
	id: string;
	conversation_id: string;
	author_id: string;
	body: string;
	metadata: Record<string, unknown> | null;
	created_at: number;
	edited_at: number | null;
	reply_to_message_id: string | null;
	/** Set when the author unsends. The text stays stored but is never handed out again. */
	deleted_at: number | null;
};

type MessageRow = Omit<Message, 'metadata'> & { metadata: string | null };

export type EditRevision = { content: string; edited_at: number };

export const MESSAGE_MIGRATIONS: Migration[] = [
	{
		id: 'core/004_messages',
		up: `CREATE TABLE messages (
			id TEXT PRIMARY KEY,
			conversation_id TEXT NOT NULL REFERENCES conversations(id),
			author_id TEXT NOT NULL REFERENCES people(id),
			body TEXT NOT NULL,
			metadata TEXT,
			created_at INTEGER NOT NULL,
			edited_at INTEGER
		);
		CREATE INDEX messages_conversation ON messages(conversation_id, id);`,
	},
	{
		id: 'core/008_message_search',
		up: `CREATE VIRTUAL TABLE messages_fts USING fts5(body, content = 'messages', tokenize = 'trigram');
		INSERT INTO messages_fts (messages_fts) VALUES ('rebuild');
		CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
			INSERT INTO messages_fts (rowid, body) VALUES (new.rowid, new.body);
		END;
		CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
			INSERT INTO messages_fts (messages_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
		END;
		CREATE TRIGGER messages_fts_update AFTER UPDATE OF body ON messages BEGIN
			INSERT INTO messages_fts (messages_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
			INSERT INTO messages_fts (rowid, body) VALUES (new.rowid, new.body);
		END;`,
	},
];

function decode(row: MessageRow): Message {
	return {
		id: row.id,
		conversation_id: row.conversation_id,
		author_id: row.author_id,
		body: row.deleted_at === null ? row.body : '',
		metadata: row.metadata === null ? null : JSON.parse(row.metadata),
		created_at: row.created_at,
		edited_at: row.edited_at,
		reply_to_message_id: row.reply_to_message_id,
		deleted_at: row.deleted_at,
	};
}

export class Messages {
	constructor(
		private readonly db: Database,
		private readonly onSend: (message: Message) => void = () => {},
		private readonly onChange: (message: Message) => void = () => {},
	) {}

	send(input: {
		conversationId: string;
		authorId: string;
		body: string;
		metadata?: Record<string, unknown>;
		replyTo?: string | null;
		clientMsgId?: string;
		/** Uploads the author made in this conversation that this message claims. */
		attachmentIds?: string[];
	}): Message {
		const message: Message = {
			id: newId(),
			conversation_id: input.conversationId,
			author_id: input.authorId,
			body: input.body,
			metadata: input.metadata ?? null,
			created_at: now(),
			edited_at: null,
			// A quote only counts inside its own conversation; anything else would leak across rooms.
			reply_to_message_id: this.inConversation(input.replyTo ?? null, input.conversationId),
			deleted_at: null,
		};
		this.db.transaction(() => {
			this.db
				.query(
					`INSERT INTO messages (id, conversation_id, author_id, body, metadata, created_at, reply_to_message_id, client_msg_id)
					VALUES ($id, $c, $a, $body, $metadata, $at, $reply, $client)`,
				)
				.run({
					id: message.id,
					c: message.conversation_id,
					a: message.author_id,
					body: message.body,
					metadata: message.metadata === null ? null : JSON.stringify(message.metadata),
					at: message.created_at,
					reply: message.reply_to_message_id,
					client: input.clientMsgId ?? null,
				});
			if (input.attachmentIds !== undefined && input.attachmentIds.length > 0) {
				this.db
					.query(
						`UPDATE attachments SET message_id = $m
						WHERE id IN (SELECT value FROM json_each($ids)) AND message_id IS NULL
						AND conversation_id = $c AND uploader_id = $a`,
					)
					.run({ m: message.id, ids: JSON.stringify(input.attachmentIds), c: message.conversation_id, a: message.author_id });
			}
		})();
		this.onSend(message);
		return message;
	}

	get(id: string): Message | null {
		const row = this.db.query<MessageRow, { id: string }>('SELECT * FROM messages WHERE id = $id').get({ id });
		return row === null ? null : decode(row);
	}

	/** A person's earlier send with this client id: how a retry finds its first attempt. */
	byClientId(authorId: string, clientMsgId: string): Message | null {
		const row = this.db
			.query<MessageRow, { a: string; client: string }>('SELECT * FROM messages WHERE author_id = $a AND client_msg_id = $client')
			.get({ a: authorId, client: clientMsgId });
		return row === null ? null : decode(row);
	}

	latest(conversationId: string): Message | null {
		const row = this.db
			.query<MessageRow, { c: string }>('SELECT * FROM messages WHERE conversation_id = $c ORDER BY id DESC LIMIT 1')
			.get({ c: conversationId });
		return row === null ? null : decode(row);
	}

	/** Oldest first. `after` pages forward, `before` pages back from a message; with neither, the newest `limit`. */
	list(conversationId: string, options: { after?: string; before?: string; limit?: number } = {}): Message[] {
		const limit = Math.min(Math.max(Math.trunc(options.limit ?? 50), 1), 500);
		if (options.after !== undefined) {
			return this.db
				.query<MessageRow, { c: string; after: string; limit: number }>(
					'SELECT * FROM messages WHERE conversation_id = $c AND id > $after ORDER BY id LIMIT $limit',
				)
				.all({ c: conversationId, after: options.after, limit })
				.map(decode);
		}
		return this.db
			.query<MessageRow, { c: string; before: string; limit: number }>(
				'SELECT * FROM (SELECT * FROM messages WHERE conversation_id = $c AND id < $before ORDER BY id DESC LIMIT $limit) ORDER BY id',
			)
			.all({ c: conversationId, before: options.before ?? '￿', limit })
			.map(decode);
	}

	/** What a person can still see after `afterId`, across every open conversation they are in. Oldest first. */
	since(personId: string, afterId: string, limit: number): Message[] {
		return this.db
			.query<MessageRow, { p: string; after: string; limit: number }>(
				`SELECT messages.* FROM messages
				JOIN open_conversation_members m ON m.conversation_id = messages.conversation_id AND m.person_id = $p
				WHERE messages.id > $after ORDER BY messages.id LIMIT $limit`,
			)
			.all({ p: personId, after: afterId, limit })
			.map(decode);
	}

	edit(id: string, body: string): Message | null {
		this.db.transaction(() => {
			const at = now();
			this.db
				.query('INSERT INTO message_edits (message_id, body, edited_at) SELECT id, body, $at FROM messages WHERE id = $id')
				.run({ id, at });
			this.db.query('UPDATE messages SET body = $body, edited_at = $at WHERE id = $id').run({ id, body, at });
		})();
		return this.announce(id);
	}

	/** The `last` most recent earlier versions of an edited message, oldest first. All are kept. */
	history(id: string, last: number): EditRevision[] {
		return this.db
			.query<EditRevision, { id: string; last: number }>(
				`SELECT content, edited_at FROM (
					SELECT id, body AS content, edited_at FROM message_edits WHERE message_id = $id ORDER BY id DESC LIMIT $last
				) ORDER BY id`,
			)
			.all({ id, last });
	}

	unsend(id: string): Message | null {
		this.db.query('UPDATE messages SET deleted_at = $at WHERE id = $id AND deleted_at IS NULL').run({ id, at: now() });
		return this.announce(id);
	}

	/** Tells listeners a message changed in place: an edit, an unsend or a tapback. */
	announce(id: string): Message | null {
		const message = this.get(id);
		if (message !== null) this.onChange(message);
		return message;
	}

	search(personId: string, query: string, limit = 20, within?: string[]): Message[] {
		const needle = query.trim();
		if (needle === '') return [];
		const like = `%${needle.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
		const scope = within === undefined ? null : JSON.stringify(within);
		if ([...needle].length < 3) {
			return this.db
				.query<MessageRow, { p: string; q: string; limit: number; within: string | null }>(
					`SELECT messages.* FROM messages
					JOIN open_conversation_members m ON m.conversation_id = messages.conversation_id AND m.person_id = $p
					WHERE messages.body LIKE $q ESCAPE '\\' AND messages.deleted_at IS NULL
					AND ($within IS NULL OR messages.conversation_id IN (SELECT value FROM json_each($within)))
					ORDER BY messages.id DESC LIMIT $limit`,
				)
				.all({ p: personId, q: like, limit, within: scope })
				.map(decode);
		}
		return this.db
			.query<MessageRow, { p: string; match: string; q: string; limit: number; within: string | null }>(
				`SELECT * FROM (
					SELECT messages.* FROM messages_fts
					JOIN messages ON messages.rowid = messages_fts.rowid
					JOIN open_conversation_members m ON m.conversation_id = messages.conversation_id AND m.person_id = $p
					WHERE messages_fts MATCH $match AND messages.body LIKE $q ESCAPE '\\' AND messages.deleted_at IS NULL
					AND ($within IS NULL OR messages.conversation_id IN (SELECT value FROM json_each($within)))
					ORDER BY messages_fts.rowid DESC LIMIT $limit
				) ORDER BY id DESC`,
			)
			.all({ p: personId, match: `"${needle.replaceAll('"', '""')}"`, q: like, limit, within: scope })
			.map(decode);
	}

	private inConversation(id: string | null, conversationId: string): string | null {
		if (id === null) return null;
		const found = this.db.query('SELECT 1 FROM messages WHERE id = $id AND conversation_id = $c').get({ id, c: conversationId });
		return found === null ? null : id;
	}
}
