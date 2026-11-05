import type { Database } from 'bun:sqlite';
import { newId, now } from './ids';

export type Attachment = {
	id: string;
	conversation_id: string;
	uploader_id: string;
	message_id: string | null;
	file_name: string;
	content_type: string;
	byte_size: number;
	width: number | null;
	height: number | null;
	created_at: number;
};

export class Attachments {
	constructor(private readonly db: Database) {}

	create(input: Omit<Attachment, 'id' | 'message_id' | 'created_at'> & { id?: string }): Attachment {
		const attachment: Attachment = { id: newId(), message_id: null, created_at: now(), ...input };
		this.db
			.query(
				`INSERT INTO attachments (id, conversation_id, uploader_id, message_id, file_name, content_type, byte_size, width, height, created_at)
				VALUES ($id, $conversation_id, $uploader_id, $message_id, $file_name, $content_type, $byte_size, $width, $height, $created_at)`,
			)
			.run({ ...attachment });
		return attachment;
	}

	get(id: string): Attachment | null {
		return this.db.query<Attachment, { id: string }>('SELECT * FROM attachments WHERE id = $id').get({ id });
	}

	/** Bytes a person has uploaded and still has on disk: sent or not, in rooms open or closed. Nothing is ever deleted. */
	usedBytes(personId: string): number {
		return this.db
			.query<{ n: number }, { p: string }>('SELECT COALESCE(SUM(byte_size), 0) AS n FROM attachments WHERE uploader_id = $p')
			.get({ p: personId })!.n;
	}

	/** Uploads a person has made that no sent message holds yet. */
	unattached(personId: string): number {
		return this.db
			.query<{ n: number }, { p: string }>('SELECT COUNT(*) AS n FROM attachments WHERE uploader_id = $p AND message_id IS NULL')
			.get({ p: personId })!.n;
	}

	forMessage(messageId: string): Attachment[] {
		return this.db
			.query<Attachment, { m: string }>('SELECT * FROM attachments WHERE message_id = $m ORDER BY created_at, id')
			.all({ m: messageId });
	}

	/** Whether every id is an unclaimed upload of this person in this conversation. */
	claimable(ids: string[], conversationId: string, personId: string): boolean {
		const unique = new Set(ids);
		const { n } = this.db
			.query<{ n: number }, { ids: string; c: string; p: string }>(
				`SELECT COUNT(*) AS n FROM attachments WHERE id IN (SELECT value FROM json_each($ids))
				AND message_id IS NULL AND conversation_id = $c AND uploader_id = $p`,
			)
			.get({ ids: JSON.stringify([...unique]), c: conversationId, p: personId })!;
		return n === unique.size;
	}
}
