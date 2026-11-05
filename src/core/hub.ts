import type { Database } from 'bun:sqlite';
import { migrate, openDatabase, type Migration } from '../db/database';
import { Attachments } from './attachments';
import { CONVERSATION_MIGRATIONS, Conversations } from './conversations';
import { Devices } from './devices';
import { Bus } from './events';
import { FileStore } from './files';
import { KEY_MIGRATIONS, Keys } from './keys';
import { MESSAGE_MIGRATIONS, Messages } from './messages';
import { People, PEOPLE_MIGRATIONS } from './people';
import { Reactions } from './reactions';
import { Reads } from './reads';
import { WIRE_MIGRATIONS } from './wire-schema';

export const CORE_MIGRATIONS: Migration[] = [
	...PEOPLE_MIGRATIONS,
	...KEY_MIGRATIONS,
	...CONVERSATION_MIGRATIONS,
	...MESSAGE_MIGRATIONS,
	...WIRE_MIGRATIONS,
];

export class Hub {
	readonly bus = new Bus();
	publicUrl: string | null = null;
	readonly people: People;
	readonly keys: Keys;
	readonly devices: Devices;
	readonly conversations: Conversations;
	readonly messages: Messages;
	readonly reactions: Reactions;
	readonly reads: Reads;
	readonly attachments: Attachments;

	constructor(
		readonly db: Database,
		readonly files: FileStore = new FileStore(null),
	) {
		this.people = new People(db);
		this.keys = new Keys(db, (keyId) => this.bus.emit({ type: 'key.revoked', keyId }));
		this.devices = new Devices(db, this.keys);
		this.conversations = new Conversations(db, (conversation) => this.bus.emit({ type: 'conversation.created', conversation }));
		this.messages = new Messages(
			db,
			(message) => this.bus.emit({ type: 'message.created', message }),
			(message) => this.bus.emit({ type: 'message.updated', message }),
		);
		this.reactions = new Reactions(db);
		this.reads = new Reads(db);
		this.attachments = new Attachments(db);
	}

	/** `filesDir` is where uploads live; leave it out for a throwaway database. */
	static open(path = ':memory:', extraMigrations: Migration[] = [], filesDir: string | null = null): Hub {
		const db = openDatabase(path);
		migrate(db, [...CORE_MIGRATIONS, ...extraMigrations]);
		return new Hub(db, new FileStore(filesDir));
	}

	link(path: string): string {
		return this.publicUrl === null ? path : `${this.publicUrl}${path}`;
	}

	general() {
		return this.conversations.ensureRoom('general', 'General');
	}
}
