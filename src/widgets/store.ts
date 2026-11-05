import type { Database } from 'bun:sqlite';
import { timingSafeEqual } from 'node:crypto';
import type { Person } from '../core/people';
import { now } from '../core/ids';
import type { Migration } from '../db/database';

/** Ids start at `widgets/001`. The table is this module's: `api_keys` and `devices` get no rows or columns. */
export const WIDGET_MIGRATIONS: Migration[] = [
	{
		// A widget key belongs to one device and is read-only; only the SHA-256 of its secret is kept. One live key per device.
		id: 'widgets/001_keys',
		up: `CREATE TABLE widget_keys (
			id TEXT PRIMARY KEY,
			person_id TEXT NOT NULL REFERENCES people(id),
			device_id TEXT NOT NULL REFERENCES devices(id),
			hash TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			revoked_at INTEGER
		);
		CREATE UNIQUE INDEX widget_keys_live ON widget_keys(device_id) WHERE revoked_at IS NULL`,
	},
];

const PREFIX = 'hq_widget_';
const BASE64URL = '[A-Za-z0-9_-]';
/** `hq_widget_` + a 12-character id + `_` + the 43-character secret: fixed widths, so the parts never run together. */
const SHAPE = new RegExp(`^${PREFIX}(${BASE64URL}{12})_(${BASE64URL}{43})$`);

const sha256 = (text: string) => new Bun.CryptoHasher('sha256').update(text).digest('hex');
const random = (bytes: number) => Buffer.from(crypto.getRandomValues(new Uint8Array(bytes))).toString('base64url');

export type WidgetCaller = { keyId: string; deviceId: string; person: Person };

export class WidgetKeys {
	constructor(private readonly db: Database) {}

	/** A new key for the device; the one it held before stops working. The secret is shown here and never again. */
	mint(deviceId: string, personId: string): string {
		const id = random(9);
		const secret = random(32);
		this.db.transaction(() => {
			this.revokeDevice(deviceId);
			this.db
				.query('INSERT INTO widget_keys (id, person_id, device_id, hash, created_at) VALUES ($id, $person, $device, $hash, $at)')
				.run({ id, person: personId, device: deviceId, hash: sha256(secret), at: now() });
		})();
		return `${PREFIX}${id}_${secret}`;
	}

	/**
	 * Who holds this key, if it still works: not revoked, its device's bearer not revoked, its person not removed. The row is
	 * found by id and the secret's hash compared in constant time.
	 */
	check(token: string): WidgetCaller | null {
		const parts = SHAPE.exec(token);
		if (parts === null) return null;
		const row = this.db
			.query<Person & { key_id: string; device_id: string; key_hash: string }, { id: string }>(
				`SELECT people.*, widget_keys.id AS key_id, widget_keys.device_id, widget_keys.hash AS key_hash
				FROM widget_keys
				JOIN devices ON devices.id = widget_keys.device_id
				JOIN api_keys ON api_keys.id = devices.key_id
				JOIN people ON people.id = widget_keys.person_id
				WHERE widget_keys.id = $id AND widget_keys.revoked_at IS NULL AND api_keys.revoked_at IS NULL
					AND people.removed_at IS NULL`,
			)
			.get({ id: parts[1]! });
		if (row === null) return null;
		const given = Buffer.from(sha256(parts[2]!));
		const stored = Buffer.from(row.key_hash);
		if (given.length !== stored.length || !timingSafeEqual(given, stored)) return null;
		const { key_id: keyId, device_id: deviceId, key_hash: _stored, ...person } = row;
		return { keyId, deviceId, person };
	}

	/** Ends every key the device holds (there is at most one live). */
	revokeDevice(deviceId: string): void {
		this.db
			.query('UPDATE widget_keys SET revoked_at = $at WHERE device_id = $device AND revoked_at IS NULL')
			.run({ at: now(), device: deviceId });
	}
}
