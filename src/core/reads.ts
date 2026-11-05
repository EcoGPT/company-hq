import type { Database } from 'bun:sqlite';
import { now } from './ids';

export type ReadMark = { person_id: string; last_read_message_id: string };

type Position = { last_read_message_id: string; marked_unread_at: number | null };

export class Reads {
	constructor(private readonly db: Database) {}

	/**
	 * Moves a person's read position forward, never back. `changed` says whether
	 * anyone has news: the position moved, or a "mark unread" flag cleared.
	 */
	markRead(conversationId: string, personId: string, messageId: string): { changed: boolean; effective: string } {
		const row = this.position(conversationId, personId);
		const flagged = row?.marked_unread_at != null;
		if (row !== null && row.last_read_message_id >= messageId) {
			if (flagged) this.clearFlag(conversationId, personId);
			return { changed: flagged, effective: row.last_read_message_id };
		}
		this.db
			.query(
				`INSERT INTO read_marks (conversation_id, person_id, last_read_message_id, marked_unread_at, updated_at)
				VALUES ($c, $p, $m, NULL, $at)
				ON CONFLICT (conversation_id, person_id) DO UPDATE
				SET last_read_message_id = $m, marked_unread_at = NULL, updated_at = $at`,
			)
			.run({ c: conversationId, p: personId, m: messageId, at: now() });
		return { changed: true, effective: messageId };
	}

	/** A private reminder only: what other people see as read does not move. */
	markUnread(conversationId: string, personId: string): void {
		this.db
			.query(
				`INSERT INTO read_marks (conversation_id, person_id, marked_unread_at, updated_at) VALUES ($c, $p, $at, $at)
				ON CONFLICT (conversation_id, person_id) DO UPDATE SET marked_unread_at = $at`,
			)
			.run({ c: conversationId, p: personId, at: now() });
	}

	marks(conversationId: string): ReadMark[] {
		return this.db
			.query<ReadMark, { c: string }>(
				"SELECT person_id, last_read_message_id FROM read_marks WHERE conversation_id = $c AND last_read_message_id != '' ORDER BY updated_at, person_id",
			)
			.all({ c: conversationId });
	}

	/** Messages from other people after the read position; an unsent one does not count. */
	unreadCount(conversationId: string, personId: string): number {
		const row = this.position(conversationId, personId);
		const { n } = this.db
			.query<{ n: number }, { c: string; p: string; after: string }>(
				`SELECT COUNT(*) AS n FROM messages
				WHERE conversation_id = $c AND id > $after AND author_id != $p AND deleted_at IS NULL`,
			)
			.get({ c: conversationId, p: personId, after: row?.last_read_message_id ?? '' })!;
		return Math.max(n, row?.marked_unread_at != null ? 1 : 0);
	}

	private position(conversationId: string, personId: string): Position | null {
		return this.db
			.query<Position, { c: string; p: string }>(
				'SELECT last_read_message_id, marked_unread_at FROM read_marks WHERE conversation_id = $c AND person_id = $p',
			)
			.get({ c: conversationId, p: personId });
	}

	private clearFlag(conversationId: string, personId: string): void {
		this.db
			.query('UPDATE read_marks SET marked_unread_at = NULL WHERE conversation_id = $c AND person_id = $p')
			.run({ c: conversationId, p: personId });
	}
}
