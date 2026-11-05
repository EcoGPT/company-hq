import type { Hub, Migration } from '@hq/sdk';
import { newId, now } from '@hq/sdk';

export type Reminder = {
	id: string;
	person_id: string;
	room_id: string | null;
	text: string;
	due_at: number;
	created_by: string;
	source_id: string | null;
	created_at: number;
	delivered_at: number | null;
	cancelled_at: number | null;
};

export const migrations: Migration[] = [
	{
		id: '001_reminders',
		up: `CREATE TABLE reminders (
			id TEXT PRIMARY KEY,
			person_id TEXT NOT NULL REFERENCES people(id),
			room_id TEXT REFERENCES conversations(id),
			text TEXT NOT NULL,
			due_at INTEGER NOT NULL,
			created_by TEXT NOT NULL REFERENCES people(id),
			source_id TEXT REFERENCES conversations(id),
			created_at INTEGER NOT NULL,
			delivered_at INTEGER,
			cancelled_at INTEGER
		);
		CREATE INDEX reminders_pending ON reminders(due_at) WHERE delivered_at IS NULL AND cancelled_at IS NULL;`,
	},
];

const UNITS = { m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000 };

export function parseWhen(input: string, at: number): number | null {
	const text = input.trim().toLowerCase();
	const relative = /^(?:in\s+)?(\d+(?:\.\d+)?)\s*(m|min|mins|minutes?|h|hrs?|hours?|d|days?|w|weeks?)$/.exec(text);
	if (relative !== null) {
		const [, amount = '', unit = ''] = relative;
		return Math.round(at + Number(amount) * UNITS[unit.charAt(0) as keyof typeof UNITS]);
	}
	if (!/^\d{4}-\d{2}-\d{2}t\d{2}:\d{2}(:\d{2}(\.\d+)?)?(z|[+-]\d{2}:?\d{2})$/.test(text)) return null;
	const parsed = Date.parse(input.trim());
	return Number.isNaN(parsed) ? null : parsed;
}

export class Reminders {
	constructor(private readonly hub: Hub) {}

	add(input: {
		personId: string;
		roomId?: string | null;
		text: string;
		dueAt: number;
		createdBy: string;
		sourceId?: string | null;
	}): Reminder {
		const reminder: Reminder = {
			id: newId(),
			person_id: input.personId,
			room_id: input.roomId ?? null,
			text: input.text.trim(),
			due_at: input.dueAt,
			created_by: input.createdBy,
			source_id: input.sourceId ?? null,
			created_at: now(),
			delivered_at: null,
			cancelled_at: null,
		};
		this.hub.db
			.query(
				`INSERT INTO reminders (id, person_id, room_id, text, due_at, created_by, source_id, created_at)
				VALUES ($id, $person_id, $room_id, $text, $due_at, $created_by, $source_id, $created_at)`,
			)
			.run({
				id: reminder.id,
				person_id: reminder.person_id,
				room_id: reminder.room_id,
				text: reminder.text,
				due_at: reminder.due_at,
				created_by: reminder.created_by,
				source_id: reminder.source_id,
				created_at: reminder.created_at,
			});
		return reminder;
	}

	get(id: string): Reminder | null {
		return this.hub.db.query<Reminder, { id: string }>('SELECT * FROM reminders WHERE id = $id').get({ id });
	}

	pending(personId?: string): Reminder[] {
		return this.hub.db
			.query<Reminder, { p: string | null }>(
				`SELECT * FROM reminders WHERE delivered_at IS NULL AND cancelled_at IS NULL AND ($p IS NULL OR person_id = $p)
				ORDER BY due_at`,
			)
			.all({ p: personId ?? null });
	}

	due(at: number): Reminder[] {
		return this.hub.db
			.query<Reminder, { at: number }>(
				'SELECT * FROM reminders WHERE delivered_at IS NULL AND cancelled_at IS NULL AND due_at <= $at ORDER BY due_at',
			)
			.all({ at });
	}

	delivered(id: string): void {
		this.hub.db.query('UPDATE reminders SET delivered_at = $at WHERE id = $id').run({ id, at: now() });
	}

	cancel(id: string): boolean {
		return (
			this.hub.db
				.query('UPDATE reminders SET cancelled_at = $at WHERE id = $id AND delivered_at IS NULL AND cancelled_at IS NULL')
				.run({ id, at: now() }).changes > 0
		);
	}
}
