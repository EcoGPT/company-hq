import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import { newId, now } from './ids';
import type { Person } from './people';

export const KEY_MIGRATIONS: Migration[] = [
	{
		id: 'core/002_api_keys',
		up: `CREATE TABLE api_keys (
			id TEXT PRIMARY KEY,
			person_id TEXT NOT NULL REFERENCES people(id),
			label TEXT NOT NULL,
			hash TEXT NOT NULL UNIQUE,
			created_at INTEGER NOT NULL,
			last_used_at INTEGER,
			revoked_at INTEGER
		)`,
	},
	{
		// What a key may do comes from how it was made, not from its label. Keys made before this keep their label's meaning.
		id: 'core/016_key_kinds',
		up: `ALTER TABLE api_keys ADD COLUMN kind TEXT NOT NULL DEFAULT 'key';
		UPDATE api_keys SET kind = label WHERE label IN ('setup', 'invite', 'device')`,
	},
];

/**
 * What a key is for, set by whoever made it and never read from a label: `setup` and `invite` sign a person in
 * (and only that), `device` is a signed-in device's bearer, `mcp` is a key made on the MCP keys card, and `key`
 * is any other key (`bun hq key`). The last three are bearers; only a `device` may do an admin's work.
 */
export type KeyKind = 'setup' | 'invite' | 'device' | 'key' | 'mcp';

export type ApiKey = {
	id: string;
	person_id: string;
	label: string;
	kind: KeyKind;
	created_at: number;
	last_used_at: number | null;
	revoked_at: number | null;
};

const LAST_USED_RESOLUTION = 60_000;
const DAY = 86_400_000;

export const INVITE_EXPIRED = 'invite_expired';

export type KeyCheck = { ok: true; person: Person; keyId: string; kind: KeyKind } | { ok: false; error: string };

function hashKey(secret: string): string {
	return new Bun.CryptoHasher('sha256').update(secret).digest('hex');
}

const COLUMNS = 'id, person_id, label, kind, created_at, last_used_at, revoked_at';

export class Keys {
	/** An invite key enrolls devices until this many days after it was minted, used or not. 0 turns that off. */
	inviteTtlDays = 7;

	constructor(
		private readonly db: Database,
		private readonly onRevoke: (keyId: string) => void = () => {},
	) {}

	/**
	 * The kind is the caller's to say; the label is only a name for people to read and never changes what a key may do.
	 * The secret is always random (256 bits) and shown once.
	 */
	mint(personId: string, kind: KeyKind = 'key', options: { label?: string } = {}): { key: ApiKey; secret: string } {
		const secret = `hq_${Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url')}`;
		const label = options.label ?? (kind === 'key' ? 'default' : kind);
		const key: ApiKey = {
			id: newId(),
			person_id: personId,
			label,
			kind,
			created_at: now(),
			last_used_at: null,
			revoked_at: null,
		};
		this.db
			.query(
				'INSERT INTO api_keys (id, person_id, label, kind, hash, created_at) VALUES ($id, $person_id, $label, $kind, $hash, $created_at)',
			)
			.run({ id: key.id, person_id: personId, label, kind: key.kind, hash: hashKey(secret), created_at: key.created_at });
		return { key, secret };
	}

	authenticate(secret: string): Person | null {
		const found = this.check(secret);
		return found.ok ? found.person : null;
	}

	/** A bearer: what every route, MCP and the socket sign in with. A setup or invite key is not one; it only enrolls. */
	check(secret: string | null): KeyCheck {
		if (secret === null || !secret.startsWith('hq_')) return { ok: false, error: 'unauthorized' };
		const found = this.find(secret);
		if (found === null || found.kind === 'invite' || found.kind === 'setup') return { ok: false, error: 'unauthorized' };
		this.touch(found);
		return { ok: true, person: found.person, keyId: found.keyId, kind: found.kind };
	}

	/** What an enroll trades for a device: a setup or invite key, nothing else. */
	checkSignIn(secret: string): KeyCheck {
		const found = this.find(secret);
		if (found === null || (found.kind !== 'setup' && found.kind !== 'invite')) return { ok: false, error: 'unauthorized' };
		if (found.kind === 'invite' && this.inviteTtlDays > 0 && now() - found.createdAt >= this.inviteTtlDays * DAY) {
			return { ok: false, error: INVITE_EXPIRED };
		}
		this.touch(found);
		return { ok: true, person: found.person, keyId: found.keyId, kind: found.kind };
	}

	list(personId: string): ApiKey[] {
		return this.db
			.query<ApiKey, { person_id: string }>(
				`SELECT ${COLUMNS} FROM api_keys WHERE person_id = $person_id ORDER BY created_at, rowid`,
			)
			.all({ person_id: personId });
	}

	get(id: string): ApiKey | null {
		return this.db.query<ApiKey, { id: string }>(`SELECT ${COLUMNS} FROM api_keys WHERE id = $id`).get({ id });
	}

	isActive(id: string): boolean {
		return this.db.query('SELECT 1 FROM api_keys WHERE id = $id AND revoked_at IS NULL').get({ id }) !== null;
	}

	revokeAll(personId: string): number {
		return this.list(personId).filter((key) => key.revoked_at === null && this.revoke(key.id)).length;
	}

	/** Ends every sign-in key (invite or setup) a person holds, so a new one is the only one. Devices carry on. */
	revokeSignIn(personId: string): void {
		for (const key of this.list(personId)) {
			if ((key.kind === 'invite' || key.kind === 'setup') && key.revoked_at === null) this.revoke(key.id);
		}
	}

	revoke(id: string): boolean {
		const { changes } = this.db
			.query('UPDATE api_keys SET revoked_at = $at WHERE id = $id AND revoked_at IS NULL')
			.run({ at: now(), id });
		if (changes > 0) this.onRevoke(id);
		return changes > 0;
	}

	/** A live key and whose it is; nothing for a revoked key or for a person who was removed. */
	private find(secret: string) {
		const row = this.db
			.query<
				Person & { key_id: string; key_kind: KeyKind; key_created_at: number; key_used_at: number | null },
				{ hash: string }
			>(
				`SELECT people.*, api_keys.id AS key_id, api_keys.kind AS key_kind, api_keys.created_at AS key_created_at,
					api_keys.last_used_at AS key_used_at
				FROM api_keys JOIN people ON people.id = api_keys.person_id
				WHERE api_keys.hash = $hash AND api_keys.revoked_at IS NULL AND people.removed_at IS NULL`,
			)
			.get({ hash: hashKey(secret) });
		if (row === null) return null;
		const { key_id: keyId, key_kind: kind, key_created_at: createdAt, key_used_at: usedAt, ...person } = row;
		return { keyId, kind, createdAt, usedAt, person };
	}

	private touch(found: { keyId: string; usedAt: number | null }): void {
		const at = now();
		if (found.usedAt === null || at - found.usedAt >= LAST_USED_RESOLUTION) {
			this.db.query('UPDATE api_keys SET last_used_at = $at WHERE id = $id').run({ at, id: found.keyId });
		}
	}
}
