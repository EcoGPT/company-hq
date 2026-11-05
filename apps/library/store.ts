import type { Hub, Migration } from '@hq/sdk';

export type LibraryFile = {
	id: string;
	file_name: string;
	content_type: string;
	byte_size: number;
	conversation_id: string;
	conversation_title: string;
	uploader_name: string;
	created_at: number;
};

export const migrations: Migration[] = [
	{
		id: '001_files_by_conversation',
		up: 'CREATE INDEX attachments_conversation ON attachments(conversation_id, created_at)',
	},
];

export class Files {
	constructor(private readonly hub: Hub) {}

	/**
	 * The files sent in conversations `personId` is in now, newest first: the rule for downloading one. A room that is
	 * archived has no members, so its files are not listed. An upload no message holds yet and a file whose message was
	 * unsent are not files in the room.
	 */
	visibleTo(personId: string, limit: number): LibraryFile[] {
		return this.hub.db
			.query<LibraryFile, { p: string; limit: number }>(
				`SELECT a.id, a.file_name, a.content_type, a.byte_size, a.conversation_id, a.created_at,
					c.title AS conversation_title, u.name AS uploader_name
				FROM open_conversation_members m
				JOIN attachments a ON a.conversation_id = m.conversation_id
				JOIN messages msg ON msg.id = a.message_id AND msg.deleted_at IS NULL
				JOIN conversations c ON c.id = a.conversation_id
				JOIN people u ON u.id = a.uploader_id
				WHERE m.person_id = $p
				ORDER BY a.created_at DESC, a.id DESC LIMIT $limit`,
			)
			.all({ p: personId, limit });
	}
}
