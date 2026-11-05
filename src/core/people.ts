import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import { newId, now } from './ids';

export type PersonKind = 'human' | 'assistant' | 'service';
export type Role = 'admin' | 'member';

export type Person = {
	id: string;
	name: string;
	handle: string;
	kind: PersonKind;
	role: Role;
	created_at: number;
	avatar_id: string | null;
	/** Set when an admin removed them. The row stays, and their access ends; restoring clears it. */
	removed_at: number | null;
};

export const PEOPLE_MIGRATIONS: Migration[] = [
	{
		id: 'core/001_people',
		up: `CREATE TABLE people (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			handle TEXT NOT NULL UNIQUE COLLATE NOCASE,
			kind TEXT NOT NULL CHECK (kind IN ('human', 'assistant', 'service')),
			role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
			created_at INTEGER NOT NULL
		)`,
	},
	{
		// Removing a person freezes them: the row stays so history still names them.
		id: 'core/017_people_removed',
		up: 'ALTER TABLE people ADD COLUMN removed_at INTEGER',
	},
];

export const HANDLE = /^[a-z0-9][a-z0-9_-]{0,31}$/i;

export class People {
	constructor(private readonly db: Database) {}

	create(input: { name: string; handle: string; kind?: PersonKind; role?: Role }): Person {
		if (!HANDLE.test(input.handle)) throw new Error(`invalid handle: ${input.handle}`);
		const person: Person = {
			id: newId(),
			name: input.name.trim() || input.handle,
			handle: input.handle,
			kind: input.kind ?? 'human',
			role: input.role ?? 'member',
			created_at: now(),
			avatar_id: null,
			removed_at: null,
		};
		this.db
			.query(
				'INSERT INTO people (id, name, handle, kind, role, created_at) VALUES ($id, $name, $handle, $kind, $role, $created_at)',
			)
			.run({
				id: person.id,
				name: person.name,
				handle: person.handle,
				kind: person.kind,
				role: person.role,
				created_at: person.created_at,
			});
		return person;
	}

	ensure(input: { name: string; handle: string; kind?: PersonKind; role?: Role }): Person {
		const existing = this.byHandle(input.handle);
		if (existing === null) return this.create(input);
		const kind = input.kind ?? 'human';
		if (existing.kind !== kind) {
			throw new Error(`@${existing.handle} already belongs to a ${existing.kind}; pick another handle for this ${kind}`);
		}
		if (existing.name === input.name) return existing;
		this.db.query('UPDATE people SET name = $name WHERE id = $id').run({ id: existing.id, name: input.name });
		return { ...existing, name: input.name };
	}

	get(id: string): Person | null {
		return this.db.query<Person, { id: string }>('SELECT * FROM people WHERE id = $id').get({ id });
	}

	setAvatar(id: string, avatarId: string | null): void {
		this.db.query('UPDATE people SET avatar_id = $avatarId WHERE id = $id').run({ id, avatarId });
	}

	setRole(id: string, role: Role): void {
		this.db.query('UPDATE people SET role = $role WHERE id = $id').run({ id, role });
	}

	/** Freezes (a time) or unfreezes (null) a person. Rows are never deleted. */
	setRemoved(id: string, at: number | null): void {
		this.db.query('UPDATE people SET removed_at = $at WHERE id = $id').run({ id, at });
	}

	/** Anyone, of any kind, whose name or handle is this, whatever the case; removed ones included. */
	named(name: string): Person[] {
		return this.db
			.query<Person, { name: string }>(
				'SELECT * FROM people WHERE name = $name COLLATE NOCASE OR handle = $name COLLATE NOCASE ORDER BY created_at',
			)
			.all({ name });
	}

	/** The admins who sign in and have not been removed: the people who can still run the place. */
	activeAdmins(): Person[] {
		return this.db
			.query<Person, []>(
				"SELECT * FROM people WHERE kind = 'human' AND role = 'admin' AND removed_at IS NULL ORDER BY created_at",
			)
			.all();
	}

	/** A handle from a display name that nobody has: "Cy Young" is cy-young, then cy-young-2. */
	freeHandle(name: string): string {
		const base =
			name
				.toLowerCase()
				.replaceAll(/[^a-z0-9]+/g, '-')
				.replaceAll(/^-+|-+$/g, '')
				.slice(0, 28) || 'member';
		for (let n = 1; ; n++) {
			const handle = n === 1 ? base : `${base}-${n}`;
			if (this.byHandle(handle) === null) return handle;
		}
	}

	byHandle(handle: string): Person | null {
		return this.db.query<Person, { handle: string }>('SELECT * FROM people WHERE handle = $handle').get({ handle });
	}

	byIds(ids: Iterable<string>): Map<string, Person> {
		const unique = [...new Set(ids)];
		if (unique.length === 0) return new Map();
		return new Map(
			this.db
				.query<Person, { ids: string }>('SELECT * FROM people WHERE id IN (SELECT value FROM json_each($ids))')
				.all({ ids: JSON.stringify(unique) })
				.map((person) => [person.id, person]),
		);
	}

	list(): Person[] {
		return this.db.query<Person, []>('SELECT * FROM people ORDER BY created_at').all();
	}
}
