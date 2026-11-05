import type { Database } from 'bun:sqlite';
import { now } from './ids';

export type Reaction = { emoji: string; person_ids: string[] };

export class Reactions {
	constructor(private readonly db: Database) {}

	/** The same emoji from the same person twice takes it back. */
	toggle(messageId: string, personId: string, emoji: string): void {
		const { changes } = this.db
			.query('DELETE FROM reactions WHERE message_id = $m AND person_id = $p AND emoji = $e')
			.run({ m: messageId, p: personId, e: emoji });
		if (changes > 0) return;
		this.db
			.query('INSERT INTO reactions (message_id, person_id, emoji, created_at) VALUES ($m, $p, $e, $at)')
			.run({ m: messageId, p: personId, e: emoji, at: now() });
	}

	forMessage(messageId: string): Reaction[] {
		const rows = this.db
			.query<{ emoji: string; person_id: string }, { m: string }>(
				'SELECT emoji, person_id FROM reactions WHERE message_id = $m ORDER BY created_at, rowid',
			)
			.all({ m: messageId });
		const byEmoji = new Map<string, string[]>();
		for (const row of rows) byEmoji.set(row.emoji, [...(byEmoji.get(row.emoji) ?? []), row.person_id]);
		return [...byEmoji].map(([emoji, person_ids]) => ({ emoji, person_ids }));
	}
}
