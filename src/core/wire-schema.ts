import type { Migration } from '../db/database';

/** What the native app's protocol needs beyond rooms, messages and keys. */
export const WIRE_MIGRATIONS: Migration[] = [
	{
		// A device is one sign-in: its bearer is an ordinary api key, so revoking the key revokes the device.
		id: 'core/012_devices',
		up: `CREATE TABLE devices (
			id TEXT PRIMARY KEY,
			person_id TEXT NOT NULL REFERENCES people(id),
			key_id TEXT NOT NULL UNIQUE REFERENCES api_keys(id),
			name TEXT NOT NULL,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX devices_person ON devices(person_id)`,
	},
	{
		id: 'core/013_message_wire',
		up: `ALTER TABLE messages ADD COLUMN reply_to_message_id TEXT;
		ALTER TABLE messages ADD COLUMN client_msg_id TEXT;
		ALTER TABLE messages ADD COLUMN deleted_at INTEGER;
		CREATE UNIQUE INDEX messages_client_id ON messages(author_id, client_msg_id) WHERE client_msg_id IS NOT NULL;
		CREATE TABLE message_edits (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			message_id TEXT NOT NULL REFERENCES messages(id),
			body TEXT NOT NULL,
			edited_at INTEGER NOT NULL
		);
		CREATE INDEX message_edits_message ON message_edits(message_id);
		CREATE TABLE reactions (
			message_id TEXT NOT NULL REFERENCES messages(id),
			person_id TEXT NOT NULL REFERENCES people(id),
			emoji TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			PRIMARY KEY (message_id, person_id, emoji)
		)`,
	},
	{
		id: 'core/014_read_marks',
		up: `CREATE TABLE read_marks (
			conversation_id TEXT NOT NULL REFERENCES conversations(id),
			person_id TEXT NOT NULL REFERENCES people(id),
			last_read_message_id TEXT NOT NULL DEFAULT '',
			marked_unread_at INTEGER,
			updated_at INTEGER NOT NULL,
			PRIMARY KEY (conversation_id, person_id)
		)`,
	},
	{
		id: 'core/015_attachments_avatars',
		up: `CREATE TABLE attachments (
			id TEXT PRIMARY KEY,
			conversation_id TEXT NOT NULL REFERENCES conversations(id),
			uploader_id TEXT NOT NULL REFERENCES people(id),
			message_id TEXT REFERENCES messages(id),
			file_name TEXT NOT NULL,
			content_type TEXT NOT NULL,
			byte_size INTEGER NOT NULL,
			width INTEGER,
			height INTEGER,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX attachments_message ON attachments(message_id);
		ALTER TABLE people ADD COLUMN avatar_id TEXT;
		ALTER TABLE conversations ADD COLUMN avatar_id TEXT`,
	},
	{
		id: 'core/018_attachment_uploader',
		up: 'CREATE INDEX attachments_uploader ON attachments(uploader_id, message_id)',
	},
];
